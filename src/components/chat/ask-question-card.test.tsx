import { fireEvent, render, screen } from "@testing-library/react"
import { NextIntlClientProvider } from "next-intl"
import { describe, expect, it, vi } from "vitest"

import { AskQuestionCard } from "./ask-question-card"
import enMessages from "@/i18n/messages/en.json"
import type { PendingQuestionState, QuestionAnswer } from "@/lib/types"

function renderCard(question: PendingQuestionState, onAnswer = vi.fn()) {
  render(
    <NextIntlClientProvider locale="en" messages={enMessages}>
      <AskQuestionCard question={question} onAnswer={onAnswer} />
    </NextIntlClientProvider>
  )
  return onAnswer
}

/** Render with an explicit (typically async) `onAnswer`, returning the render
 *  result so a test can reach into `container` for the spinner. */
function renderWith(
  question: PendingQuestionState,
  onAnswer: (questionId: string, answer: QuestionAnswer) => void | Promise<void>
) {
  return render(
    <NextIntlClientProvider locale="en" messages={enMessages}>
      <AskQuestionCard question={question} onAnswer={onAnswer} />
    </NextIntlClientProvider>
  )
}

/** A manually-resolvable promise so a test can hold the answer round-trip
 *  "in flight" and assert the card's disabled/spinner state. */
