import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vite-plus/test";
import { Landing } from "../src/components/Landing";
import { describeSharedRun } from "../src/components/SharedRun";
import { initialActivityState, type ActivityState } from "../src/lib/activity-store";
import { liveSessionPath } from "../src/lib/live-access";

afterEach(cleanup);

describe("public page hierarchy", () => {
  it("keeps the family action primary and broadcast tools secondary", () => {
    render(<Landing shareId="family-id" studioId="studio-id" />);
    expect(screen.getByRole("link", { name: /view the current run/i }).getAttribute("href")).toBe(
      "/share/family-id",
    );
    expect(screen.getByRole("link", { name: /broadcast tools/i }).getAttribute("href")).toBe(
      "/studio/studio-id",
    );
  });

  it("uses separate session namespaces for viewers and browser sources", () => {
    expect(liveSessionPath("share", "family/id")).toBe("/api/share/family%2Fid/session");
    expect(liveSessionPath("embed", "obs")).toBe("/api/embed/obs/session");
  });

  it("presents an ended activity as a completed run that remains available", () => {
    const ended = {
      ...initialActivityState,
      connection: "ended",
      latest: { state: 4 },
    } as ActivityState;
    expect(describeSharedRun(ended)).toEqual(
      expect.objectContaining({
        label: "Run completed",
        detail: expect.stringContaining("remain available"),
      }),
    );
  });

  it("distinguishes a delayed signal from a completed run", () => {
    const delayed = {
      ...initialActivityState,
      connection: "stale",
      latest: { state: 1 },
    } as ActivityState;
    expect(describeSharedRun(delayed).label).toBe("Signal delayed");
  });
});
