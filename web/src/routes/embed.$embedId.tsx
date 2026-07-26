import { Outlet, createFileRoute } from "@tanstack/react-router";
import { LiveProvider } from "../components/LiveProvider";
import { validateEmbed } from "../lib/live.functions";

export const Route = createFileRoute("/embed/$embedId")({
  beforeLoad: ({ params }) => validateEmbed({ data: { accessId: params.embedId } }),
  component: EmbedLayout,
});

function EmbedLayout() {
  const { embedId } = Route.useParams();
  return (
    <LiveProvider audience="embed" accessId={embedId}>
      <Outlet />
    </LiveProvider>
  );
}
