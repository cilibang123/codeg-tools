import { act, renderHook, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"

// Both status scans are mocked so we can count how many times a window focus
// triggers them across multiple mounted consumers.
vi.mock("@/lib/api", () => ({
  expertsListAllInstallStatuses: vi.fn(),
  officecliSkillListAllInstallStatuses: vi.fn(),
}))

// The hook caches snapshot + focus-listener state at module scope; reset the
// module registry per test so each starts uncached with a fresh refcount.
beforeEach(() => {
  vi.resetModules()
})

async function setup() {
  const api = await import("@/lib/api")
  vi.mocked(api.expertsListAllInstallStatuses).mockResolvedValue([])
  vi.mocked(api.officecliSkillListAllInstallStatuses).mockResolvedValue([])
  const hook = await import("./use-enabled-skill-ids")
  return { api, hook }
}

describe("useEnabledSkillIds — focus refresh coalescing", () => {
  it("runs a single (experts + office) refresh per focus regardless of how many consumers are mounted", async () => {
    const { api, hook } = await setup()
    // Two mounted consumers — e.g. two tiled conversation composers.
    const a = renderHook(() => hook.useEnabledSkillIds("claude_code"))
    const b = renderHook(() => hook.useEnabledSkillIds("codex"))
    await waitFor(() => {
      expect(a.result.current.ready).toBe(true)
      expect(b.result.current.ready).toBe(true)
    })

    vi.mocked(api.expertsListAllInstallStatuses).mockClear()
    vi.mocked(api.officecliSkillListAllInstallStatuses).mockClear()

    // A window focus must coalesce to ONE refresh — not one scan per instance
    // (the pre-fix behavior cleared `inflight` per listener, defeating dedup).
    await act(async () => {
      window.dispatchEvent(new Event("focus"))
      await Promise.resolve()
    })

    await waitFor(() => {
      expect(api.expertsListAllInstallStatuses).toHaveBeenCalledTimes(1)
      expect(api.officecliSkillListAllInstallStatuses).toHaveBeenCalledTimes(1)
    })
  })

  it("detaches the shared listener once the last consumer unmounts", async () => {
    const { api, hook } = await setup()
    const a = renderHook(() => hook.useEnabledSkillIds("claude_code"))
    const b = renderHook(() => hook.useEnabledSkillIds("claude_code"))
    await waitFor(() => expect(a.result.current.ready).toBe(true))

    a.unmount()
    b.unmount()
    vi.mocked(api.expertsListAllInstallStatuses).mockClear()
    vi.mocked(api.officecliSkillListAllInstallStatuses).mockClear()

    await act(async () => {
      window.dispatchEvent(new Event("focus"))
      await Promise.resolve()
    })

    expect(api.expertsListAllInstallStatuses).not.toHaveBeenCalled()
    expect(api.officecliSkillListAllInstallStatuses).not.toHaveBeenCalled()
  })
})
