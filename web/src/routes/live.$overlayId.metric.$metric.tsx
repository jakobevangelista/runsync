import { createFileRoute, getRouteApi, notFound } from "@tanstack/react-router";
import { useLive } from "../components/LiveProvider";
import { IndividualMetric, type MetricName } from "../components/Metrics";
import { parseDisplaySearch } from "../lib/display";

const liveRoute = getRouteApi("/live/$overlayId");
const metrics = new Set<MetricName>(["pace", "heart-rate", "distance"]);

export const Route = createFileRoute("/live/$overlayId/metric/$metric")({
  beforeLoad: ({ params }) => {
    if (!metrics.has(params.metric as MetricName)) throw notFound();
  },
  validateSearch: (search) => ({ units: search.units, pace: search.pace }),
  component: MetricRoute,
});

function MetricRoute() {
  const { state } = useLive();
  const defaults = liveRoute.useRouteContext();
  const display = parseDisplaySearch(Route.useSearch(), defaults);
  return (
    <main className="overlay-page overlay-page--counter">
      <IndividualMetric
        metric={Route.useParams().metric as MetricName}
        state={state}
        units={display.units}
        paceMode={display.pace}
      />
    </main>
  );
}
