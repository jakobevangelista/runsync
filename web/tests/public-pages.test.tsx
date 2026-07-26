import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vite-plus/test";
import { Landing } from "../src/components/Landing";
import { describeSharedRun } from "../src/components/SharedRun";
import { STREAMSYNC_PROGRAM_URL, StreamsyncPlayer } from "../src/components/StreamsyncPlayer";
import { initialActivityState, type ActivityState } from "../src/lib/activity-store";
import { liveSessionPath } from "../src/lib/live-access";

afterEach(() => {
  cleanup();
  document.documentElement.classList.remove("dark");
  window.localStorage.removeItem("runsync-theme");
});

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

  it("persists an explicit dark mode preference", () => {
    render(<Landing shareId="family-id" studioId="studio-id" />);
    fireEvent.click(screen.getByRole("button", { name: /toggle color theme/i }));
    expect(document.documentElement.classList.contains("dark")).toBe(true);
    expect(window.localStorage.getItem("runsync-theme")).toBe("dark");
  });

  it("embeds the stable public Streamsync program output", () => {
    render(<StreamsyncPlayer />);
    const player = screen.getByTitle("Live video");
    expect(player.getAttribute("src")).toBe(STREAMSYNC_PROGRAM_URL);
    expect(STREAMSYNC_PROGRAM_URL).toContain(
      "?controls=true&muted=true&autoplay=true&playsinline=true",
    );
    expect(player.getAttribute("allow")).toBe("autoplay; fullscreen; picture-in-picture");
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
