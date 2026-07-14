import { createFileRoute, getRouteApi } from "@tanstack/react-router";
import { Preview } from "../components/Preview";

const liveRoute = getRouteApi("/live/$overlayId");

export const Route = createFileRoute("/live/$overlayId/preview")({
  component: PreviewRoute,
});

function PreviewRoute() {
  const { overlayId } = Route.useParams();
  const defaults = liveRoute.useRouteContext();
  return (
    <Preview
      overlayId={overlayId}
      defaultUnits={defaults.defaultUnits}
      defaultPace={defaults.defaultPace}
    />
  );
}
