import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import type { Engine } from 'claude-code/testing'

// The Waggle mod against a fake `waggle`: every `$.process.run` is answered here, so
// no real binary, daemon or Claude Code session is touched.

const SURFACES = ['terminal', 'desktop'] as const
const START = 1_000_000_000_000

type Answer = { case_id: string; title: string; choice: string | null; note: string | null; answered_at: string }
type World = {
  open_ask: { case_id: string; title: string; created_at: string; waiting_since?: string } | null
  other_open_count: number
  answer: Answer | null
  nudge: { case_id: string; text: string } | null
  // Poll answers exit 127 (Waggle not installed).
  isMissing: boolean
  calls: string[][]
  toasts: string[]
  submitted: string[]
  dropSubmit: boolean
}

const world = (): World => ({
  open_ask: null,
  other_open_count: 0,
  answer: null,
  nudge: null,
  isMissing: false,
  calls: [],
  toasts: [],
  submitted: [],
  dropSubmit: false,
})

const ran = (stdout: string, exitCode = 0) =>
  ({
    value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  }) as never

// The world beneath the plugin: a fake waggle, a session id, the clock, a toast sink.
function setup(on: On, w: World) {
  const clock = mock.clock(on, { now: START })
  on('session.id', () => ({ value: 'sess-test' }) as never)
  // The engine draws nothing of its own in the band.
  on('ui.render', () => ({ type: 'Box', props: {}, children: [] }) as never)
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  on('tool.call', () => ({ result: { stdout: '', stderr: '' }, text: 'ok' }) as never)
  on('ui.toast', (_$, e) => {
    w.toasts.push(e.text)
    return undefined as never
  })
  on('prompt.submit', (_$, e) => {
    w.submitted.push(e.text)
    return w.dropSubmit ? { drop: 'busy' } : { text: e.text }
  })
  on('process.run', (_$, e) => {
    const argv = [...e.argv]
    w.calls.push(argv)
    if (argv[2] === 'poll') {
      if (w.isMissing) return ran('', 127)
      const nudge = w.nudge
      w.nudge = null
      return ran(
        JSON.stringify({
          now: new Date().toISOString(),
          sig: JSON.stringify([w.open_ask?.case_id, w.other_open_count, w.answer?.answered_at]),
          open_ask: w.open_ask,
          open_count: w.open_ask ? 1 : 0,
          other_open_count: w.other_open_count,
          answer: w.answer,
          nudge,
        }),
      )
    }
    return ran('{"ok":true}')
  })
  return clock
}

// Every scenario ends the session and lets the mod's last wait run out, so nothing is
// left pending when the test environment unloads.
type Clock = ReturnType<typeof mock.clock>
function scenario(name: string, body: ($: Engine, w: World, clock: Clock) => Promise<void>) {
  test(name, async ($, on) => {
    const w = world()
    const clock = setup(on, w)
    try {
      await body($, w, clock)
    } finally {
      await $.session.end({ reason: 'other', sessionId: 'sess-test' } as never)
      await clock.advance(31_000)
    }
  })
}

const BAND = {
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 6,
    bodyColumns: 100,
    scroll: { offset: 0, bodyRows: 6 },
    view: {},
  },
} as const

const askAt = (ageMs: number) => ({
  case_id: 'c_1',
  title: 'Checkout: one page or two steps?',
  created_at: new Date(START - ageMs).toISOString(),
})

async function begin($: Engine) {
  await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
}

async function bandText($: Engine, surface: (typeof SURFACES)[number]) {
  const ui = await $.ui.mount({ plugin: 'waggle', surface, ...BAND })
  const texts = await ui.findAll({ type: 'Text' })
  return { ui, text: texts.map(t => t.text).join('') }
}

const at = (ms: number) => new Date(ms).toISOString()
const mountBand = ($: Engine, surface: (typeof SURFACES)[number], props: object = {}) =>
  $.ui.mount({ plugin: 'waggle', surface, ...BAND, props: { ...BAND.props, ...props } })

