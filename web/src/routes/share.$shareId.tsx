import { createFileRoute } from "@tanstack/react-router";
import { LiveProvider } from "../components/LiveProvider";
import { SharedRun } from "../components/SharedRun";
import { validateShare } from "../lib/live.functions";

export const Route = createFileRoute("/share/$shareId")({
  beforeLoad: ({ params }) => validateShare({ data: { accessId: params.shareId } }),
  component: SharedRunRoute,
});

function SharedRunRoute() {
  const { shareId } = Route.useParams();
  const defaults = Route.useRouteContext();
  return (
    <LiveProvider audience="share" accessId={shareId}>
      <SharedRun defaultUnits={defaults.defaultUnits} defaultPace={defaults.defaultPace} />
    </LiveProvider>
  );
}
