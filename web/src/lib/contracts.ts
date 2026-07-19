import { z } from "zod";

export const UUID = z.uuid();
export const mapboxAccessTokenSchema = z
  .string()
  .refine((token) => token === "" || token.startsWith("pk."), {
    message: "must be empty or start with pk.",
  });

export const sampleSchema = z.object({
  envelopeId: UUID,
  phoneReceivedAt: z.iso.datetime(),
  serverReceivedAt: z.iso.datetime().optional(),
  protocolVersion: z.number().int(),
  sequence: z.number().int().nonnegative(),
  state: z.number().int().min(0).max(4),
  activityStartEpochSeconds: z.number().int().optional(),
  elapsedTimeMilliseconds: z.number().int().nonnegative().optional(),
  distanceDecimeters: z.number().int().nonnegative().optional(),
  speedMillimetersPerSecond: z.number().int().nonnegative().optional(),
  heartRateBPM: z
    .number()
    .int()
    .nonnegative()
    .max(300)
    .transform((value) => (value === 0 ? undefined : value))
    .optional(),
  cadenceRPM: z.number().int().min(0).max(300).optional(),
  latitudeMicrodegrees: z.number().int().min(-90_000_000).max(90_000_000).optional(),
  longitudeMicrodegrees: z.number().int().min(-180_000_000).max(180_000_000).optional(),
  gpsQuality: z.number().int().min(0).max(4).optional(),
  altitudeDecimeters: z.number().int().optional(),
  totalAscentMeters: z.number().int().nonnegative().optional(),
});

export const snapshotSchema = z.object({
  channelId: UUID,
  slug: z.string().min(1),
  activityId: UUID.nullish(),
  status: z.string(),
  latest: sampleSchema.nullish(),
  latestSampleAgeMilliseconds: z.number().int().nonnegative().nullish(),
  route: z.array(sampleSchema),
  serverTime: z.iso.datetime(),
});

export const routePointSchema = z.object({
  envelopeId: UUID,
  phoneReceivedAt: z.iso.datetime(),
  latitudeMicrodegrees: z.number().int().min(-90_000_000).max(90_000_000),
  longitudeMicrodegrees: z.number().int().min(-180_000_000).max(180_000_000),
  gpsQuality: z.number().int().optional(),
});

export const fullRouteSchema = z.object({
  channelId: UUID,
  activityId: UUID.nullish(),
  locationPolicy: z.enum(["precise", "rounded", "hidden"]),
  points: z.array(routePointSchema).max(5000),
  serverTime: z.iso.datetime(),
});

export const bootstrapSchema = z
  .object({
    snapshot: snapshotSchema,
    route: fullRouteSchema,
    replayAfterEnvelopeId: UUID.nullable(),
  })
  .superRefine((bootstrap, context) => {
    if (
      bootstrap.snapshot.channelId !== bootstrap.route.channelId ||
      (bootstrap.snapshot.activityId ?? null) !== (bootstrap.route.activityId ?? null)
    ) {
      context.addIssue({ code: "custom", message: "bootstrap identities must match" });
    }
  });

export const sessionSchema = z.object({
  viewerToken: z.string().min(1),
  expiresAt: z.iso.datetime(),
  apiPublicUrl: z.url(),
  channelSlug: z.string().min(1),
  mapboxAccessToken: mapboxAccessTokenSchema,
  replayAfterEnvelopeId: UUID.nullable(),
  snapshot: snapshotSchema,
  route: fullRouteSchema,
});

export type Sample = z.infer<typeof sampleSchema>;
export type Snapshot = z.infer<typeof snapshotSchema>;
export type RoutePoint = z.infer<typeof routePointSchema>;
export type FullRoute = z.infer<typeof fullRouteSchema>;
export type Bootstrap = z.infer<typeof bootstrapSchema>;
export type LiveSession = z.infer<typeof sessionSchema>;
export type Units = "imperial" | "metric";
export type PaceMode = "rolling" | "average";
export type ConnectionState = "connecting" | "live" | "reconnecting" | "stale" | "ended" | "error";
