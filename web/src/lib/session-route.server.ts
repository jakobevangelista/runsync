import { getServerConfig } from "./config.server";
import type { LiveAudience } from "./live-access";
import { allowSession, isSameOrigin, requestIP } from "./rate-limit.server";
import { createLiveSession, redactSessionForLog } from "./session.server";

const noStore = { "Cache-Control": "no-store", "Referrer-Policy": "no-referrer" };

export async function handleLiveSession(
  request: Request,
  audience: LiveAudience,
  accessId: string,
) {
  const config = getServerConfig();
  if (accessId !== expectedAccessId(config, audience)) {
    return new Response("Not found", { status: 404, headers: noStore });
  }
  if (!isSameOrigin(request)) {
    return new Response("Forbidden", { status: 403, headers: noStore });
  }
  if (!allowSession(requestIP(request))) {
    return Response.json({ error: "Too many requests" }, { status: 429, headers: noStore });
  }
  try {
    const session = await createLiveSession(config);
    return Response.json(session, { headers: noStore });
  } catch (error) {
    console.error("Live session bootstrap failed:", redactSessionForLog(error));
    return Response.json({ error: "Live session unavailable" }, { status: 502, headers: noStore });
  }
}

function expectedAccessId(config: ReturnType<typeof getServerConfig>, audience: LiveAudience) {
  switch (audience) {
    case "share":
      return config.shareId;
    case "embed":
      return config.embedId;
    default:
      return config.overlayId;
  }
}
