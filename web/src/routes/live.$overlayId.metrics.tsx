import { createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useLive } from "../components/LiveProvider";
import { MetricsPanel } from "../components/Metrics";
import { parseDisplaySearch } from "../lib/display";

const liveRoute = getRouteApi("/live/$overlayId");

export const Route = createFileRoute("/live/$overlayId/metrics")({
  validateSearch: (search) => ({ units: search.units, pace: search.pace }),
  component: MetricsRoute,
});

function MetricsRoute() {
  const { state } = useLive();
  const defaults = liveRoute.useRouteContext();
  const display = parseDisplaySearch(Route.useSearch(), defaults);
  return (
    <main className="overlay-page overlay-page--metrics">
      <MetricsPanel state={state} units={display.units} paceMode={display.pace} />
    </main>
  );
}
