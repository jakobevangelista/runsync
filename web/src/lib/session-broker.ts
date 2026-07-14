import { fullRouteSchema, sessionSchema, snapshotSchema, type LiveSession } from "./contracts";
import type { ServerConfig } from "./config";
import { fixtureRoute, fixtureSnapshot } from "./fixtures";

type Fetch = typeof fetch;
const BOOTSTRAP_ATTEMPTS = 3;

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
  let bootstrap: { snapshot: unknown; route: unknown } | undefined;
  for (let attempt = 0; attempt < BOOTSTRAP_ATTEMPTS; attempt += 1) {
    const [snapshotResponse, routeResponse] = await Promise.all([
      fetcher(`${config.apiInternalUrl}/v1/channels/${slug}/snapshot`, {
        headers,
        cache: "no-store",
      }),
      fetcher(`${config.apiInternalUrl}/v1/channels/${slug}/route`, {
        headers,
        cache: "no-store",
      }),
    ]);
    if (!snapshotResponse.ok || !routeResponse.ok) throw new Error("live bootstrap fetch failed");
    const snapshot = snapshotSchema.parse(await snapshotResponse.json());
    const route = fullRouteSchema.parse(await routeResponse.json());
    if (
      snapshot.channelId === route.channelId &&
      (snapshot.activityId ?? null) === (route.activityId ?? null)
    ) {
      bootstrap = { snapshot, route };
      break;
    }
  }
  if (!bootstrap) throw new Error("live bootstrap remained inconsistent after 3 attempts");
  return sessionSchema.parse({
    viewerToken: tokenBody.token,
    expiresAt: tokenBody.expiresAt,
    apiPublicUrl: config.apiPublicUrl,
    channelSlug: config.channelSlug,
    mapboxAccessToken: config.mapboxAccessToken,
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
