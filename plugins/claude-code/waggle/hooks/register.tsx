import type { EngineInterface, Register } from 'claude-code'

import { answerLine, answerToast, ageText, clip, toneFor, type Answer } from './format'

// The Waggle mod (HAIL-134). It reaches the Waggle daemon only through the installed
// `knock` binary (bin/waggle-launcher, `waggle mod ...`) and sends no prompt text,
// only that a prompt was submitted, and a tool's name. No network calls.

const MOD_VERSION = '0.1.0'
const POLL_WAIT_MS = 20_000 // each long poll; the daemon answers sooner on a change
const POLL_GAP_MS = 250 // never a hot loop, whatever the daemon answers
const RETRY_MS = 30_000 // Waggle missing or not answering
const TOOL_FLUSH_MS = 1_000 // tool calls are reported in bursts
const REDRAW_MS = 15_000 // the band's age, only while an ask is open
const NUDGE_WINDOW_MS = 60_000 // one nudge per case in this window, as the daemon holds

// `waiting_since` is when the case last started waiting on the human; an older daemon omits it.
type OpenAsk = { case_id: string; title: string; created_at: string; waiting_since?: string }
const waitingSince = (ask: OpenAsk) => Date.parse(ask.waiting_since ?? ask.created_at)
type Status = {
  sig: string
  open_ask: OpenAsk | null
  open_count: number
  other_open_count: number
  answer: Answer | null
  nudge: { case_id: string; text: string } | null
}

type Engine = EngineInterface

const isStatus = (value: unknown): value is Status =>
  typeof value === 'object' && value !== null && typeof (value as Status).sig === 'string'

let status: Status | null = null
let seen: string | undefined
let started = false
let stopped = false
// The answer the band shows until the next prompt (at most ANSWER_LINE_MS), and the one seen first
// (an answer from before this session loaded is never toasted or shown).
let answerShown: Answer | null = null
// How long the answer's line stays at most when no new prompt comes.
const ANSWER_LINE_MS = 10 * 60_000
let primed = false
let lastAnswerKey: string | null = null
let redraw: { cancel: () => void } | null = null
const nudged = new Map<string, number>()
// Reports go one at a time, so Waggle sees them in the order they happened.
let queue: Promise<unknown> = Promise.resolve()
let pendingTools = 0
let lastTool: string | undefined
let isFlushScheduled = false

async function knock($: Engine, args: string[], timeoutMs = 15_000): Promise<unknown | null> {
  try {
    const result = await $.process.run([`${$.plugin.root}/bin/waggle-launcher`, 'mod', ...args], { timeoutMs })
    if (result.exitCode !== 0) return null
    const line = result.stdout.trim().split('\n').pop() ?? ''
    return JSON.parse(line)
  } catch {
    return null
  }
}

function report($: Engine, event: string, extra: string[] = []): void {
  queue = queue
    .then(async () => {
      const id = await $.session.id()
      await knock($, ['report', '--session', id, '--event', event, ...extra])
    })
    .catch(() => {})
}

// HAIL-195: the Waggle tool a call names, or null. The tool name is `mcp__<server>__waggle_check`.
const WAGGLE_TOOL = /(?:^|__)(?:waggle|knock)_(ask|check|update|guide|settings)$/

// Before a Waggle tool runs, Waggle reads the token numbers of the latest assistant message in the
// session log (`waggle mod usage`). The path stays in the `waggle` process: only four numbers
// reach the daemon, never message text. A missing path sends nothing.
function reportContext($: Engine, tool: string, transcript: unknown): void {
  if (typeof transcript !== 'string' || transcript === '') return
  queue = queue
    .then(async () => {
      const id = await $.session.id()
      await knock($, ['usage', '--session', id, '--tool', tool, '--transcript', transcript])
    })
    .catch(() => {})
}

function flushTools($: Engine): void {
  isFlushScheduled = false
  if (pendingTools === 0) return
  const extra = ['--count', String(pendingTools)]
  if (lastTool) extra.push('--tool', lastTool)
  pendingTools = 0
  lastTool = undefined
  report($, 'tool.call', extra)
}

