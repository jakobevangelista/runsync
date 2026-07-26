import { createFileRoute } from "@tanstack/react-router";
import { handleLiveSession } from "../lib/session-route.server";

export const Route = createFileRoute("/api/share/$shareId/session")({
  server: {
    handlers: {
      POST: ({ request, params }) => handleLiveSession(request, "share", params.shareId),
    },
  },
});
