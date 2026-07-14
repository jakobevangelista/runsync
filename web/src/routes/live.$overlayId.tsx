import { Outlet, createFileRoute } from "@tanstack/react-router";
import { LiveProvider } from "../components/LiveProvider";
import { validateOverlay } from "../lib/live.functions";

export const Route = createFileRoute("/live/$overlayId")({
  beforeLoad: ({ params }) => validateOverlay({ data: { overlayId: params.overlayId } }),
  component: LiveLayout,
});

function LiveLayout() {
  const { overlayId } = Route.useParams();
  return (
    <LiveProvider overlayId={overlayId}>
      <Outlet />
    </LiveProvider>
  );
}