// A burst of tool calls becomes one report, TOOL_FLUSH_MS after the first.
async function flushLater($: Engine): Promise<void> {
  try {
    await $.clock.sleep(TOOL_FLUSH_MS)
    if (isFlushScheduled) flushTools($)
  } catch {
    // The environment unloaded while it waited.
  }
}

// An ask is open: redraw every 15 s so the age moves. None open: no timer.
function syncRedraw($: Engine): void {
  if (status?.open_ask && !redraw) {
    redraw = $.clock.every(REDRAW_MS, () => $.ui.invalidate('ui.render'))
  } else if (!status?.open_ask && redraw) {
    redraw.cancel()
    redraw = null
  }
}

async function deliver($: Engine, nudge: { case_id: string; text: string }): Promise<void> {
  const now = await $.clock.now()
  const last = nudged.get(nudge.case_id)
  if (last !== undefined && now - last < NUDGE_WINDOW_MS) return
  nudged.set(nudge.case_id, now)
  let isDropped = false
  try {
    const result = await $.prompt.submit({ text: nudge.text })
    isDropped = 'drop' in result && result.drop !== undefined
  } catch {
    isDropped = true
  }
  if (isDropped) {
    // Not submitted: give Waggle its window back.
    nudged.delete(nudge.case_id)
    report($, 'nudge.failed', ['--case', nudge.case_id])
  }
}

function apply($: Engine, next: Status): void {
  status = next
  seen = next.sig
  const answer = next.answer
  const key = answer ? `${answer.case_id}@${answer.answered_at}` : null
  if (!primed) {
    primed = true
    lastAnswerKey = key
  } else if (answer && key !== lastAnswerKey) {
    lastAnswerKey = key
    answerShown = answer
    $.ui.toast(answerToast(answer), { timeoutMs: 8_000 })
  }
  // A newer ask after the answer ends the answer's line.
  if (answerShown && next.open_ask && waitingSince(next.open_ask) > Date.parse(answerShown.answered_at)) {
    answerShown = null
  }
  if (next.nudge) void deliver($, next.nudge).catch(() => {})
  syncRedraw($)
  $.ui.invalidate('ui.render')
}

async function loop($: Engine): Promise<void> {
  let isFirst = true
  while (!stopped) {
    const id = await $.session.id()
    const args = ['poll', '--session', id, '--wait-ms', isFirst ? '0' : String(POLL_WAIT_MS), '--mod-version', MOD_VERSION]
    if (seen !== undefined) args.push('--seen', seen)
    const result = await knock($, args, isFirst ? 10_000 : POLL_WAIT_MS + 10_000)
    if (!isStatus(result)) {
      // Waggle is not installed or not answering: draw nothing and try again later.
      status = null
      syncRedraw($)
      $.ui.invalidate('ui.render')
      await $.clock.sleep(RETRY_MS)
      continue
    }
    isFirst = false
    apply($, result)
    await $.clock.sleep(POLL_GAP_MS)
  }
}

// The loop starts once, from whichever hook fires first.
function start($: Engine): void {
  if (started) return
  started = true
  void loop($)
}


