import { describe, expect, it } from "vitest"

import { parseCodegReferenceUri } from "./reference-uri"

describe("parseCodegReferenceUri", () => {
  it("returns null for non-reference schemes", () => {
    expect(parseCodegReferenceUri("https://example.com", "x")).toBeNull()
    expect(parseCodegReferenceUri("data:text/plain,abc", "x")).toBeNull()
    expect(parseCodegReferenceUri("codeg://unknown/1", "x")).toBeNull()
  })

  it("parses a file uri, falling back to the basename when label is empty", () => {
    expect(
      parseCodegReferenceUri("file:///repo/deep/name.ts", "")
    ).toMatchObject({
      refType: "file",
      id: "name.ts",
      label: "name.ts",
      uri: "file:///repo/deep/name.ts",
      meta: { fileKind: "file" },
    })
  })

  it("parses a new-format session uri, recovering the agent type", () => {
    expect(
      parseCodegReferenceUri("codeg://session/codex_abc123", "My chat")
    ).toMatchObject({
      refType: "session",
      id: "codex_abc123",
      label: "My chat",
      uri: "codeg://session/codex_abc123",
      meta: { agentType: "codex" },
    })
  })

  it("never splits an agent type on its first underscore", () => {
    // claude_code / open_code / open_claw contain underscores; a naive first-`_`
    // split would yield "claude" / "open". The whole `<type>_<external_id>` is
    // the id and the full type is recovered by prefix match.
    expect(
      parseCodegReferenceUri("codeg://session/claude_code_sess-9", "")
    ).toMatchObject({
      id: "claude_code_sess-9",
      meta: { agentType: "claude_code" },
    })
    expect(
      parseCodegReferenceUri("codeg://session/open_code_x", "")?.meta
    ).toEqual({ agentType: "open_code" })
    expect(
      parseCodegReferenceUri("codeg://session/open_claw_y", "")?.meta
    ).toEqual({ agentType: "open_claw" })
  })

  it("treats a legacy numeric session id as opaque (no agent icon)", () => {
    expect(
      parseCodegReferenceUri("codeg://session/123", "Login")
    ).toMatchObject({
      refType: "session",
      id: "123",
      label: "Login",
      uri: "codeg://session/123",
      meta: null,
    })
  })

  it("treats a non-agent-prefixed token as a plain session id", () => {
    expect(
      parseCodegReferenceUri("codeg://session/randomtoken", "")
    ).toMatchObject({ refType: "session", id: "randomtoken", meta: null })
  })

  it("falls back to #id for an empty session label", () => {
    expect(parseCodegReferenceUri("codeg://session/123", "")?.label).toBe(
      "#123"
    )
  })

  it("parses a commit uri, deriving the short hash", () => {
    expect(
      parseCodegReferenceUri("codeg://commit/%2Frepo@abc1234def5678", "abc1234")
    ).toMatchObject({
      refType: "commit",
      id: "abc1234def5678",
      label: "abc1234",
      uri: "codeg://commit/%2Frepo@abc1234def5678",
      meta: { shortHash: "abc1234" },
    })
  })
})
