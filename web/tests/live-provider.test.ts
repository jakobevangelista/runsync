import { describe, expect, it, vi } from "vite-plus/test";
import { runLiveClient } from "../src/components/LiveProvider";
import type { ActivityAction } from "../src/lib/activity-store";
import type { LiveSession } from "../src/lib/contracts";
import { fixtureReplayAfterEnvelopeId, fixtureRoute, fixtureSnapshot } from "../src/lib/fixtures";

function liveSession(): LiveSession {
  return {
    viewerToken: "viewer",
    expiresAt: new Date(Date.now() + 300_000).toISOString(),
    apiPublicUrl: "https://api.example.test",
    channelSlug: "live",
    mapboxAccessToken: "",
    replayAfterEnvelopeId: fixtureReplayAfterEnvelopeId,
    snapshot: fixtureSnapshot,
    route: fixtureRoute,
  };
}

describe("live client replay recovery", () => {
  it("starts at bootstrap high-water and advances only from a valid matching SSE ID", async () => {
    const controller = new AbortController();
    const cursor = { current: undefined as string | undefined };
    const seenHeaders: Array<string | null> = [];
    let call = 0;
    const fetcher = vi.fn<typeof fetch>(async (_input, init) => {
      call += 1;
      if (call === 1) return Response.json(liveSession());
      seenHeaders.push(new Headers(init?.headers).get("Last-Event-ID"));
      if (call === 2) {
        const sample = fixtureSnapshot.latest!;
        return new Response(
          `id: ${sample.envelopeId}\nevent: sample\ndata: ${JSON.stringify(sample)}\n\n`,
          { status: 200 },
        );
      }
      controller.abort();
      return new Response("", { status: 200 });
    });

    await runLiveClient(
      "overlay",
      controller.signal,
      vi.fn<(action: ActivityAction) => void>(),
      vi.fn(),
      cursor,
      { fetcher, waitForRetry: async () => {}, retryDelay: () => 0 },
    );

    expect(fixtureSnapshot.latest!.envelopeId).not.toBe(fixtureReplayAfterEnvelopeId);
    expect(seenHeaders).toEqual([fixtureReplayAfterEnvelopeId, fixtureSnapshot.latest!.envelopeId]);
  });

  it("backs off across a reset and a failed replacement bootstrap", async () => {
    const controller = new AbortController();
    const waits: number[] = [];
    let call = 0;
    const fetcher = vi.fn<typeof fetch>(async () => {
      call += 1;
      if (call === 1) return Response.json(liveSession());
      if (call === 2) return new Response("event: reset\ndata: {}\n\n", { status: 200 });
      if (call === 3) throw new Error("bootstrap unavailable");
      controller.abort();
      throw new Error("stopped");
    });

    await runLiveClient(
      "overlay",
      controller.signal,
      vi.fn<(action: ActivityAction) => void>(),
      vi.fn(),
      { current: undefined },
      {
        fetcher,
        retryDelay: (attempt) => attempt,
        waitForRetry: async (milliseconds) => {
          waits.push(milliseconds);
        },
      },
    );

    expect(waits).toEqual([0, 1]);
    expect(call).toBe(4);
  });
});
