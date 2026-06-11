import { ALL_AGENT_TYPES } from "@/lib/types"

import type { ReferenceAttrs } from "./types"

// The reference uri grammar, shared by two consumers: editor draft restore
// (from-prompt-blocks.ts) and transcript badge rendering
// (ai-elements/markdown-link.tsx). Mirrors the schemes the adapters emit
// (suggestion/adapters.ts) and the node's allow-list (nodes/reference-node.ts).
const SESSION_URI = /^codeg:\/\/session\/(.+)$/i
const COMMIT_URI = /^codeg:\/\/commit\/.*@(.+)$/i

/**
 * Parse a composer reference uri (`file://` / `codeg://…`) back into
 * {@link ReferenceAttrs}, or null when it isn't a recognized reference scheme
 * (in which case the caller treats it as a plain link / attachment).
 *
 * `label` is the human-readable text (a sent resource's name, or a markdown
 * link's text); it falls back to the uri basename or `#id` when empty.
 */
export function parseCodegReferenceUri(
  uri: string,
  label: string
): ReferenceAttrs | null {
  const lower = uri.toLowerCase()

  if (lower.startsWith("file:")) {
    const base = fileBaseName(uri)
    return {
      refType: "file",
      id: base || uri,
      label: label || base || uri,
      uri,
      meta: { fileKind: "file" },
    }
  }

  const session = uri.match(SESSION_URI)
  if (session) {
    const id = session[1]
    // New format is `codeg://session/<agent_type>_<external_id>`. Agent types
    // themselves contain underscores (claude_code, open_code, open_claw), so the
    // type is recovered by prefix match against the known set — never by
    // splitting on the first `_`. A legacy all-numeric id (or any opaque token)
    // matches no prefix and degrades to a session badge without an agent icon.
    const agentType = ALL_AGENT_TYPES.find((type) => id.startsWith(`${type}_`))
    return {
      refType: "session",
      id,
      label: label || `#${id}`,
      uri,
      meta: agentType ? { agentType } : null,
    }
  }

  const commit = uri.match(COMMIT_URI)
  if (commit) {
    const hash = commit[1]
    const shortHash = hash.slice(0, 7)
    return {
      refType: "commit",
      id: hash,
      label: label || shortHash,
      uri,
      meta: { shortHash },
    }
  }

  return null
}

/** Best-effort basename of a `file://` (or any path-shaped) uri. */
function fileBaseName(uri: string): string {
  const path = uri.replace(/^[a-z]+:\/+/i, "")
  const last = path.split("/").filter(Boolean).pop() ?? ""
  try {
    return decodeURIComponent(last)
  } catch {
    return last
  }
}
