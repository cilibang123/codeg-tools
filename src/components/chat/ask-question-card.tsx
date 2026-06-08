"use client"

import { useMemo, useRef, useState } from "react"
import { useTranslations } from "next-intl"
import { Check, HelpCircle, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { cn } from "@/lib/utils"
import type {
  PendingQuestionState,
  QuestionAnswer,
  QuestionSpec,
} from "@/lib/types"

interface AskQuestionCardProps {
  /** The awaiting-answer question set. The shell renders this card only when a
   *  question is pending, so the prop is always present. */
  question: PendingQuestionState
  /** Resolves the parked tool call. Returns a promise so the card can show an
   *  in-flight state and surface a retryable error if the round-trip fails. */
  onAnswer: (questionId: string, answer: QuestionAnswer) => void | Promise<void>
}

/** Strip a trailing " (Recommended)" so it can render as a badge while the
 *  submitted value keeps the agent's original label verbatim. */
function splitRecommended(label: string): {
  text: string
  recommended: boolean
} {
  const m = label.match(/^(.*?)\s*\(recommended\)\s*$/i)
  const text = m?.[1].trim()
  // Only treat "(Recommended)" as a suffix when real text precedes it — a bare
  // "(Recommended)" label keeps its literal text rather than rendering empty.
  return text
    ? { text, recommended: true }
    : { text: label, recommended: false }
}

interface QState {
  /** Selected real-option labels (verbatim). For single-select, ≤ 1. */
  chosen: string[]
  otherActive: boolean
  otherText: string
}

function initialState(questions: QuestionSpec[]): Record<string, QState> {
  const out: Record<string, QState> = {}
  for (const q of questions) {
    out[q.id] = { chosen: [], otherActive: false, otherText: "" }
  }
  return out
}

/** A question is answered once it has a real option or non-empty "Other" text. */
function isAnswered(s: QState | undefined): boolean {
  if (!s) return false
  const hasOther = s.otherActive && s.otherText.trim().length > 0
  return s.chosen.length > 0 || hasOther
}

export function AskQuestionCard({ question, onAnswer }: AskQuestionCardProps) {
  const t = useTranslations("Folder.chat.askQuestion")
  const questions = question.questions
  const [state, setState] = useState<Record<string, QState>>(() =>
    initialState(questions)
  )
  // Active tab in the multi-question layout.
  const [activeId, setActiveId] = useState(() => questions[0]?.id ?? "")
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState(false)
  // Synchronous guard against a double-submit before `submitting` re-renders.
  const inFlight = useRef(false)
  // Tracks which question set the above state belongs to. If the card is reused
  // for a different set (a new question_id) without remounting, reset so stale
  // selections never carry over — the component stays correct on its own rather
  // than relying on the caller to supply a fresh React key.
  const [renderedId, setRenderedId] = useState(question.question_id)

  // Whether every question has at least one selection — the submit gate.
  const complete = useMemo(
    () => questions.every((q) => isAnswered(state[q.id])),
    [questions, state]
  )

  if (question.question_id !== renderedId) {
    setRenderedId(question.question_id)
    setState(initialState(questions))
    setActiveId(questions[0]?.id ?? "")
    setSubmitting(false)
    setError(false)
    // `inFlight` is intentionally not reset here — refs must not be written
    // during render, and it is only ever true mid-submit. A resolved answer
    // unmounts the card, so the ref is already idle on any real set change.
  }

  const select = (q: QuestionSpec, label: string) => {
    setState((prev) => {
      const s = prev[q.id] ?? { chosen: [], otherActive: false, otherText: "" }
      if (q.multi_select) {
        const has = s.chosen.includes(label)
        return {
          ...prev,
          [q.id]: {
            ...s,
            chosen: has
              ? s.chosen.filter((l) => l !== label)
              : [...s.chosen, label],
          },
        }
      }
      // Single-select: picking a real option clears "Other".
      return { ...prev, [q.id]: { ...s, chosen: [label], otherActive: false } }
    })
    // A single-select pick advances to the next question so a multi-question set
    // reads as a guided sequence. Multi-select must not jump (you may pick
    // several); toggling "Other" must not jump (you still need to type).
    if (!q.multi_select) {
      const idx = questions.findIndex((x) => x.id === q.id)
      const next = questions[idx + 1]
      if (next) setActiveId(next.id)
    }
  }

  const toggleOther = (q: QuestionSpec) => {
    setState((prev) => {
      const s = prev[q.id] ?? { chosen: [], otherActive: false, otherText: "" }
      const nextActive = !s.otherActive
      return {
        ...prev,
        [q.id]: {
          ...s,
          otherActive: nextActive,
          // Single-select: turning on "Other" clears real options.
          chosen: q.multi_select ? s.chosen : nextActive ? [] : s.chosen,
        },
      }
    })
  }

  const setOtherText = (q: QuestionSpec, text: string) => {
    setState((prev) => {
      const s = prev[q.id] ?? { chosen: [], otherActive: false, otherText: "" }
      return { ...prev, [q.id]: { ...s, otherActive: true, otherText: text } }
    })
  }

  // Run an answer/skip round-trip, holding the card in an in-flight state until
  // it resolves. On success the backend's `question_resolved` clears
  // `pendingAskQuestion`, which unmounts this card — so we intentionally stay
  // disabled rather than flash the controls back on. On failure we re-enable and
  // surface a retryable error instead of swallowing it.
  const run = async (answer: QuestionAnswer) => {
    if (inFlight.current) return
    inFlight.current = true
    setSubmitting(true)
    setError(false)
    try {
      await onAnswer(question.question_id, answer)
    } catch {
      setError(true)
      setSubmitting(false)
      inFlight.current = false
    }
  }

  const submit = () => {
    const answers = questions.map((q) => {
      const s = state[q.id]
      const labels = [...(s?.chosen ?? [])]
      if (s?.otherActive && s.otherText.trim()) labels.push(s.otherText.trim())
      return { questionId: q.id, labels }
    })
    void run({ answers, declined: false })
  }

  const skip = () => void run({ answers: [], declined: true })

  // The options + free-text "Other" block for one question, reused by the
  // single-question layout and each tab panel.
  const renderOptions = (q: QuestionSpec) => {
    const s = state[q.id]
    const otherId = `${q.id}-other`
    return (
      <div className="space-y-1.5">
        {q.options.map((opt) => {
          const selected = s?.chosen.includes(opt.label) ?? false
          const { text, recommended } = splitRecommended(opt.label)
          return (
            <button
              key={opt.label}
              type="button"
              aria-pressed={selected}
              disabled={submitting}
              onClick={() => select(q, opt.label)}
              className={cn(
                "flex w-full items-start gap-2 rounded-md border p-2 text-left transition-colors",
                "disabled:cursor-not-allowed disabled:opacity-60",
                selected
                  ? "border-blue-500/70 bg-blue-500/10"
                  : "border-border/60 hover:bg-muted/40"
              )}
            >
              <span
                className={cn(
                  "mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center border",
                  q.multi_select ? "rounded" : "rounded-full",
                  selected
                    ? "border-blue-500 bg-blue-500 text-white"
                    : "border-muted-foreground/40"
                )}
              >
                {selected && <Check className="h-3 w-3" />}
              </span>
              <span className="min-w-0">
                <span className="flex items-center gap-1.5 text-sm font-medium">
                  {text}
                  {recommended && (
                    <Badge variant="secondary" className="shrink-0 text-[10px]">
                      {t("recommended")}
                    </Badge>
                  )}
                </span>
                {opt.description && (
                  <span className="block text-xs text-muted-foreground">
                    {opt.description}
                  </span>
                )}
              </span>
            </button>
          )
        })}

        {/* Host-injected free-text "Other" — always available. */}
        <button
          type="button"
          aria-pressed={s?.otherActive ?? false}
          disabled={submitting}
          onClick={() => toggleOther(q)}
          className={cn(
            "flex w-full items-center gap-2 rounded-md border p-2 text-left transition-colors",
            "disabled:cursor-not-allowed disabled:opacity-60",
            s?.otherActive
              ? "border-blue-500/70 bg-blue-500/10"
              : "border-border/60 hover:bg-muted/40"
          )}
        >
          <span
            className={cn(
              "flex h-4 w-4 shrink-0 items-center justify-center border",
              q.multi_select ? "rounded" : "rounded-full",
              s?.otherActive
                ? "border-blue-500 bg-blue-500 text-white"
                : "border-muted-foreground/40"
            )}
          >
            {s?.otherActive && <Check className="h-3 w-3" />}
          </span>
          <span className="text-sm font-medium">{t("other")}</span>
        </button>
        {s?.otherActive && (
          <input
            id={otherId}
            type="text"
            autoFocus
            disabled={submitting}
            value={s.otherText}
            onChange={(e) => setOtherText(q, e.target.value)}
            placeholder={t("otherPlaceholder")}
            className="w-full rounded-md border border-border/60 bg-background px-2 py-1.5 text-sm outline-none focus:border-blue-500/70 disabled:cursor-not-allowed disabled:opacity-60"
          />
        )}
      </div>
    )
  }

  const isMulti = questions.length > 1

  return (
    // Capped to the viewport (title + footer pinned, body scrolls) so a tall set
    // — many questions, long localized text, or a short window — never covers
    // the whole message list and always keeps Submit/Skip reachable.
    <div className="mb-2 flex max-h-[88svh] flex-col rounded-xl border border-blue-500/30 bg-card p-3 shadow-lg">
      <div className="flex shrink-0 items-center gap-1.5 text-sm font-medium">
        <HelpCircle className="h-4 w-4 shrink-0 text-blue-500" />
        <span>{t("title")}</span>
      </div>

      {isMulti ? (
        <Tabs
          value={activeId}
          onValueChange={setActiveId}
          className="mt-2 flex min-h-0 flex-1 flex-col"
        >
          <TabsList variant="line" className="w-full shrink-0 justify-start">
            {questions.map((q) => {
              const done = isAnswered(state[q.id])
              return (
                <TabsTrigger
                  key={q.id}
                  value={q.id}
                  disabled={submitting}
                  data-answered={done ? "true" : "false"}
                  className="min-w-0 gap-1 data-[answered=true]:text-blue-600 dark:data-[answered=true]:text-blue-400"
                >
                  <span className="truncate">{q.header}</span>
                  {done && (
                    <Check className="size-3.5 shrink-0 text-blue-500" />
                  )}
                </TabsTrigger>
              )
            })}
          </TabsList>
          {questions.map((q) => (
            <TabsContent
              key={q.id}
              value={q.id}
              className="mt-2 min-h-0 flex-1 overflow-y-auto pr-1"
            >
              <div className="space-y-2 rounded-md border border-border/60 bg-muted/10 p-2.5">
                <p className="text-sm text-foreground/90">{q.question}</p>
                {renderOptions(q)}
              </div>
            </TabsContent>
          ))}
        </Tabs>
      ) : (
        <div className="mt-2 min-h-0 flex-1 space-y-3 overflow-y-auto pr-1">
          {questions.map((q) => (
            <div
              key={q.id}
              className="space-y-2 rounded-md border border-border/60 bg-muted/10 p-2.5"
            >
              <div className="flex items-start gap-2">
                <Badge
                  variant="outline"
                  className="mt-0.5 shrink-0 text-[10px]"
                >
                  {q.header}
                </Badge>
                <p className="text-sm text-foreground/90">{q.question}</p>
              </div>
              {renderOptions(q)}
            </div>
          ))}
        </div>
      )}

      <div className="mt-3 flex shrink-0 items-center justify-end gap-2">
        {error && (
          <span role="alert" className="mr-auto text-xs text-destructive">
            {t("submitError")}
          </span>
        )}
        <Button variant="ghost" size="sm" onClick={skip} disabled={submitting}>
          {t("skip")}
        </Button>
        <Button size="sm" disabled={!complete || submitting} onClick={submit}>
          {submitting && <Loader2 className="mr-1.5 size-3.5 animate-spin" />}
          {t("submit")}
        </Button>
      </div>
    </div>
  )
}