describe('the band', () => {
  for (const surface of SURFACES) {
    scenario(`${surface}: no open ask draws nothing`, async $ => {
      await begin($)
      expect(await (await mountBand($, surface)).findAll({ type: 'Text' })).toHaveLength(0)
    })

    scenario(`${surface}: no open ask but asks in other sessions shows the queue line`, async ($, w) => {
      w.other_open_count = 1
      await begin($)
      const { text } = await bandText($, surface)
      expect(text).toContain('1 request waiting for you in other sessions')
    })

    scenario(`${surface}: an ask under 60 s old draws nothing`, async ($, w) => {
      w.open_ask = askAt(30_000)
      await begin($)
      expect(await (await mountBand($, surface)).findAll({ type: 'Text' })).toHaveLength(0)
    })

    scenario(`${surface}: between 1 and 10 minutes a dim reminder with the age and an open button`, async ($, w) => {
      w.open_ask = askAt(3 * 60_000)
      await begin($)
      const { ui, text } = await bandText($, surface)
      expect(text).toContain('still waiting on your answer · 3m')
      expect(text).not.toContain('Checkout')
      expect(await ui.find({ type: 'Button', key: 'open' })).toBeDefined()
      expect(await ui.find({ type: 'Button', key: 'queue' })).toBeUndefined()
    })

    scenario(`${surface}: after 10 minutes Waggle's line with the title and age`, async ($, w) => {
      w.open_ask = askAt(12 * 60_000)
      await begin($)
      const { text } = await bandText($, surface)
      expect(text).toContain('Waggle · waiting on your answer · Checkout: one page or two steps? · 12m')
    })

    scenario(`${surface}: other sessions add a count and a queue button that opens the queue`, async ($, w) => {
      w.open_ask = askAt(3 * 60_000)
      w.other_open_count = 2
      await begin($)
      const { ui, text } = await bandText($, surface)
      expect(text).toContain('+2 in other sessions')
      await ui.press({ key: 'queue' })
      expect(w.calls.at(-1)?.slice(2)).toEqual(['open'])
    })

    scenario(`${surface}: the open button opens Waggle on this ask`, async ($, w) => {
      w.open_ask = askAt(3 * 60_000)
      await begin($)
      const { ui } = await bandText($, surface)
      await ui.press({ key: 'open' })
      expect(w.calls.at(-1)?.slice(2)).toEqual(['open', '--case', 'c_1'])
    })

    scenario(`${surface}: an answer shows past the turn, until the next prompt`, async ($, w, clock) => {
      w.open_ask = askAt(3 * 60_000)
      await begin($)
      await clock.advance(300)
      w.open_ask = null
      w.answer = { case_id: 'c_1', title: 'Checkout', choice: 'Two steps', note: 'Keep the order summary visible', answered_at: at(START) }
      await clock.advance(21_000)
      const { text } = await bandText($, surface)
      expect(text).toContain('Waggle · you chose Two steps · "Keep the order summary visible"')
      await $.turn.complete({ reason: 'answer' } as never)
      expect((await bandText($, surface)).text).toContain('you chose Two steps')
      await $.prompt.submit({ text: 'next' } as never)
      expect(await (await mountBand($, surface)).findAll({ type: 'Text' })).toHaveLength(0)
    })
  }

  scenario('an answer line is cut to the width of the band', async ($, w, clock) => {
    await begin($)
    await clock.advance(300)
    w.answer = { case_id: 'c_1', title: 'T', choice: 'Two steps', note: 'x'.repeat(300), answered_at: at(START) }
    await clock.advance(21_000)
    const { text } = await bandText($, 'terminal')
    expect(text.length).toBeLessThanOrEqual(98)
    expect(text.endsWith('…')).toBe(true)
  })

  scenario('an answer that was there before the session loaded is not shown', async ($, w) => {
    w.answer = { case_id: 'c_0', title: 'T', choice: 'Old', note: null, answered_at: at(START - 3600_000) }
    await begin($)
    expect(await (await mountBand($, 'terminal')).findAll({ type: 'Text' })).toHaveLength(0)
    expect(w.toasts).toEqual([])
  })

  scenario('a survey keeps the band', async ($, w) => {
    w.open_ask = askAt(12 * 60_000)
    await begin($)
    expect(await (await mountBand($, 'terminal', { hasSurvey: true })).findAll({ type: 'Text' })).toHaveLength(0)
  })

  scenario('Waggle missing: nothing drawn, and the mod keeps trying later', async ($, w, clock) => {
    w.isMissing = true
    w.open_ask = askAt(12 * 60_000)
    await begin($)
    const polls = () => w.calls.filter(c => c[2] === 'poll').length
    expect(polls()).toBe(1)
    expect(await (await mountBand($, 'terminal')).findAll({ type: 'Text' })).toHaveLength(0)
    await clock.advance(31_000)
    expect(polls()).toBe(2)
    w.isMissing = false
    await clock.advance(31_000)
    expect((await bandText($, 'terminal')).text).toContain('Waggle · waiting on your answer')
  })

  scenario('the age counts from waiting_since, not from the case creation', async ($, w) => {
    w.open_ask = { ...askAt(60 * 60_000), waiting_since: at(START - 2 * 60_000) }
    await begin($)
    expect((await bandText($, 'terminal')).text).toContain('still waiting on your answer · 2m')
  })

  scenario('an older daemon without waiting_since falls back to created_at', async ($, w) => {
    w.open_ask = askAt(60 * 60_000)
    await begin($)
    expect((await bandText($, 'terminal')).text).toContain('Waggle · waiting on your answer · Checkout: one page or two steps? · 1h')
  })

  scenario('a new round after an answer ends the answer line', async ($, w, clock) => {
    w.answer = { case_id: 'c_1', title: 'T', choice: 'Two steps', note: null, answered_at: at(START + 1_000) }
    w.open_ask = null
    await begin($)
    await clock.advance(300)
    w.answer = { case_id: 'c_1', title: 'T', choice: 'Two steps', note: null, answered_at: at(START + 2_000) }
    await clock.advance(21_000)
    expect((await bandText($, 'terminal')).text).toContain('you chose Two steps')
    // The case was created long before the answer; only the new round's waiting_since is later.
    w.open_ask = { ...askAt(60 * 60_000), waiting_since: at(START + 60_000) }
    await clock.advance(21_000)
    expect((await bandText($, 'terminal')).text).not.toContain('you chose')
  })

  scenario('the age moves as time passes, with no new answer from the daemon', async ($, w, clock) => {
    w.open_ask = askAt(9 * 60_000)
    await begin($)
    expect((await bandText($, 'terminal')).text).toContain('still waiting')
    await clock.advance(61_000)
    expect((await bandText($, 'terminal')).text).toContain('Waggle · waiting on your answer')
  })
})

