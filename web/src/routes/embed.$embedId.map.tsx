import { createFileRoute } from "@tanstack/react-router";
import { MapPanel } from "../components/MapPanel";

export const Route = createFileRoute("/embed/$embedId/map")({ component: MapRoute });

function MapRoute() {
  return (
    <main className="overlay-page overlay-page--map">
      <MapPanel />
    </main>
  );
}
