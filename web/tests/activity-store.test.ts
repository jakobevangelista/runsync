import { describe, expect, it } from "vite-plus/test";
import { activityReducer, initialActivityState } from "../src/lib/activity-store";
import { fixtureRoute, fixtureSnapshot } from "../src/lib/fixtures";
import { sampleSchema, type LiveSession, type Sample } from "../src/lib/contracts";

const session: LiveSession = {
  viewerToken: "viewer",
  expiresAt: "2026-07-12T18:47:12.410Z",
  apiPublicUrl: "https://api.example.test",
  channelSlug: "live",
  mapboxAccessToken: "",
  replayAfterEnvelopeId: fixtureRoute.points[0]!.envelopeId,
  snapshot: fixtureSnapshot,
  route: fixtureRoute,
};

function sample(
  id: string,
  sequence: number,
  elapsed: number,
  distance: number,
  state = 1,
): Sample {
  return {
    envelopeId: id,
    phoneReceivedAt: new Date(Date.UTC(2026, 6, 12, 18, 42, sequence)).toISOString(),
    protocolVersion: 1,
    sequence,
    state,
    elapsedTimeMilliseconds: elapsed,
    distanceDecimeters: distance,
  };
}

describe("activity reducer", () => {
  it("bootstraps, deduplicates route points, and retains final data", () => {
    const route = { ...fixtureRoute, points: [...fixtureRoute.points, fixtureRoute.points[0]!] };
    let state = activityReducer(initialActivityState, {
      type: "bootstrap",
      session: { ...session, route },
    });
    expect(state.route).toHaveLength(4);
    state = activityReducer(state, { type: "sample", sample: fixtureSnapshot.latest! });
    expect(state.route).toHaveLength(4);
    state = activityReducer(state, {
      type: "sample",
      sample: {
        ...sample("d4712cf4-d7ed-4772-a0dc-8e58a51b08b9", 13, 760_000, 26_500, 4),
        heartRateBPM: undefined,
      },
    });
    expect(state.connection).toBe("ended");
    expect(state.latest?.heartRateBPM).toBe(148);
  });

  it("calculates a bounded rolling pace and freezes it while paused", () => {
    let state = activityReducer(initialActivityState, {
      type: "sample",
      sample: sample("877955c3-ff64-401b-aa41-cf3f74a83ab9", 1, 100_000, 5000),
    });
    state = activityReducer(state, {
      type: "sample",
      sample: sample("aeddb7b7-aa73-4455-9adf-0df51b1288c9", 2, 110_000, 5400),
    });
    expect(state.rollingPace).toBe(0.25);
    const paused = activityReducer(state, {
      type: "sample",
      sample: sample("94088563-1928-453f-a6cd-6d431ed875f1", 3, 120_000, 6000, 2),
    });
    expect(paused.rollingPace).toBe(0.25);
  });

  it("uses the cumulative point nearest ten seconds without an immature speed fallback", () => {
    let state = activityReducer(initialActivityState, {
      type: "sample",
      sample: {
        ...sample("877955c3-ff64-401b-aa41-cf3f74a83ab9", 1, 0, 0),
        speedMillimetersPerSecond: 4000,
      },
    });
    expect(state.rollingPace).toBeUndefined();
    state = activityReducer(state, {
      type: "sample",
      sample: sample("aeddb7b7-aa73-4455-9adf-0df51b1288c9", 2, 20_000, 1000),
    });
    state = activityReducer(state, {
      type: "sample",
      sample: sample("94088563-1928-453f-a6cd-6d431ed875f1", 3, 30_000, 1400),
    });
    expect(state.rollingPace).toBe(0.25);
  });

  it("normalizes API heart rate zero and preserves the prior valid reading", () => {
    const zeroHeartRate = sampleSchema.parse({
      ...sample("d4712cf4-d7ed-4772-a0dc-8e58a51b08b9", 13, 760_000, 26_500),
      heartRateBPM: 0,
    });
    expect(zeroHeartRate.heartRateBPM).toBeUndefined();
    const state = activityReducer(
      activityReducer(initialActivityState, { type: "bootstrap", session }),
      { type: "sample", sample: zeroHeartRate },
    );
    expect(state.latest?.heartRateBPM).toBe(148);
  });

  it("tracks delayed replay samples without regressing latest state and orders their route points", () => {
    const newest = {
      ...sample("94088563-1928-453f-a6cd-6d431ed875f1", 3, 30_000, 1400, 4),
      heartRateBPM: 170,
      latitudeMicrodegrees: 37_000_300,
      longitudeMicrodegrees: -122_000_300,
    };
    let state = activityReducer(initialActivityState, { type: "sample", sample: newest });
    const delayed = {
      ...sample("aeddb7b7-aa73-4455-9adf-0df51b1288c9", 2, 20_000, 1000),
      heartRateBPM: 120,
      latitudeMicrodegrees: 37_000_200,
      longitudeMicrodegrees: -122_000_200,
    };
    state = activityReducer(state, { type: "sample", sample: delayed });

    expect(state.latest).toMatchObject({ sequence: 3, state: 4, heartRateBPM: 170 });
    expect(state.connection).toBe("ended");
    expect(state.latestEnvelopeId).toBe(delayed.envelopeId);
    expect(state.seenEnvelopeIds.has(delayed.envelopeId)).toBe(true);
    expect(state.route.map((point) => point.envelopeId)).toEqual([
      delayed.envelopeId,
      newest.envelopeId,
    ]);
  });

  it("accepts a chronologically newer sample after a watch sequence reset", () => {
    const beforeReset = sample("94088563-1928-453f-a6cd-6d431ed875f1", 500, 30_000, 1400);
    let state = activityReducer(initialActivityState, { type: "sample", sample: beforeReset });
    const afterReset = {
      ...sample("aeddb7b7-aa73-4455-9adf-0df51b1288c9", 1, 31_000, 1440),
      phoneReceivedAt: new Date(Date.parse(beforeReset.phoneReceivedAt) + 1000).toISOString(),
    };

    state = activityReducer(state, { type: "sample", sample: afterReset });

    expect(state.latest?.envelopeId).toBe(afterReset.envelopeId);
    expect(state.latest?.sequence).toBe(1);
  });

  it("preserves the route origin and the newest points when applying the cap", () => {
    const points = Array.from({ length: 5001 }, (_, index) => ({
      envelopeId: `point-${index}`,
      phoneReceivedAt: new Date(index * 1000).toISOString(),
      latitudeMicrodegrees: 37_000_000 + index,
      longitudeMicrodegrees: -122_000_000 + index,
    }));
    const state = activityReducer(initialActivityState, {
      type: "bootstrap",
      session: { ...session, route: { ...fixtureRoute, points } },
    });

    expect(state.route).toHaveLength(5000);
    expect(state.route[0]?.envelopeId).toBe("point-0");
    expect(state.route[1]?.envelopeId).toBe("point-2");
    expect(state.route.at(-1)?.envelopeId).toBe("point-5000");
  });

  it("resets all activity-scoped data when the snapshot activity changes", () => {
    const first = activityReducer(initialActivityState, { type: "bootstrap", session });
    const next = activityReducer(first, {
      type: "bootstrap",
      session: {
        ...session,
        snapshot: {
          ...fixtureSnapshot,
          activityId: "485cc805-e423-4dbf-bfa6-ddc0d07df784",
          latest: null,
        },
        route: { ...fixtureRoute, activityId: "485cc805-e423-4dbf-bfa6-ddc0d07df784", points: [] },
      },
    });
    expect(next.route).toEqual([]);
    expect(next.latest).toBeUndefined();
    expect(next.paceWindow).toEqual([]);
  });

  it("replaces same-activity geometry when the authoritative policy is tightened", () => {
    const precise = activityReducer(initialActivityState, { type: "bootstrap", session });
    const hidden = activityReducer(precise, {
      type: "bootstrap",
      session: {
        ...session,
        snapshot: {
          ...fixtureSnapshot,
          latest: {
            ...fixtureSnapshot.latest!,
            latitudeMicrodegrees: undefined,
            longitudeMicrodegrees: undefined,
          },
        },
        route: { ...fixtureRoute, locationPolicy: "hidden", points: [] },
      },
    });

    expect(hidden.locationPolicy).toBe("hidden");
    expect(hidden.route).toEqual([]);
    expect(hidden.latest?.latitudeMicrodegrees).toBeUndefined();
    expect(hidden.latest?.longitudeMicrodegrees).toBeUndefined();
  });
});