describe('the toast', () => {
  scenario('an answer after load toasts "Answered in Waggle: <choice>" once', async ($, w, clock) => {
    w.open_ask = askAt(3 * 60_000)
    await begin($)
    await clock.advance(300)
    w.open_ask = null
    w.answer = { case_id: 'c_1', title: 'T', choice: 'Two steps', note: null, answered_at: at(START) }
    await clock.advance(21_000)
    await clock.advance(21_000)
    expect(w.toasts).toEqual(['Answered in Waggle: Two steps'])
  })

  scenario('a note-only answer toasts the start of the note', async ($, w, clock) => {
    await begin($)
    await clock.advance(300)
    w.answer = { case_id: 'c_1', title: 'T', choice: null, note: 'Make it a list please', answered_at: at(START) }
    await clock.advance(21_000)
    expect(w.toasts).toEqual(['Answered in Waggle: Make it a list please'])
  })
})

describe('live state', () => {
  scenario('turn, prompt and tool events are reported; no prompt text, only tool names', async ($, w, clock) => {
    await begin($)
    await $.prompt.submit({ text: 'my secret prompt about the payroll' } as never)
    await $.turn.start({ text: 'my secret prompt about the payroll', turnId: 't1' })
    await $.tool.call({ tool: 'Bash', command: 'echo secret-command' } as never)
    await $.tool.call({ tool: 'Edit', file_path: '/secret/path' } as never)
    await clock.advance(1_500)
    await $.turn.complete({ reason: 'answer', turnId: 't1' } as never)
    await clock.advance(10)
    const reports = w.calls.filter(c => c[2] === 'report').map(c => c.slice(3).join(' '))
    const events = reports.map(r => /--event (\S+)/.exec(r)?.[1])
    expect(events).toEqual(['prompt.submit', 'turn.start', 'tool.call', 'turn.complete'])
    expect(reports.every(r => r.startsWith('--session sess-test'))).toBe(true)
    // Two tool calls in one burst are one report: the count and the last tool's name.
    expect(reports[2]).toBe('--session sess-test --event tool.call --count 2 --tool Edit')
    const everything = JSON.stringify(w.calls)
    expect(everything).not.toContain('payroll')
    expect(everything).not.toContain('secret-command')
    expect(everything).not.toContain('/secret/path')
  })

  scenario('a subagent turn does not end the session turn', async ($, w, clock) => {
    await begin($)
    await $.turn.complete({ reason: 'answer', turnId: 't2', agentId: 'agent-1' } as never)
    await clock.advance(10)
    expect(w.calls.filter(c => c[2] === 'report')).toHaveLength(0)
  })
})

describe('subagent tool calls', () => {
  scenario('a subagent tool call after the turn ended does not report the session as working', async ($, w, clock) => {
    await begin($)
    await $.turn.start({ text: 'go', turnId: 't1' })
    await $.turn.complete({ reason: 'answer', turnId: 't1' } as never)
    await $.tool.call({ tool: 'Bash', command: 'ls', agentId: 'agent-1' } as never)
    await clock.advance(1_500)
    const events = w.calls.filter(c => c[2] === 'report').map(c => /--event (\S+)/.exec(c.slice(3).join(' '))?.[1])
    expect(events).toEqual(['turn.start', 'turn.complete'])
  })
})

describe('nudge', () => {
  const nudge = { case_id: 'c_1', text: 'Waggle: the human answered "T". Call waggle_check with case_id c_1 now.' }

  scenario('a nudge from the daemon is submitted as a prompt, once per window', async ($, w, clock) => {
    await begin($)
    await clock.advance(300)
    w.nudge = nudge
    await clock.advance(21_000)
    expect(w.submitted).toEqual([nudge.text])
    w.nudge = nudge // the daemon's window restarted; the mod's own window still holds
    await clock.advance(21_000)
    expect(w.submitted).toEqual([nudge.text])
    await clock.advance(61_000)
    w.nudge = nudge
    await clock.advance(21_000)
    expect(w.submitted).toEqual([nudge.text, nudge.text])
  })

  scenario('a prompt that did not enter is reported back as failed', async ($, w, clock) => {
    w.dropSubmit = true
    await begin($)
    await clock.advance(300)
    w.nudge = nudge
    await clock.advance(21_000)
    const failed = w.calls.filter(c => c[2] === 'report' && c.includes('nudge.failed'))
    expect(failed).toHaveLength(1)
    expect(failed[0]?.slice(-2)).toEqual(['--case', 'c_1'])
  })
})
