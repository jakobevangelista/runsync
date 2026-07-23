export type LiveAudience = "live" | "share" | "embed";

export function liveSessionPath(audience: LiveAudience, accessId: string) {
  return `/api/${audience}/${encodeURIComponent(accessId)}/session`;
}
