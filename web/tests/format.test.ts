import { describe, expect, it } from "vite-plus/test";
import {
  averagePace,
  distanceFromDecimeters,
  formatElapsed,
  formatElevation,
  formatPace,
  stateLabel,
} from "../src/lib/format";

describe("metric formatting", () => {
  it("converts cumulative distance", () => {
    expect(distanceFromDecimeters(16_093, "imperial")).toBeCloseTo(1, 3);
    expect(distanceFromDecimeters(10_000, "metric")).toBe(1);
  });

  it("formats elapsed time around one hour", () => {
    expect(formatElapsed(754_000)).toBe("12:34");
    expect(formatElapsed(3_661_000)).toBe("1:01:01");
    expect(formatElapsed(undefined)).toBe("—");
  });

  it("converts altitude and ascent independently", () => {
    expect(formatElevation(1000, 50, "metric")).toEqual({
      altitude: "100",
      ascent: "50",
      unit: "m",
    });
    expect(formatElevation(1000, 50, "imperial")).toEqual({
      altitude: "328",
      ascent: "164",
      unit: "ft",
    });
  });

  it("formats valid pace and rejects implausible pace", () => {
    expect(formatPace(0.3, "metric")).toEqual({ value: "5:00", unit: "/km" });
    expect(formatPace(0.3, "imperial")).toEqual({ value: "8:03", unit: "/mi" });
    expect(formatPace(0.01, "metric").value).toBe("—");
  });

  it("computes average pace and explicit state labels", () => {
    expect(
      averagePace({
        envelopeId: "c1a7c88e-8fa7-446d-aa26-a3ce0ad98f58",
        phoneReceivedAt: "2026-07-12T18:42:12.250Z",
        protocolVersion: 1,
        sequence: 1,
        state: 1,
        elapsedTimeMilliseconds: 300_000,
        distanceDecimeters: 10_000,
      }),
    ).toBe(0.3);
    expect([0, 1, 2, 3, 4].map(stateLabel)).toEqual([
      "waiting",
      "running",
      "paused",
      "stopped",
      "ended",
    ]);
  });
});
