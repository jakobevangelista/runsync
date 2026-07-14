import type { ActivityState } from "../lib/activity-store";
import type { PaceMode, Units } from "../lib/contracts";
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
  return (
    <section
      className={`metric metric--${accent}${compact ? " metric--solo" : ""}`}
      aria-label={label}
    >
      <span className="metric__label">{label}</span>
      <div className="metric__reading">
        <strong>{value}</strong>
        <span>{unit}</span>
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
    <div className="metrics-panel">
      <div className="metrics-panel__signal">
        <span className={`signal signal--${state.connection}`} />
        <span>{values.activity}</span>
        <small>{state.connection}</small>
      </div>
      <div className="metrics-panel__primary">
        <MetricCounter
          label={paceMode === "rolling" ? "Pace · 10 sec" : "Pace · average"}
          {...values.pace}
          accent="lime"
        />
        <MetricCounter label="Heart rate" {...values.heartRate} accent="coral" />
        <MetricCounter label="Distance" {...values.distance} accent="cyan" />
      </div>
      <div className="metrics-panel__secondary">
        <Secondary label="Elapsed" value={values.elapsed} />
        <Secondary
          label="Altitude"
          value={`${values.elevation.altitude} ${values.elevation.unit}`}
        />
        <Secondary label="Ascent" value={`${values.elevation.ascent} ${values.elevation.unit}`} />
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

function Secondary({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}
