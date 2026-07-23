import { createFileRoute } from "@tanstack/react-router";
import { handleLiveSession } from "../lib/session-route.server";

export const Route = createFileRoute("/api/embed/$embedId/session")({
  server: {
    handlers: {
      POST: ({ request, params }) => handleLiveSession(request, "embed", params.embedId),
    },
  },
});
