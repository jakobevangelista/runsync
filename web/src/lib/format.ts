import type { Sample, Units } from "./contracts";

const METERS_PER_MILE = 1609.344;
const FEET_PER_METER = 3.28084;
const MIN_SECONDS_PER_METER = 0.12;
const MAX_SECONDS_PER_METER = 1.8;

export function distanceFromDecimeters(value: number, units: Units) {
  const meters = value / 10;
  return units === "imperial" ? meters / METERS_PER_MILE : meters / 1000;
}

export function formatDistance(value: number | undefined, units: Units) {
  if (value === undefined) return { value: "—", unit: units === "imperial" ? "mi" : "km" };
  const distance = distanceFromDecimeters(value, units);
  return {
    value: distance.toFixed(distance < 10 ? 2 : 1),
    unit: units === "imperial" ? "mi" : "km",
  };
}

export function formatHeartRate(value: number | undefined) {
  return { value: value === undefined ? "—" : Math.round(value).toString(), unit: "bpm" };
}

export function formatElapsed(milliseconds: number | undefined) {
  if (milliseconds === undefined) return "—";
  const total = Math.floor(milliseconds / 1000);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  return hours > 0
    ? `${hours}:${minutes.toString().padStart(2, "0")}:${seconds.toString().padStart(2, "0")}`
    : `${minutes.toString().padStart(2, "0")}:${seconds.toString().padStart(2, "0")}`;
}

export function validPace(secondsPerMeter: number | undefined) {
  return secondsPerMeter !== undefined &&
    Number.isFinite(secondsPerMeter) &&
    secondsPerMeter >= MIN_SECONDS_PER_METER &&
    secondsPerMeter <= MAX_SECONDS_PER_METER
    ? secondsPerMeter
    : undefined;
}

export function averagePace(sample: Sample | undefined) {
  if (!sample?.elapsedTimeMilliseconds || !sample.distanceDecimeters) return undefined;
  return validPace(sample.elapsedTimeMilliseconds / 1000 / (sample.distanceDecimeters / 10));
}

export function speedPace(speedMillimetersPerSecond: number | undefined) {
  if (!speedMillimetersPerSecond) return undefined;
  return validPace(1000 / speedMillimetersPerSecond);
}

export function formatPace(secondsPerMeter: number | undefined, units: Units) {
  const valid = validPace(secondsPerMeter);
  const unit = units === "imperial" ? "/mi" : "/km";
  if (valid === undefined) return { value: "—", unit };
  const totalSeconds = Math.round(valid * (units === "imperial" ? METERS_PER_MILE : 1000));
  return {
    value: `${Math.floor(totalSeconds / 60)}:${(totalSeconds % 60).toString().padStart(2, "0")}`,
    unit,
  };
}

export function formatElevation(
  altitudeDecimeters: number | undefined,
  ascentMeters: number | undefined,
  units: Units,
) {
  const altitudeMeters = altitudeDecimeters === undefined ? undefined : altitudeDecimeters / 10;
  const convert = (meters: number | undefined) =>
    meters === undefined
      ? "—"
      : Math.round(units === "imperial" ? meters * FEET_PER_METER : meters).toString();
  return {
    altitude: convert(altitudeMeters),
    ascent: convert(ascentMeters),
    unit: units === "imperial" ? "ft" : "m",
  };
}

export function stateLabel(state: number | undefined) {
  return ["waiting", "running", "paused", "stopped", "ended"][state ?? 0] ?? "waiting";
}
