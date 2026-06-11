import type { PromptInputBlock } from "@/lib/types"
import { randomUUID } from "@/lib/utils"

import type { InputAttachment } from "../message-input-attachments"
import { parseCodegReferenceUri as parseReferenceUri } from "./reference-uri"
import type { ReferenceAttrs } from "./types"

/**
 * Restore serialization (inverse of {@link "./to-prompt-blocks".docToPromptBlocks}):
 * turn a sent `PromptInputBlock[]` back into editor content + attachments, so a
 * queued message can be re-opened for editing with its badges and attachments
 * intact.
 *
 * The split mirrors the send rule:
 * - `text` blocks → markdown segments replayed into the editor (inline
 *   session/commit/agent/skill references that were serialized *as text* come
 *   back as their text form — only **file** references were structured blocks,
 *   so only they round-trip to badges).
 * - `resource_link` blocks whose uri is a composer scheme (`file:` / `codeg:`)
 *   → reference badge segments.
 * - everything else (`image`, embedded `resource`, non-composer `resource_link`)
 *   → out-of-band attachments.
 *
 * The host replays `segments` in order against a live editor (markdown via
 * `insertMarkdownAtCursor`, references via `insertReference`) and sets
 * `attachments`. Pure and deterministic given an injected `makeId`.
 */
export type RestoreSegment =
  | { kind: "markdown"; text: string }
  | { kind: "reference"; attrs: ReferenceAttrs }

export interface RestoredDraft {
  segments: RestoreSegment[]
  attachments: InputAttachment[]
}

export function blocksToRestoredDraft(
  blocks: PromptInputBlock[],
  makeId: () => string = randomUUID
): RestoredDraft {
  const segments: RestoreSegment[] = []
  const attachments: InputAttachment[] = []

  for (const block of blocks) {
    switch (block.type) {
      case "text": {
        if (block.text.trim().length > 0) {
          segments.push({ kind: "markdown", text: block.text })
        }
        break
      }
      case "resource_link": {
        const attrs = parseReferenceUri(block.uri, block.name)
        if (attrs) {
          segments.push({ kind: "reference", attrs })
        } else {
          attachments.push({
            id: makeId(),
            type: "resource",
            kind: "link",
            uri: block.uri,
            name: block.name,
            mimeType: block.mime_type ?? null,
          })
        }
        break
      }
      case "resource": {
        attachments.push({
          id: makeId(),
          type: "resource",
          kind: "embedded",
          uri: block.uri,
          name: fileBaseName(block.uri) || block.uri,
          mimeType: block.mime_type ?? null,
          text: block.text ?? null,
          blob: block.blob ?? null,
        })
        break
      }
      case "image": {
        attachments.push({
          id: makeId(),
          type: "image",
          data: block.data,
          uri: block.uri ?? null,
          name: imageName(block),
          mimeType: block.mime_type,
        })
        break
      }
    }
  }

  return { segments, attachments }
}

// The reference uri grammar (file:/codeg: → ReferenceAttrs) now lives in
// ./reference-uri, shared with transcript badge rendering. Re-exported here
// under its historical name so existing importers (tests, queue-edit restore)
// keep working.
export { parseReferenceUri }

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

/** Derive a display name for an image block (mirrors the transcript adapter). */
function imageName(
  block: Extract<PromptInputBlock, { type: "image" }>
): string {
  if (block.uri && block.uri.trim().length > 0) {
    const base = fileBaseName(block.uri)
    if (base) return base
  }
  const ext = block.mime_type.split("/")[1]?.split("+")[0] ?? "image"
  return `image.${ext}`
}
