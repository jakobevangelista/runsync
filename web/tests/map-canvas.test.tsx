import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";
import MapCanvas, { routeData } from "../src/components/MapCanvas";
import { initialActivityState, type ActivityState } from "../src/lib/activity-store";

const mapbox = vi.hoisted(() => {
  const maps: FakeMap[] = [];
  const markers: FakeMarker[] = [];

  class FakeMap {
    handlers: Record<string, (event: { preventDefault: () => void }) => void> = {};
    source = { setData: vi.fn() };
    canvas = document.createElement("canvas");
    remove = vi.fn();
    easeTo = vi.fn();

    constructor() {
      maps.push(this);
    }

    on(event: string, handler: (event: { preventDefault: () => void }) => void) {
      this.handlers[event] = handler;
      if (event === "load") queueMicrotask(() => handler({ preventDefault: vi.fn() }));
      return this;
    }

    addSource(_id: string, source: { data: unknown }) {
      this.source.setData(source.data);
    }

    addLayer() {}

    getSource() {
      return this.source;
    }

    getCanvas() {
      return this.canvas;
    }

    isStyleLoaded() {
      return true;
    }
  }

  class FakeMarker {
    removed = false;
    lngLat?: [number, number];

    constructor(public options: { element: HTMLElement }) {
      markers.push(this);
    }

    setLngLat(coordinate: [number, number]) {
      this.lngLat = coordinate;
      return this;
    }

    addTo() {
      return this;
    }

    remove() {
      this.removed = true;
    }
  }

  return {
    maps,
    markers,
    module: { accessToken: "", Map: FakeMap, Marker: FakeMarker },
  };
});

vi.mock("mapbox-gl", () => ({ default: mapbox.module }));

const firstActivity = "07da0dd8-e84b-42e2-9711-a60770dc3c2f";
const secondActivity = "485cc805-e423-4dbf-bfa6-ddc0d07df784";

function mapState(activityId: string, offset = 0): ActivityState {
  return {
    ...initialActivityState,
    activityId,
    route: [
      {
        envelopeId: `start-${offset}`,
        phoneReceivedAt: "2026-07-12T18:42:00.000Z",
        latitudeMicrodegrees: 37_000_000 + offset,
        longitudeMicrodegrees: -122_000_000 - offset,
      },
      {
        envelopeId: `current-${offset}`,
        phoneReceivedAt: "2026-07-12T18:42:10.000Z",
        latitudeMicrodegrees: 37_000_100 + offset,
        longitudeMicrodegrees: -122_000_100 - offset,
      },
    ],
  };
}

beforeEach(() => {
  mapbox.maps.length = 0;
  mapbox.markers.length = 0;
  vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue({} as WebGL2RenderingContext);
});

afterEach(cleanup);

describe("MapCanvas", () => {
  it("uses an empty FeatureCollection until a LineString has two points", () => {
    expect(routeData([])).toEqual({ type: "FeatureCollection", features: [] });
    expect(routeData([[1, 2]])).toEqual({ type: "FeatureCollection", features: [] });
    expect(
      routeData([
        [1, 2],
        [3, 4],
      ]),
    ).toMatchObject({
      type: "Feature",
      geometry: { type: "LineString" },
    });
  });

  it("resets and repositions markers across activities, map recreation, and an empty route", async () => {
    const { rerender } = render(<MapCanvas state={mapState(firstActivity)} token="pk.test" />);
    await waitFor(() => expect(mapbox.markers).toHaveLength(2));
    expect(mapbox.maps[0]?.handlers.error).toBeUndefined();
    expect(screen.queryByText("Map tiles could not be loaded")).toBeNull();

    rerender(<MapCanvas state={mapState(secondActivity, 1000)} token="pk.test" />);
    await waitFor(() => expect(mapbox.markers).toHaveLength(4));
    expect(mapbox.markers.slice(0, 2).every((marker) => marker.removed)).toBe(true);
    expect(mapbox.markers[2]?.lngLat).toEqual([-122.001, 37.001]);

    act(() => {
      mapbox.maps[0]?.canvas.dispatchEvent(new Event("webglcontextlost", { cancelable: true }));
    });
    await waitFor(() => expect(mapbox.maps).toHaveLength(2));
    await waitFor(() => expect(mapbox.markers).toHaveLength(6));
    expect(mapbox.markers.slice(2, 4).every((marker) => marker.removed)).toBe(true);

    rerender(
      <MapCanvas state={{ ...mapState(secondActivity, 1000), route: [] }} token="pk.test" />,
    );
    await waitFor(() =>
      expect(mapbox.markers.slice(4, 6).every((marker) => marker.removed)).toBe(true),
    );
    expect(mapbox.maps[1]?.source.setData).toHaveBeenLastCalledWith({
      type: "FeatureCollection",
      features: [],
    });
  });
});
