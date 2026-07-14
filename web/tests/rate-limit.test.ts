import { describe, expect, it } from "vite-plus/test";
import { allowSession, isSameOrigin } from "../src/lib/rate-limit.server";

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

  it("accepts the public origin forwarded by the trusted reverse proxy", () => {
    const request = new Request("http://web:3000/api/live/example/session", {
      method: "POST",
      headers: {
        origin: "https://runsync.example.com",
        "sec-fetch-site": "same-origin",
        "x-forwarded-host": "runsync.example.com",
        "x-forwarded-proto": "https",
      },
    });
    expect(isSameOrigin(request)).toBe(true);
  });

  it("rejects cross-site session requests", () => {
    const request = new Request("http://web:3000/api/live/example/session", {
      method: "POST",
      headers: {
        origin: "https://evil.example",
        "sec-fetch-site": "cross-site",
        "x-forwarded-host": "runsync.example.com",
        "x-forwarded-proto": "https",
      },
    });
    expect(isSameOrigin(request)).toBe(false);
  });
});
