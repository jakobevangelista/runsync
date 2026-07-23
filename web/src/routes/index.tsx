import { createFileRoute } from "@tanstack/react-router";
import { Landing } from "../components/Landing";
import { landingLinks } from "../lib/live.functions";

export const Route = createFileRoute("/")({
  beforeLoad: () => landingLinks(),
  component: LandingRoute,
});

function LandingRoute() {
  const links = Route.useRouteContext();
  return <Landing shareId={links.shareId} studioId={links.studioId} />;
}
