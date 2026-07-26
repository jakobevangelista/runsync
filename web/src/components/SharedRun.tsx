import { useEffect, useState } from "react";
import { Clock3, Eye, Radio } from "lucide-react";

import type { ActivityState } from "../lib/activity-store";
import type { PaceMode, Units } from "../lib/contracts";
import { cn } from "../lib/utils";
import { Brand } from "./Brand";
import { MapPanel } from "./MapPanel";
import { MetricsPanel } from "./Metrics";
import { ThemeToggle } from "./ThemeToggle";
import { useLive } from "./LiveProvider";
import { Badge } from "./ui/badge";
import { Card } from "./ui/card";

export function SharedRun({
  defaultUnits,
  defaultPace,
}: {
  defaultUnits: Units;
  defaultPace: PaceMode;
}) {
  const { state } = useLive();
  const presentation = describeSharedRun(state);
  return (
    <main className="min-h-svh bg-background text-foreground">
      <div className="mx-auto w-full max-w-[90rem] px-4 py-4 sm:px-7 sm:py-6 lg:px-10">
        <header className="flex items-center justify-between gap-4 border-b border-border/70 pb-5">
          <Brand />
          <div className="flex items-center gap-1">
            <ThemeToggle />
            <Badge
              variant="outline"
              className={cn(
                "h-7 gap-2 border-border bg-card px-3 shadow-xs",
                presentation.tone === "live" && "border-live/20 bg-live/8 text-live",
                presentation.tone === "complete" &&
                  "border-complete/20 bg-complete/8 text-complete",
              )}
            >
              <span className={`signal signal--${state.connection}`} />
              {presentation.label}
            </Badge>
          </div>
        </header>

        <section className="grid gap-6 py-10 sm:py-12 lg:grid-cols-[minmax(0,1fr)_minmax(260px,0.38fr)] lg:items-end">
          <div>
            <p className="flex items-center gap-2 text-xs font-medium tracking-[0.13em] text-primary uppercase">
              <Radio className="size-3.5" />
              Current run
            </p>
            <h1 className="mt-4 max-w-[15ch] text-4xl leading-[0.98] font-semibold tracking-[-0.055em] text-balance sm:text-6xl lg:text-7xl">
              {presentation.heading}
            </h1>
          </div>
          <div className="border-l-2 border-primary pl-5">
            <p className="m-0 text-sm leading-6 text-muted-foreground">{presentation.detail}</p>
            <p className="mt-3 flex items-center gap-2 text-xs text-muted-foreground">
              <Clock3 className="size-3.5" />
              Last update <SampleAge receivedAt={state.sampleReceivedAt} />
            </p>
          </div>
        </section>

        <section
          className="grid gap-4 xl:grid-cols-[minmax(0,1.55fr)_minmax(330px,0.62fr)]"
          aria-label="Run route and metrics"
        >
          <Card className="relative min-h-[31rem] overflow-hidden border-foreground/10 bg-card py-0 shadow-[0_24px_70px_rgb(45_37_24/10%)] sm:min-h-[38rem]">
            <div className="absolute inset-0">
              <MapPanel />
            </div>
          </Card>
          <div className="min-w-0">
            <MetricsPanel state={state} units={defaultUnits} paceMode={defaultPace} />
          </div>
        </section>

        <footer className="mt-5 flex flex-col gap-3 border-t border-border/70 py-5 text-xs text-muted-foreground sm:flex-row sm:items-center sm:justify-between">
          <span>Live telemetry from Garmin via RunSync.</span>
          <span className="inline-flex items-center gap-2">
            <Eye className="size-3.5" />
            Anyone with this link can view
          </span>
        </footer>
      </div>
    </main>
  );
}

export function describeSharedRun(state: ActivityState) {
  const sampleState = state.latest?.state;
  if (sampleState === 4) {
    return {
      label: "Run completed",
      heading: "That’s a wrap.",
      detail: "The final route and run metrics remain available here.",
      tone: "complete",
    } as const;
  }
  if (state.connection === "stale" || state.connection === "reconnecting") {
    return {
      label: "Signal delayed",
      heading: "Holding the latest update.",
      detail: "The route will catch up automatically when the connection returns.",
      tone: "delayed",
    } as const;
  }
  if (sampleState === 1) {
    return {
      label: "Live now",
      heading: "The run is underway.",
      detail: "Route and metrics update automatically as new telemetry arrives.",
      tone: "live",
    } as const;
  }
  if (sampleState === 2) {
    return {
      label: "Paused",
      heading: "Taking a breather.",
      detail: "The run can resume from the same route and activity.",
      tone: "paused",
    } as const;
  }
  if (sampleState === 3) {
    return {
      label: "Stopped",
      heading: "The timer is stopped.",
      detail: "The run may resume or finish from here.",
      tone: "paused",
    } as const;
  }
  if (state.connection === "connecting") {
    return {
      label: "Connecting",
      heading: "Finding the current run.",
      detail: "This page will update automatically.",
      tone: "delayed",
    } as const;
  }
  return {
    label: "No run yet",
    heading: "Ready for the next run.",
    detail: "Come back when the activity starts.",
    tone: "idle",
  } as const;
}

function SampleAge({ receivedAt }: { receivedAt: number | undefined }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const interval = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(interval);
  }, []);
  if (receivedAt === undefined) return <>when available</>;
  const seconds = Math.max(0, Math.round((now - receivedAt) / 1000));
  return <>{seconds < 2 ? "just now" : `${seconds}s ago`}</>;
}