function deferred() {
  let resolve!: () => void
  let reject!: (reason?: unknown) => void
  const promise = new Promise<void>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

const single: PendingQuestionState = {
  question_id: "q-1",
  created_at: "2026-01-01T00:00:00Z",
  questions: [
    {
      id: "qa",
      question: "Which approach?",
      header: "Approach",
      multi_select: false,
      options: [
        { label: "Incremental", description: "smaller diffs" },
        { label: "Rewrite", description: "clean slate" },
      ],
    },
  ],
}

const multi: PendingQuestionState = {
  question_id: "q-2",
  created_at: "2026-01-01T00:00:00Z",
  questions: [
    {
      id: "qb",
      question: "Which modules?",
      header: "Scope",
      multi_select: true,
      options: [
        { label: "auth", description: "" },
        { label: "billing", description: "" },
        { label: "ui", description: "" },
      ],
    },
  ],
}

// Two single-select questions — exercises the tabbed multi-question layout.
const twoSingle: PendingQuestionState = {
  question_id: "q-two",
  created_at: "2026-01-01T00:00:00Z",
  questions: [
    {
      id: "qa",
      question: "First question?",
      header: "First",
      multi_select: false,
      options: [
        { label: "X", description: "" },
        { label: "Y", description: "" },
      ],
    },
    {
      id: "qb",
      question: "Second question?",
      header: "Second",
      multi_select: false,
      options: [
        { label: "P", description: "" },
        { label: "Q", description: "" },
      ],
    },
  ],
}

// First question is multi-select — used to assert it does NOT auto-advance.
const twoMultiFirst: PendingQuestionState = {
  question_id: "q-two-multi",
  created_at: "2026-01-01T00:00:00Z",
  questions: [
    {
      id: "qa",
      question: "First question?",
      header: "First",
      multi_select: true,
      options: [
        { label: "X", description: "" },
        { label: "Y", description: "" },
      ],
    },
    {
      id: "qb",
      question: "Second question?",
      header: "Second",
      multi_select: false,
      options: [
        { label: "P", description: "" },
        { label: "Q", description: "" },
      ],
    },
  ],
}

describe("AskQuestionCard", () => {
  it("submits a single-select choice keyed by question id", () => {
    const onAnswer = renderCard(single)
    fireEvent.click(screen.getByText("Incremental"))
    fireEvent.click(screen.getByRole("button", { name: "Submit" }))
    expect(onAnswer).toHaveBeenCalledWith("q-1", {
      answers: [{ questionId: "qa", labels: ["Incremental"] }],
      declined: false,
    })
  })

  it("disables Submit until something is selected", () => {
    renderCard(single)
    const submit = screen.getByRole("button", { name: "Submit" })
    expect(submit).toBeDisabled()
    fireEvent.click(screen.getByText("Rewrite"))
    expect(submit).not.toBeDisabled()
  })

  it("collects multiple labels in multi-select", () => {
    const onAnswer = renderCard(multi)
    fireEvent.click(screen.getByText("auth"))
    fireEvent.click(screen.getByText("billing"))
    fireEvent.click(screen.getByRole("button", { name: "Submit" }))
    expect(onAnswer).toHaveBeenCalledWith("q-2", {
      answers: [{ questionId: "qb", labels: ["auth", "billing"] }],
      declined: false,
    })
  })

  it("submits the typed Other text as the answer label", () => {
    const onAnswer = renderCard(single)
    fireEvent.click(screen.getByText("Other"))
    fireEvent.change(screen.getByPlaceholderText("Type your answer…"), {
      target: { value: "a third way" },
    })
    fireEvent.click(screen.getByRole("button", { name: "Submit" }))
    expect(onAnswer).toHaveBeenCalledWith("q-1", {
      answers: [{ questionId: "qa", labels: ["a third way"] }],
      declined: false,
    })
  })

  it("single-select Other replaces a prior option choice", () => {
    const onAnswer = renderCard(single)
    fireEvent.click(screen.getByText("Incremental"))
    fireEvent.click(screen.getByText("Other"))
    fireEvent.change(screen.getByPlaceholderText("Type your answer…"), {
      target: { value: "custom" },
    })
    fireEvent.click(screen.getByRole("button", { name: "Submit" }))
    expect(onAnswer).toHaveBeenCalledWith("q-1", {
      answers: [{ questionId: "qa", labels: ["custom"] }],
      declined: false,
    })
  })

  it("skips with a declined answer", () => {
    const onAnswer = renderCard(single)
    fireEvent.click(screen.getByRole("button", { name: "Skip" }))
    expect(onAnswer).toHaveBeenCalledWith("q-1", {
      answers: [],
      declined: true,
    })
  })

  it("disables controls and shows a spinner while answering is in flight", () => {
    const d = deferred()
    const onAnswer = vi.fn(() => d.promise)
    const { container } = renderWith(single, onAnswer)
    fireEvent.click(screen.getByText("Incremental"))
    fireEvent.click(screen.getByRole("button", { name: "Submit" }))
    expect(onAnswer).toHaveBeenCalledTimes(1)
    expect(screen.getByRole("button", { name: "Submit" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Skip" })).toBeDisabled()
    expect(screen.getByText("Incremental").closest("button")).toBeDisabled()
    expect(container.querySelector(".animate-spin")).not.toBeNull()
    d.resolve()
  })

  it("ignores a second submit while one is already in flight", () => {
    const d = deferred()
    const onAnswer = vi.fn(() => d.promise)
    renderWith(single, onAnswer)
    fireEvent.click(screen.getByText("Incremental"))
    const submit = screen.getByRole("button", { name: "Submit" })
    fireEvent.click(submit)
    fireEvent.click(submit)
    expect(onAnswer).toHaveBeenCalledTimes(1)
    d.resolve()
  })

  it("surfaces a retryable error and re-enables controls when answering fails", async () => {
    // A rejecting onAnswer stands in for both a backend failure and the
    // "no connection" path (the context now throws there instead of silently
    // resolving, which would otherwise strand the card in its in-flight state).
    const onAnswer = vi
      .fn()
      .mockRejectedValueOnce(new Error("boom"))
      .mockResolvedValueOnce(undefined)
    renderWith(single, onAnswer)
    fireEvent.click(screen.getByText("Rewrite"))
    fireEvent.click(screen.getByRole("button", { name: "Submit" }))
    // The failure surfaces inline and every control re-enables for a retry.
    const alert = await screen.findByRole("alert")
    expect(alert).toHaveTextContent("Couldn't submit. Please try again.")
    const submit = screen.getByRole("button", { name: "Submit" })
    expect(submit).not.toBeDisabled()
    expect(screen.getByRole("button", { name: "Skip" })).not.toBeDisabled()
    fireEvent.click(submit)
    expect(onAnswer).toHaveBeenCalledTimes(2)
  })

  it('renders a bare "(Recommended)" label literally instead of going empty', () => {
    const onlyRecommended: PendingQuestionState = {
      question_id: "q-3",
      created_at: "2026-01-01T00:00:00Z",
      questions: [
        {
          id: "qc",
          question: "Pick one",
          header: "Pick",
          multi_select: false,
          options: [
            { label: "(Recommended)", description: "" },
            { label: "Other path", description: "" },
          ],
        },
      ],
    }
    const onAnswer = renderCard(onlyRecommended)
    // The literal label is shown (not stripped to empty); selecting it submits
    // the verbatim label.
    fireEvent.click(screen.getByText("(Recommended)"))
    fireEvent.click(screen.getByRole("button", { name: "Submit" }))
    expect(onAnswer).toHaveBeenCalledWith("q-3", {
      answers: [{ questionId: "qc", labels: ["(Recommended)"] }],
      declined: false,
    })
  })

  it("renders one tab per question when there are multiple", () => {
    renderCard(twoSingle)
    expect(screen.getAllByRole("tab")).toHaveLength(2)
  })

  it("auto-advances to the next tab after a single-select pick", () => {
    renderCard(twoSingle)
    expect(screen.getAllByRole("tab")[0]).toHaveAttribute(
      "aria-selected",
      "true"
    )
    // Picking an option on the first tab moves focus to the second.
    fireEvent.click(screen.getByText("X"))
    const tabs = screen.getAllByRole("tab")
    expect(tabs[1]).toHaveAttribute("aria-selected", "true")
    expect(tabs[0]).toHaveAttribute("aria-selected", "false")
    // The second tab's options are now the visible ones.
    expect(screen.getByText("P")).toBeInTheDocument()
  })

  it("does not auto-advance on a multi-select pick", () => {
    renderCard(twoMultiFirst)
    fireEvent.click(screen.getByText("X"))
    // Still on the first tab so further options can be picked.
    expect(screen.getAllByRole("tab")[0]).toHaveAttribute(
      "aria-selected",
      "true"
    )
    expect(screen.getByText("Y")).toBeInTheDocument()
  })

  it("marks a tab as confirmed once it is answered", () => {
    renderCard(twoSingle)
    expect(screen.getAllByRole("tab")[0]).toHaveAttribute(
      "data-answered",
      "false"
    )
    fireEvent.click(screen.getByText("X"))
    expect(screen.getAllByRole("tab")[0]).toHaveAttribute(
      "data-answered",
      "true"
    )
  })

  it("enables Submit only after every tab is answered, then submits all", () => {
    const onAnswer = renderCard(twoSingle)
    const submit = screen.getByRole("button", { name: "Submit" })
    expect(submit).toBeDisabled()
    // Answer tab 1 (auto-advances to tab 2), then answer tab 2.
    fireEvent.click(screen.getByText("X"))
    expect(submit).toBeDisabled()
    fireEvent.click(screen.getByText("P"))
    expect(submit).not.toBeDisabled()
    fireEvent.click(submit)
    expect(onAnswer).toHaveBeenCalledWith("q-two", {
      answers: [
        { questionId: "qa", labels: ["X"] },
        { questionId: "qb", labels: ["P"] },
      ],
      declined: false,
    })
  })

  it("resets selections when the question set is replaced in place", () => {
    // The shell renders the card without a per-question React key, so the card
    // must reset its own state when the question set changes underneath it.
    const onAnswer = vi.fn()
    const { rerender } = render(
      <NextIntlClientProvider locale="en" messages={enMessages}>
        <AskQuestionCard question={single} onAnswer={onAnswer} />
      </NextIntlClientProvider>
    )
    fireEvent.click(screen.getByText("Incremental"))
    expect(screen.getByRole("button", { name: "Submit" })).not.toBeDisabled()
    // Swap in a different question set (new question_id) at the same position.
    rerender(
      <NextIntlClientProvider locale="en" messages={enMessages}>
        <AskQuestionCard question={twoSingle} onAnswer={onAnswer} />
      </NextIntlClientProvider>
    )
    // No stale selection carries over: the new set renders fresh and ungated.
    expect(screen.queryByText("Incremental")).not.toBeInTheDocument()
    expect(screen.getAllByRole("tab")).toHaveLength(2)
    expect(screen.getByRole("button", { name: "Submit" })).toBeDisabled()
  })
})
