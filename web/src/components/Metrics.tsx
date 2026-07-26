import { Activity, Clock3, Gauge, HeartPulse, MapPin, Mountain } from "lucide-react";

import type { ActivityState } from "../lib/activity-store";
import type { PaceMode, Units } from "../lib/contracts";
import { cn } from "../lib/utils";
import {
  averagePace,
  formatDistance,
  formatElapsed,
  formatElevation,
  formatHeartRate,
  formatPace,
  stateLabel,
} from "../lib/format";

export type MetricName = "pace" | "heart-rate" | "distance";

export function metricsFor(state: ActivityState, units: Units, paceMode: PaceMode) {
  const latest = state.latest;
  return {
    pace: formatPace(paceMode === "rolling" ? state.rollingPace : averagePace(latest), units),
    heartRate: formatHeartRate(latest?.heartRateBPM),
    distance: formatDistance(latest?.distanceDecimeters, units),
    elapsed: formatElapsed(latest?.elapsedTimeMilliseconds),
    elevation: formatElevation(latest?.altitudeDecimeters, latest?.totalAscentMeters, units),
    activity: stateLabel(latest?.state),
  };
}

export function MetricCounter({
  label,
  value,
  unit,
  accent,
  compact = false,
}: {
  label: string;
  value: string;
  unit: string;
  accent: "lime" | "coral" | "cyan";
  compact?: boolean;
}) {
  const accentStyles = {
    lime: {
      icon: Gauge,
      iconClassName: "bg-primary/10 text-primary",
      lineClassName: "bg-primary",
    },
    coral: {
      icon: HeartPulse,
      iconClassName: "bg-heart/10 text-heart",
      lineClassName: "bg-heart",
    },
    cyan: {
      icon: MapPin,
      iconClassName: "bg-route/10 text-route",
      lineClassName: "bg-route",
    },
  } as const;
  const styles = accentStyles[accent];
  const Icon = styles.icon;
  return (
    <section
      className={cn(
        "group/metric relative min-w-0 overflow-hidden bg-card p-5 @lg:p-6",
        compact &&
          "flex h-full min-h-0 flex-col justify-center rounded-2xl border border-foreground/10 p-[clamp(1.25rem,7vmin,3rem)] shadow-sm",
      )}
      aria-label={label}
    >
      <span className={cn("absolute inset-x-0 bottom-0 h-0.5 opacity-80", styles.lineClassName)} />
      <div className="mb-7 flex items-center justify-between gap-3">
        <span className="text-[11px] font-medium tracking-[0.08em] text-muted-foreground uppercase">
          {label}
        </span>
        <span className={cn("grid size-8 place-items-center rounded-lg", styles.iconClassName)}>
          <Icon className="size-4" strokeWidth={2} />
        </span>
      </div>
      <div className="flex min-w-0 items-baseline gap-2">
        <strong
          className={cn(
            "metric-value min-w-0 text-[clamp(2.55rem,14cqw,5.2rem)] leading-[0.8] font-semibold tracking-[-0.07em] text-foreground",
            compact && "text-[clamp(3.5rem,30vmin,15rem)]",
          )}
        >
          {value}
        </strong>
        <span
          className={cn(
            "shrink-0 text-xs font-medium text-muted-foreground",
            compact && "text-[clamp(0.75rem,4vmin,1.5rem)]",
          )}
        >
          {unit}
        </span>
      </div>
    </section>
  );
}

export function MetricsPanel({
  state,
  units,
  paceMode,
}: {
  state: ActivityState;
  units: Units;
  paceMode: PaceMode;
}) {
  const values = metricsFor(state, units, paceMode);
  return (
    <div className="@container overflow-hidden rounded-2xl border border-foreground/10 bg-card shadow-[0_20px_60px_rgb(45_37_24/9%)]">
      <div className="flex min-h-14 items-center gap-2 border-b border-border/80 px-5">
        <span className={`signal signal--${state.connection}`} />
        <span className="text-xs font-semibold capitalize">{values.activity}</span>
        <span className="ml-auto text-[11px] font-medium tracking-[0.08em] text-muted-foreground uppercase">
          {state.connection}
        </span>
      </div>
      <div className="grid grid-cols-1 divide-y divide-border/80 @lg:grid-cols-3 @lg:divide-x @lg:divide-y-0">
        <MetricCounter
          label={paceMode === "rolling" ? "Pace · 10 sec" : "Pace · average"}
          {...values.pace}
          accent="lime"
        />
        <MetricCounter label="Heart rate" {...values.heartRate} accent="coral" />
        <MetricCounter label="Distance" {...values.distance} accent="cyan" />
      </div>
      <div className="grid grid-cols-1 divide-y divide-border/80 border-t border-border/80 bg-muted/40 @sm:grid-cols-3 @sm:divide-x @sm:divide-y-0">
        <Secondary icon={Clock3} label="Elapsed" value={values.elapsed} />
        <Secondary
          icon={Mountain}
          label="Altitude"
          value={`${values.elevation.altitude} ${values.elevation.unit}`}
        />
        <Secondary
          icon={Activity}
          label="Ascent"
          value={`${values.elevation.ascent} ${values.elevation.unit}`}
        />
      </div>
    </div>
  );
}

export function IndividualMetric({
  metric,
  state,
  units,
  paceMode,
}: {
  metric: MetricName;
  state: ActivityState;
  units: Units;
  paceMode: PaceMode;
}) {
  const values = metricsFor(state, units, paceMode);
  if (metric === "pace") {
    return (
      <MetricCounter
        label={paceMode === "rolling" ? "Pace · 10 sec" : "Pace · average"}
        {...values.pace}
        accent="lime"
        compact
      />
    );
  }
  if (metric === "heart-rate") {
    return <MetricCounter label="Heart rate" {...values.heartRate} accent="coral" compact />;
  }
  return <MetricCounter label="Distance" {...values.distance} accent="cyan" compact />;
}

function Secondary({
  icon: Icon,
  label,
  value,
}: {
  icon: typeof Clock3;
  label: string;
  value: string;
}) {
  return (
    <div className="flex items-center gap-3 px-5 py-4">
      <Icon className="size-3.5 shrink-0 text-muted-foreground" strokeWidth={2} />
      <span className="text-[10px] font-medium tracking-[0.08em] text-muted-foreground uppercase">
        {label}
      </span>
      <strong className="metric-value ml-auto text-sm font-semibold tracking-[-0.02em]">
        {value}
      </strong>
    </div>
  );
}
