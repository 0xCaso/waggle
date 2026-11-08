// Plain text helpers for the Waggle band. No engine calls here.

export const QUIET_MS = 60_000; // nothing drawn while the Waggle notification is fresh
export const URGENT_MS = 10 * 60_000; // after this the line takes Waggle's colour

export function ageText(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000))
  if (seconds < 60) return 'just now'
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h`
  return `${Math.floor(hours / 24)}d`
}

// Cuts `text` to `max` characters, with an ellipsis, never below 1.
export function clip(text: string, max: number): string {
  const limit = Math.max(1, max)
  return text.length <= limit ? text : `${text.slice(0, Math.max(0, limit - 1)).trimEnd()}…`
}

// How the band looks for one ask: nothing, a dim reminder, or Waggle's own colour.
export type AskTone = 'quiet' | 'dim' | 'urgent'

export function toneFor(ageMs: number): AskTone {
  if (ageMs < QUIET_MS) return 'quiet'
  return ageMs < URGENT_MS ? 'dim' : 'urgent'
}

export type Answer = {
  case_id: string
  title: string
  choice: string | null
  note: string | null
  answered_at: string
}

// "Waggle · you chose Two steps · "Keep the summary visible"", cut to the columns.
export function answerLine(answer: Answer, columns: number): string {
  const head = answer.choice === null ? 'Waggle · you answered' : `Waggle · you chose ${answer.choice}`
  const note = answer.note ? ` · "${answer.note}"` : ''
  return clip(`${head}${note}`, columns)
}

// The toast text: "Answered in Waggle: <choice>" (Claude Code already prefixes the plugin name), or the start of the note.
export function answerToast(answer: Answer): string {
  return `Answered in Waggle: ${answer.choice ?? clip(answer.note ?? 'a note', 40)}`
}
