import { useEffect, useState } from "react";
import { Clock3, Eye, MapPinned, Radio, Volume2 } from "lucide-react";

import type { ActivityState } from "../lib/activity-store";
import type { PaceMode, Units } from "../lib/contracts";
import { Brand } from "./Brand";
import { MapPanel } from "./MapPanel";
import { MetricsPanel } from "./Metrics";
import { StreamsyncPlayer } from "./StreamsyncPlayer";
import { ThemeToggle } from "./ThemeToggle";
import { useLive } from "./LiveProvider";
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
    <main className="share-page min-h-svh bg-background text-foreground dark:bg-[#141312]">
      <div className="mx-auto w-full max-w-[90rem] px-4 sm:px-7 lg:px-8">
        <header className="flex h-18 items-center justify-between gap-4 border-b-2 border-foreground/20">
          <Brand />
          <ThemeToggle />
        </header>

        <section className="py-6 sm:py-8">
          <div className="mb-3 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <p className="m-0 flex items-center gap-2 text-xs font-medium tracking-[0.13em] text-primary uppercase">
              <Radio className="size-3.5" />
              Live stream
            </p>
            <p className="m-0 flex items-center gap-2 text-xs text-muted-foreground">
              <Volume2 className="size-3.5" />
              Muted by default · Use player controls for sound
            </p>
          </div>
          <StreamsyncPlayer className="border-b-0" />
          <div className="grid gap-3 border-2 border-foreground/25 bg-card px-5 py-4 sm:grid-cols-[auto_minmax(0,1fr)_auto] sm:items-center sm:gap-5 dark:bg-[#141312]">
            <div className="flex items-center gap-2">
              <span className={`signal signal--${state.connection}`} />
              <strong className="text-xs font-semibold tracking-[0.08em] uppercase">
                {presentation.label}
              </strong>
            </div>
            <p className="m-0 text-xs leading-5 text-muted-foreground">{presentation.detail}</p>
            <p className="m-0 flex items-center gap-2 text-xs text-muted-foreground">
              <Clock3 className="size-3.5" />
              Updated <SampleAge receivedAt={state.sampleReceivedAt} />
            </p>
          </div>
        </section>

        <div className="mb-3 flex items-center gap-2 text-xs font-medium tracking-[0.13em] text-primary uppercase">
          <MapPinned className="size-3.5" />
          Route and run data
        </div>
        <section
          className="grid overflow-hidden border-2 border-foreground/25 xl:grid-cols-[minmax(0,1fr)_360px]"
          aria-label="Run route and metrics"
        >
          <Card className="relative min-h-[25rem] overflow-hidden rounded-none border-0 border-b-2 border-foreground/25 bg-card py-0 shadow-none sm:min-h-[32rem] xl:border-r-2 xl:border-b-0 dark:bg-[#141312]">
            <div className="absolute inset-0">
              <MapPanel />
            </div>
          </Card>
          <div className="min-w-0">
            <MetricsPanel
              state={state}
              units={defaultUnits}
              paceMode={defaultPace}
              variant="ledger"
            />
          </div>
        </section>

        <footer className="mt-6 flex flex-col gap-3 border-t-2 border-foreground/20 py-5 text-[10px] tracking-[0.08em] text-muted-foreground uppercase sm:flex-row sm:items-center sm:justify-between">
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
      detail: "The final route and run metrics remain available here.",
      tone: "complete",
    } as const;
  }
  if (state.connection === "stale" || state.connection === "reconnecting") {
    return {
      label: "Signal delayed",
      detail: "The route will catch up automatically when the connection returns.",
      tone: "delayed",
    } as const;
  }
  if (sampleState === 1) {
    return {
      label: "Live now",
      detail: "Route and metrics update automatically as new telemetry arrives.",
      tone: "live",
    } as const;
  }
  if (sampleState === 2) {
    return {
      label: "Paused",
      detail: "The run can resume from the same route and activity.",
      tone: "paused",
    } as const;
  }
  if (sampleState === 3) {
    return {
      label: "Stopped",
      detail: "The run may resume or finish from here.",
      tone: "paused",
    } as const;
  }
  if (state.connection === "connecting") {
    return {
      label: "Connecting",
      detail: "This page will update automatically.",
      tone: "delayed",
    } as const;
  }
  return {
    label: "No run yet",
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
