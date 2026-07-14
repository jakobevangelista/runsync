import { z } from "zod";
import { mapboxAccessTokenSchema, type PaceMode, type Units } from "./contracts";

const environmentSchema = z.object({
  RUNSYNC_API_INTERNAL_URL: z.url(),
  RUNSYNC_API_PUBLIC_URL: z.url(),
  RUNSYNC_API_READ_TOKEN_FILE: z.string().min(1),
  RUNSYNC_CHANNEL_SLUG: z.string().min(1),
  RUNSYNC_OVERLAY_ID: z.uuid(),
  RUNSYNC_DEFAULT_UNITS: z.enum(["imperial", "metric"]).default("imperial"),
  RUNSYNC_DEFAULT_PACE: z.enum(["rolling", "average"]).default("rolling"),
  MAPBOX_ACCESS_TOKEN: mapboxAccessTokenSchema.default(""),
});

export type ServerConfig = {
  apiInternalUrl: string;
  apiPublicUrl: string;
  readToken: string;
  channelSlug: string;
  overlayId: string;
  defaultUnits: Units;
  defaultPace: PaceMode;
  mapboxAccessToken: string;
  fixtureMode: boolean;
};

export function parseServerConfig(
  environment: NodeJS.ProcessEnv,
  readToken: (path: string) => string,
): ServerConfig {
  const fixtureMode = environment.RUNSYNC_USE_FIXTURES === "true";
  const values = fixtureMode
    ? {
        RUNSYNC_API_INTERNAL_URL: environment.RUNSYNC_API_INTERNAL_URL ?? "http://127.0.0.1:8080",
        RUNSYNC_API_PUBLIC_URL: environment.RUNSYNC_API_PUBLIC_URL ?? "http://127.0.0.1:8080",
        RUNSYNC_API_READ_TOKEN_FILE: environment.RUNSYNC_API_READ_TOKEN_FILE ?? "/dev/null",
        RUNSYNC_CHANNEL_SLUG: environment.RUNSYNC_CHANNEL_SLUG ?? "live",
        RUNSYNC_OVERLAY_ID:
          environment.RUNSYNC_OVERLAY_ID ?? "7a85db43-30ba-4de7-bb5e-7f2038937538",
        RUNSYNC_DEFAULT_UNITS: environment.RUNSYNC_DEFAULT_UNITS,
        RUNSYNC_DEFAULT_PACE: environment.RUNSYNC_DEFAULT_PACE,
        MAPBOX_ACCESS_TOKEN: environment.MAPBOX_ACCESS_TOKEN,
      }
    : environment;
  const parsed = environmentSchema.parse(values);
  const publicApiUrl = new URL(parsed.RUNSYNC_API_PUBLIC_URL);
  if (!fixtureMode && publicApiUrl.protocol !== "https:" && !isLoopbackHTTP(publicApiUrl)) {
    throw new Error("RUNSYNC_API_PUBLIC_URL must use https except for loopback development");
  }
  const token = fixtureMode
    ? "fixture-token-never-returned"
    : readToken(parsed.RUNSYNC_API_READ_TOKEN_FILE).trim();
  if (!token) throw new Error("RUNSYNC API read token file is empty");
  return {
    apiInternalUrl: parsed.RUNSYNC_API_INTERNAL_URL.replace(/\/$/, ""),
    apiPublicUrl: parsed.RUNSYNC_API_PUBLIC_URL.replace(/\/$/, ""),
    readToken: token,
    channelSlug: parsed.RUNSYNC_CHANNEL_SLUG,
    overlayId: parsed.RUNSYNC_OVERLAY_ID,
    defaultUnits: parsed.RUNSYNC_DEFAULT_UNITS,
    defaultPace: parsed.RUNSYNC_DEFAULT_PACE,
    mapboxAccessToken: parsed.MAPBOX_ACCESS_TOKEN,
    fixtureMode,
  };
}

function isLoopbackHTTP(url: URL) {
  return (
    url.protocol === "http:" &&
    (url.hostname === "localhost" || url.hostname === "127.0.0.1" || url.hostname === "[::1]")
  );
}
