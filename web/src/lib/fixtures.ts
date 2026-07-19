import type { FullRoute, Snapshot } from "./contracts";

const activityId = "07da0dd8-e84b-42e2-9711-a60770dc3c2f";
const channelId = "8383afd0-8d84-422d-b842-dad0db190fbf";

export const fixtureSnapshot: Snapshot = {
  channelId,
  slug: "live",
  activityId,
  status: "running",
  latestSampleAgeMilliseconds: 800,
  latest: {
    envelopeId: "c1a7c88e-8fa7-446d-aa26-a3ce0ad98f58",
    phoneReceivedAt: "2026-07-12T18:42:12.250Z",
    serverReceivedAt: "2026-07-12T18:42:12.410Z",
    protocolVersion: 1,
    sequence: 12,
    state: 1,
    elapsedTimeMilliseconds: 754000,
    distanceDecimeters: 26340,
    speedMillimetersPerSecond: 3510,
    heartRateBPM: 148,
    latitudeMicrodegrees: 37776920,
    longitudeMicrodegrees: -122417380,
    gpsQuality: 4,
    altitudeDecimeters: 184,
    totalAscentMeters: 42,
  },
  route: [],
  serverTime: "2026-07-12T18:42:12.410Z",
};

export const fixtureRoute: FullRoute = {
  channelId,
  activityId,
  locationPolicy: "precise",
  points: [
    ["8577ced7-6b5e-44d9-83b3-ec65ee0e96e6", 37774920, -122419380],
    ["d3bcdf2a-e0cd-4161-b05f-f926b935d639", 37775620, -122418980],
    ["fc165753-91f6-4b76-9a7c-55cbb11aa2c9", 37776320, -122418180],
    ["c1a7c88e-8fa7-446d-aa26-a3ce0ad98f58", 37776920, -122417380],
  ].map(([envelopeId, latitudeMicrodegrees, longitudeMicrodegrees], index) => ({
    envelopeId: String(envelopeId),
    phoneReceivedAt: `2026-07-12T18:42:${String(index * 4).padStart(2, "0")}.250Z`,
    latitudeMicrodegrees: Number(latitudeMicrodegrees),
    longitudeMicrodegrees: Number(longitudeMicrodegrees),
    gpsQuality: 4,
  })),
  serverTime: "2026-07-12T18:42:12.410Z",
};

export const fixtureReplayAfterEnvelopeId = "8577ced7-6b5e-44d9-83b3-ec65ee0e96e6";
