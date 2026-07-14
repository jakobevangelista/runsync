import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vite-plus/test";
import { activityReducer, initialActivityState } from "../src/lib/activity-store";
import { IndividualMetric, MetricsPanel } from "../src/components/Metrics";
import { fixtureRoute, fixtureSnapshot } from "../src/lib/fixtures";

afterEach(cleanup);

const state = activityReducer(initialActivityState, {
  type: "bootstrap",
  session: {
    viewerToken: "viewer",
    expiresAt: "2026-07-12T18:47:12.410Z",
    apiPublicUrl: "https://api.example.test",
    channelSlug: "live",
    mapboxAccessToken: "",
    snapshot: fixtureSnapshot,
    route: fixtureRoute,
  },
});

describe("route presentation components", () => {
  it("renders the combined panel with state and secondary metrics", () => {
    render(<MetricsPanel state={state} units="metric" paceMode="average" />);
    expect(screen.getByLabelText("Pace · average").textContent).toContain("/km");
    expect(screen.getByLabelText("Heart rate").textContent).toContain("148");
    expect(screen.getByText("running")).toBeTruthy();
    expect(screen.getByText("Elapsed")).toBeTruthy();
  });

  it("renders each standalone counter without Mapbox", () => {
    const { rerender } = render(
      <IndividualMetric metric="distance" state={state} units="imperial" paceMode="rolling" />,
    );
    expect(screen.getByLabelText("Distance").textContent).toContain("mi");
    rerender(
      <IndividualMetric metric="heart-rate" state={state} units="metric" paceMode="rolling" />,
    );
    expect(screen.getByLabelText("Heart rate").textContent).toContain("bpm");
  });

  it("renders deliberate unavailable values while waiting", () => {
    render(
      <IndividualMetric
        metric="pace"
        state={initialActivityState}
        units="metric"
        paceMode="rolling"
      />,
    );
    expect(screen.getByLabelText("Pace · 10 sec").textContent).toContain("—");
  });
});
