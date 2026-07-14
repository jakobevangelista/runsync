import { lazy, Suspense, useEffect, useState } from "react";
import { createClientOnlyFn } from "@tanstack/react-start";
import { useLive } from "./LiveProvider";

const LazyMap = lazy(createClientOnlyFn(() => import("./MapCanvas")));

export function MapPanel() {
  const { state, session } = useLive();
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  if (!mounted) return <MapFallback title="Preparing route" />;
  return (
    <Suspense fallback={<MapFallback title="Loading map" />}>
      <LazyMap state={state} token={session?.mapboxAccessToken ?? ""} />
    </Suspense>
  );
}

export function MapFallback({ title, detail }: { title: string; detail?: string }) {
  return (
    <div className="map-fallback" role="status">
      <div className="map-fallback__grid" />
      <span className="map-fallback__route" />
      <div>
        <strong>{title}</strong>
        <small>{detail ?? "Route metrics remain available."}</small>
      </div>
    </div>
  );
}
