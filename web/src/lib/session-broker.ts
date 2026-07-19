import { bootstrapSchema, sessionSchema, type LiveSession } from "./contracts";
import type { ServerConfig } from "./config";
import { fixtureReplayAfterEnvelopeId, fixtureRoute, fixtureSnapshot } from "./fixtures";

type Fetch = typeof fetch;

export async function createLiveSession(
  config: ServerConfig,
  fetcher: Fetch = fetch,
): Promise<LiveSession> {
  if (config.fixtureMode) {
    return sessionSchema.parse({
      viewerToken: "fixture-viewer-token",
      expiresAt: new Date(Date.now() + 300_000).toISOString(),
      apiPublicUrl: config.apiPublicUrl,
      channelSlug: config.channelSlug,
      mapboxAccessToken: config.mapboxAccessToken,
      replayAfterEnvelopeId: fixtureReplayAfterEnvelopeId,
      snapshot: { ...fixtureSnapshot, slug: config.channelSlug },
      route: fixtureRoute,
    });
  }

  const tokenResponse = await fetcher(`${config.apiInternalUrl}/v1/viewer-tokens`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${config.readToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ channelSlug: config.channelSlug, lifetimeSeconds: 300 }),
    cache: "no-store",
  });
  if (!tokenResponse.ok) throw new Error(`viewer token exchange failed (${tokenResponse.status})`);
  const tokenBody = zViewerToken.parse(await tokenResponse.json());
  const headers = { Authorization: `Bearer ${tokenBody.token}` };
  const slug = encodeURIComponent(config.channelSlug);
  const bootstrapResponse = await fetcher(
    `${config.apiInternalUrl}/v1/channels/${slug}/bootstrap`,
    { headers, cache: "no-store" },
  );
  if (!bootstrapResponse.ok) throw new Error("live bootstrap fetch failed");
  const bootstrap = bootstrapSchema.parse(await bootstrapResponse.json());
  return sessionSchema.parse({
    viewerToken: tokenBody.token,
    expiresAt: tokenBody.expiresAt,
    apiPublicUrl: config.apiPublicUrl,
    channelSlug: config.channelSlug,
    mapboxAccessToken: config.mapboxAccessToken,
    replayAfterEnvelopeId: bootstrap.replayAfterEnvelopeId,
    snapshot: bootstrap.snapshot,
    route: bootstrap.route,
  });
}

const zViewerToken = sessionSchema
  .pick({ expiresAt: true })
  .extend({ token: sessionSchema.shape.viewerToken });

export function redactSessionForLog(error: unknown) {
  return error instanceof Error
    ? error.message.replace(/Bearer\s+\S+/gi, "Bearer [redacted]")
    : "unknown error";
}
