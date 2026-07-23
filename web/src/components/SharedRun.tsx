import { useEffect, useState } from "react";
import type { ActivityState } from "../lib/activity-store";
import type { PaceMode, Units } from "../lib/contracts";
import { MapPanel } from "./MapPanel";
import { MetricsPanel } from "./Metrics";
import { useLive } from "./LiveProvider";

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
    <main className="shared-shell">
      <header className="shared-header">
        <a className="shared-brand" href="/" aria-label="RunSync home">
          <span aria-hidden="true">RS</span>
          <strong>RunSync</strong>
        </a>
        <div className={`shared-status shared-status--${presentation.tone}`}>
          <span className={`signal signal--${state.connection}`} />
          <span>{presentation.label}</span>
        </div>
      </header>
      <section className="shared-intro">
        <div>
          <span className="eyebrow">Current run</span>
          <h1>{presentation.heading}</h1>
        </div>
        <div className="shared-intro__detail">
          <p>{presentation.detail}</p>
          <small>
            Last update <SampleAge receivedAt={state.sampleReceivedAt} />
          </small>
        </div>
      </section>
      <section className="shared-stage" aria-label="Run route and metrics">
        <div className="shared-stage__map">
          <MapPanel />
        </div>
        <div className="shared-stage__metrics">
          <MetricsPanel state={state} units={defaultUnits} paceMode={defaultPace} />
        </div>
      </section>
      <footer className="shared-footer">
        <span>Live telemetry from Garmin via RunSync</span>
        <a href="/">About this page</a>
      </footer>
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
