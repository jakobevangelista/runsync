import { createFileRoute } from "@tanstack/react-router";
import { getServerConfig } from "../lib/config.server";
import { allowSession, requestIP } from "../lib/rate-limit.server";
import { createLiveSession, redactSessionForLog } from "../lib/session.server";

const noStore = { "Cache-Control": "no-store", "Referrer-Policy": "no-referrer" };

export const Route = createFileRoute("/api/live/$overlayId/session")({
  server: {
    handlers: {
      POST: async ({ request, params }) => {
        const config = getServerConfig();
        if (params.overlayId !== config.overlayId)
          return new Response("Not found", { status: 404, headers: noStore });
        if (!isSameOrigin(request))
          return new Response("Forbidden", { status: 403, headers: noStore });
        if (!allowSession(requestIP(request)))
          return Response.json({ error: "Too many requests" }, { status: 429, headers: noStore });
        try {
          const session = await createLiveSession(config);
          return Response.json(session, { headers: noStore });
        } catch (error) {
          console.error("Live session bootstrap failed:", redactSessionForLog(error));
          return Response.json(
            { error: "Live session unavailable" },
            { status: 502, headers: noStore },
          );
        }
      },
    },
  },
});

function isSameOrigin(request: Request) {
  const fetchSite = request.headers.get("sec-fetch-site");
  if (fetchSite && fetchSite !== "same-origin") return false;
  const origin = request.headers.get("origin");
  return !origin || origin === new URL(request.url).origin;
}
