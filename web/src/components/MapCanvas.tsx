import "mapbox-gl/dist/mapbox-gl.css";
import { useEffect, useRef, useState } from "react";
import type { ActivityState } from "../lib/activity-store";
import { MapFallback } from "./MapPanel";

type Coordinate = [number, number];
type MapboxGL = typeof import("mapbox-gl").default;
type MapMarkers = {
  activityId?: string;
  current?: import("mapbox-gl").Marker;
  start?: import("mapbox-gl").Marker;
};
const FOLLOW_ZOOM = 14.5;

export default function MapCanvas({ state, token }: { state: ActivityState; token: string }) {
  const container = useRef<HTMLDivElement>(null);
  const mapRef = useRef<import("mapbox-gl").Map | undefined>(undefined);
  const markers = useRef<MapMarkers>({});
  const lastCameraMove = useRef(0);
  const [error, setError] = useState<string | undefined>(undefined);
  const [generation, setGeneration] = useState(0);
  const [darkMode, setDarkMode] = useState(prefersDarkMap);
  const coordinates = state.route.map(
    (point) =>
      [
        point.longitudeMicrodegrees / 1_000_000,
        point.latitudeMicrodegrees / 1_000_000,
      ] as Coordinate,
  );
  const view = useRef({
    activityId: state.activityId,
    coordinates,
    ended: state.latest?.state === 4,
  });
  view.current = { activityId: state.activityId, coordinates, ended: state.latest?.state === 4 };

  useEffect(() => {
    const observer = new MutationObserver(() => setDarkMode(prefersDarkMap()));
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    if (!token || !container.current) return;
    setError(undefined);
    const canvas = document.createElement("canvas");
    if (!canvas.getContext("webgl2") && !canvas.getContext("webgl")) {
      setError("WebGL is unavailable");
      return;
    }
    let disposed = false;
    void import("mapbox-gl")
      .then(({ default: mapboxgl }) => {
        if (disposed || !container.current) return;
        mapboxgl.accessToken = token;
        const first = view.current.coordinates[0] ?? [-98.5, 39.8];
        const routeColor =
          getComputedStyle(container.current).getPropertyValue("--primary").trim() || "#e86238";
        const map = new mapboxgl.Map({
          container: container.current,
          style: darkMode ? "mapbox://styles/mapbox/dark-v11" : "mapbox://styles/mapbox/light-v11",
          center: first,
          zoom: view.current.coordinates.length ? FOLLOW_ZOOM : 2.5,
          attributionControl: true,
          interactive: false,
          pitchWithRotate: false,
        });
        mapRef.current = map;
        map.on("load", () => {
          if (disposed) return;
          map.addSource("run", {
            type: "geojson",
            data: routeData(view.current.coordinates),
          });
          map.addLayer({
            id: "run-casing",
            type: "line",
            source: "run",
            paint: {
              "line-color": darkMode ? "#211e1a" : "#fffdf8",
              "line-width": 11,
              "line-opacity": 0.94,
            },
          });
          map.addLayer({
            id: "run-line",
            type: "line",
            source: "run",
            paint: { "line-color": routeColor, "line-width": 5, "line-opacity": 1 },
          });
          syncMapView(map, mapboxgl, view.current, markers.current, lastCameraMove);
        });
        map.getCanvas().addEventListener("webglcontextlost", (event) => {
          event.preventDefault();
          setGeneration((value) => value + 1);
        });
      })
      .catch(() => setError("Mapbox could not initialize"));
    return () => {
      disposed = true;
      clearMarkers(markers.current);
      markers.current.activityId = undefined;
      mapRef.current?.remove();
      mapRef.current = undefined;
    };
    // The map instance is intentionally recreated only for token, theme, or WebGL changes.
  }, [token, generation, darkMode]);

  useEffect(() => {
    const map = mapRef.current;
    if (!map || !map.isStyleLoaded()) return;
    void import("mapbox-gl").then(({ default: mapboxgl }) => {
      if (mapRef.current !== map) return;
      syncMapView(map, mapboxgl, view.current, markers.current, lastCameraMove);
    });
  }, [state.activityId, state.latest?.state, state.route]);

  if (!token) return <MapFallback title="Map token not configured" />;
  if (error)
    return (
      <MapFallback
        title={error}
        detail="Check browser WebGL support and Mapbox token restrictions."
      />
    );
  return (
    <div className="relative h-full min-h-60 w-full overflow-hidden rounded-[inherit] bg-map">
      <div className="map-canvas h-full w-full" ref={container} />
      <div className="absolute top-4 left-4 flex items-center gap-2 rounded-full border border-border bg-card/92 px-3 py-2 text-[10px] font-semibold tracking-[0.08em] text-foreground uppercase shadow-sm backdrop-blur">
        <span className={`signal signal--${state.connection}`} />
        {state.connection}
      </div>
    </div>
  );
}

function prefersDarkMap() {
  const isBrowserSource = /^\/(?:embed|live)\/[^/]+\/map\/?$/.test(window.location.pathname);
  return !isBrowserSource && document.documentElement.classList.contains("dark");
}

export function routeData(coordinates: Coordinate[]) {
  if (coordinates.length < 2) {
    return { type: "FeatureCollection" as const, features: [] };
  }
  return {
    type: "Feature" as const,
    properties: {},
    geometry: { type: "LineString" as const, coordinates },
  };
}

function syncMapView(
  map: import("mapbox-gl").Map,
  mapboxgl: MapboxGL,
  view: { activityId?: string; coordinates: Coordinate[]; ended: boolean },
  markers: MapMarkers,
  lastCameraMove: { current: number },
) {
  const source = map.getSource("run") as import("mapbox-gl").GeoJSONSource | undefined;
  source?.setData(routeData(view.coordinates));

  if (markers.activityId !== view.activityId) {
    clearMarkers(markers);
    markers.activityId = view.activityId;
    lastCameraMove.current = 0;
  }

  const first = view.coordinates[0];
  const current = view.coordinates.at(-1);
  if (!first || !current) {
    clearMarkers(markers);
    return;
  }

  if (markers.start) {
    markers.start.setLngLat(first);
  } else {
    markers.start = new mapboxgl.Marker({
      element: marker("route-marker route-marker--start"),
    })
      .setLngLat(first)
      .addTo(map);
  }
  if (markers.current) {
    markers.current.setLngLat(current);
  } else {
    markers.current = new mapboxgl.Marker({
      element: marker("route-marker route-marker--current"),
    })
      .setLngLat(current)
      .addTo(map);
  }

  const now = Date.now();
  const initializingCamera = lastCameraMove.current === 0;
  if (initializingCamera || (!view.ended && now - lastCameraMove.current > 2500)) {
    map.easeTo({
      center: current,
      ...(initializingCamera ? { zoom: FOLLOW_ZOOM } : {}),
      duration: 1200,
      essential: false,
    });
    lastCameraMove.current = now;
  }
}

function clearMarkers(markers: MapMarkers) {
  markers.current?.remove();
  markers.start?.remove();
  markers.current = undefined;
  markers.start = undefined;
}

function marker(className: string) {
  const element = document.createElement("div");
  element.className = className;
  return element;
}
