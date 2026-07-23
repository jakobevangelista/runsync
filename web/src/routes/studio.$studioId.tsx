import { createFileRoute } from "@tanstack/react-router";
import { LiveProvider } from "../components/LiveProvider";
import { Preview } from "../components/Preview";
import { validateStudio } from "../lib/live.functions";

export const Route = createFileRoute("/studio/$studioId")({
  beforeLoad: ({ params }) => validateStudio({ data: { accessId: params.studioId } }),
  component: StudioRoute,
});

function StudioRoute() {
  const { studioId } = Route.useParams();
  const defaults = Route.useRouteContext();
  return (
    <LiveProvider audience="live" accessId={studioId}>
      <Preview
        embedId={defaults.embedId}
        defaultUnits={defaults.defaultUnits}
        defaultPace={defaults.defaultPace}
      />
    </LiveProvider>
  );
}