export const register: Register = on => {
  on('session.start', ($, e, next) => {
    start($)
    return next(e)
  })

  on('session.end', ($, e, next) => {
    if (e.reason === 'clear' || e.reason === 'resume') {
      // The process goes on under a new session id, and the loop follows it.
      status = null
      seen = undefined
      answerShown = null
      primed = false
      $.ui.invalidate('ui.render')
    } else {
      stopped = true
      redraw?.cancel()
      redraw = null
    }
    return next(e)
  })

  on('prompt.submit', ($, e, next) => {
    start($)
    // Only that a prompt was submitted. Never e.text.
    report($, 'prompt.submit')
    // The agent usually ends its turn right after an answer, so the answer's line stays until the next prompt.
    if (answerShown) {
      answerShown = null
      $.ui.invalidate('ui.render')
    }
    return next(e)
  })

  on('turn.start', ($, e, next) => {
    start($)
    report($, 'turn.start')
    return next(e)
  })

  on('turn.complete', ($, e, next) => {
    // A subagent's turn is not the session's.
    if (e.agentId === undefined) {
      flushTools($)
      report($, 'turn.complete')
    }
    return next(e)
  })

  on('tool.call', ($, e, next) => {
    // A subagent's tool call is not the session's turn (WAG-368). Counted, it made a session whose turn
    // had ended look busy while a background agent ran, and Waggle held the wake for a new reply.
    if (e.agentId !== undefined) return next(e)
    start($)
    pendingTools += 1
    lastTool = e.tool
    const waggle = typeof e.tool === 'string' ? WAGGLE_TOOL.exec(e.tool) : null
    if (waggle) {
      const hook = e as unknown as { transcriptPath?: unknown; transcript_path?: unknown }
      reportContext($, `waggle_${waggle[1]}`, hook.transcriptPath ?? hook.transcript_path)
    }
    if (!isFlushScheduled) {
      isFlushScheduled = true
      void flushLater($)
    }
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const columns = Math.max(20, e.props.bodyColumns)

    if (answerShown && (await $.clock.now()) - Date.parse(answerShown.answered_at) > ANSWER_LINE_MS) answerShown = null
    if (answerShown) {
      const { Box, Text } = $.ui.resolve(e)
      return (
        <Box>
          <Text color="green" wrap="truncate-end">
            {answerLine(answerShown, columns - 2)}
          </Text>
        </Box>
      )
    }

    const ask = status?.open_ask
    if (!ask) {
      // No ask of this session: still say when other sessions have asks waiting, so any terminal points to Waggle.
      const waiting = status?.other_open_count ?? 0
      if (waiting === 0) return next(e)
      const { Box, Button, Text } = $.ui.resolve(e)
      const openQueue = async () => {
        await knock($, ['open'])
      }
      return (
        <Box>
          <Text color="#E4572E" bold>
            Waggle
          </Text>
          <Text wrap="truncate-end">
            {` · ${waiting} ${waiting === 1 ? 'request' : 'requests'} waiting for you in other sessions · `}
          </Text>
          <Button key="queue" label="queue" hotkey="2" plain onPress={openQueue} />
        </Box>
      )
    }
    const age = (await $.clock.now()) - waitingSince(ask)
    const tone = toneFor(age)
    if (tone === 'quiet') return next(e)

    const { Box, Button, Text } = $.ui.resolve(e)
    const others = status?.other_open_count ?? 0
    const othersText = others > 0 ? `+${others} in other sessions · ` : ''
    // Room for the title: what is left after the fixed words, the button and the others.
    const fixed = 'Waggle · waiting on your answer ·  · 99m'.length + '1: open'.length + (others > 0 ? othersText.length + '2: queue'.length + 2 : 0) + 4
    // "Waggle" always leads in Waggle's colour so the line stands apart from the spinner above it.
    const text =
      tone === 'dim'
        ? ` · still waiting on your answer · ${ageText(age)}`
        : ` · waiting on your answer · ${clip(ask.title, columns - fixed)} · ${ageText(age)}`
    const open = async () => {
      await knock($, ['open', '--case', ask.case_id])
    }
    const openQueue = async () => {
      await knock($, ['open'])
    }

    return (
      <Box justifyContent="space-between">
        <Box>
          <Text color="#E4572E" bold>
            Waggle
          </Text>
          <Text color={tone === 'urgent' ? '#E4572E' : undefined} wrap="truncate-end">
            {text} ·{' '}
          </Text>
          {/* A digit hotkey on the band also fires when typed alone into an empty prompt; a letter needs band focus. */}
          <Button key="open" label="open" hotkey="1" plain onPress={open} />
        </Box>
        {others > 0 ? (
          <Box>
            <Text dimColor>{othersText}</Text>
            <Button key="queue" label="queue" hotkey="2" plain onPress={openQueue} />
          </Box>
        ) : null}
      </Box>
    )
  })
}
