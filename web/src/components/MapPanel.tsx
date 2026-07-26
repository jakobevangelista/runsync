import { lazy, Suspense, useEffect, useState } from "react";
import { createClientOnlyFn } from "@tanstack/react-start";
import { MapPinned } from "lucide-react";

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
    <div
      className="relative grid h-full min-h-60 w-full place-items-center overflow-hidden rounded-[inherit] bg-map text-foreground"
      role="status"
    >
      <div className="map-fallback-grid absolute -inset-12 opacity-60" aria-hidden="true" />
      <svg
        className="absolute h-[62%] w-[70%] opacity-25"
        viewBox="0 0 500 280"
        fill="none"
        aria-hidden="true"
      >
        <path
          d="M35 235C82 174 113 210 144 157C174 105 132 75 192 63C251 51 252 123 312 103C368 84 350 31 419 45C447 51 457 78 469 103"
          stroke="var(--primary)"
          strokeWidth="8"
          strokeLinecap="round"
        />
      </svg>
      <div className="relative mx-5 flex max-w-sm flex-col items-center rounded-2xl border border-border/80 bg-card/90 px-6 py-5 text-center shadow-sm backdrop-blur">
        <span className="mb-3 grid size-9 place-items-center rounded-xl bg-primary/10 text-primary">
          <MapPinned className="size-4.5" />
        </span>
        <strong className="text-sm font-semibold tracking-[-0.015em]">{title}</strong>
        <small className="mt-1 text-xs leading-5 text-muted-foreground">
          {detail ?? "Route metrics remain available."}
        </small>
      </div>
    </div>
  );
}
