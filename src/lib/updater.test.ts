import { beforeEach, describe, expect, it, vi } from "vitest"

const call = vi.fn()

vi.mock("@/lib/transport", () => ({
  getTransport: () => ({ call }),
  isDesktop: () => false,
}))

import { waitForServerHealthy } from "@/lib/updater"

describe("waitForServerHealthy", () => {
  beforeEach(() => {
    call.mockReset()
  })

  it("resolves true as soon as /health answers", async () => {
    // First poll fails (server still restarting), second succeeds.
    call.mockRejectedValueOnce(new Error("down")).mockResolvedValueOnce({})

    const healthy = await waitForServerHealthy({
      timeoutMs: 5_000,
      intervalMs: 5,
    })

    expect(healthy).toBe(true)
    expect(call).toHaveBeenCalledWith("health", {}, { timeoutMs: 4000 })
    expect(call).toHaveBeenCalledTimes(2)
  })

  it("resolves false when the server never comes back before the deadline", async () => {
    call.mockRejectedValue(new Error("down"))

    const healthy = await waitForServerHealthy({
      timeoutMs: 30,
      intervalMs: 5,
    })

    expect(healthy).toBe(false)
    expect(call.mock.calls.length).toBeGreaterThan(0)
  })
})
