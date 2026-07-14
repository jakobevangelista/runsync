import { describe, expect, it } from "vite-plus/test";
import { allowSession } from "../src/lib/rate-limit.server";

describe("in-app session limiter", () => {
  it("allows initial sources, preview, and an immediate reload burst", () => {
    const ip = "reload-burst";
    for (let request = 0; request < 12; request += 1) {
      expect(allowSession(ip, 1000)).toBe(true);
    }
    for (let request = 12; request < 20; request += 1) {
      expect(allowSession(ip, 1000)).toBe(true);
    }
    expect(allowSession(ip, 1000)).toBe(false);
    expect(allowSession(ip, 61_000)).toBe(true);
  });
});
