import { describe, expect, it, vi } from "vite-plus/test";
import { parseServerConfig } from "../src/lib/config";
import { createLiveSession, redactSessionForLog } from "../src/lib/session-broker";
import { fixtureRoute, fixtureSnapshot } from "../src/lib/fixtures";

const environment = {
  RUNSYNC_API_INTERNAL_URL: "http://api:8080",
  RUNSYNC_API_PUBLIC_URL: "https://api.example.test",
  RUNSYNC_API_READ_TOKEN_FILE: "/run/secrets/read",
  RUNSYNC_CHANNEL_SLUG: "live",
  RUNSYNC_OVERLAY_ID: "7a85db43-30ba-4de7-bb5e-7f2038937538",
  RUNSYNC_DEFAULT_UNITS: "imperial",
  MAPBOX_ACCESS_TOKEN: "",
};

describe("server configuration and session broker", () => {
  it("loads the permanent credential only from its file", () => {
    const config = parseServerConfig(environment, (path) => {
      expect(path).toBe("/run/secrets/read");
      return "rs_permanent\n";
    });
    expect(config.readToken).toBe("rs_permanent");
    expect(() => parseServerConfig(environment, () => "")).toThrow("empty");
  });

  it("accepts only public Mapbox tokens and requires a secure public API URL", () => {
    expect(
      parseServerConfig({ ...environment, MAPBOX_ACCESS_TOKEN: "pk.public" }, () => "token")
        .mapboxAccessToken,
    ).toBe("pk.public");
    expect(() =>
      parseServerConfig({ ...environment, MAPBOX_ACCESS_TOKEN: "sk.secret" }, () => "token"),
    ).toThrow("start with pk.");
    expect(() =>
      parseServerConfig(
        { ...environment, RUNSYNC_API_PUBLIC_URL: "http://api.example.test" },
        () => "token",
      ),
    ).toThrow("must use https");
    expect(
      parseServerConfig(
        { ...environment, RUNSYNC_API_PUBLIC_URL: "http://127.0.0.1:8081" },
        () => "token",
      ).apiPublicUrl,
    ).toBe("http://127.0.0.1:8081");
    expect(
      parseServerConfig(
        {
          ...environment,
          RUNSYNC_API_PUBLIC_URL: "http://127.0.0.1:8080",
          RUNSYNC_USE_FIXTURES: "true",
        },
        () => "",
      ).apiPublicUrl,
    ).toBe("http://127.0.0.1:8080");
  });

  it("exchanges with the permanent token but never returns it", async () => {
    const config = parseServerConfig(environment, () => "rs_permanent");
    const fetcher = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(
        Response.json(
          { token: "short-viewer", expiresAt: "2026-07-12T18:47:12.410Z" },
          { status: 201 },
        ),
      )
      .mockResolvedValueOnce(Response.json(fixtureSnapshot))
      .mockResolvedValueOnce(Response.json(fixtureRoute));
    const output = await createLiveSession(config, fetcher);
    expect(fetcher.mock.calls[0]?.[1]?.headers).toEqual(
      expect.objectContaining({ Authorization: "Bearer rs_permanent" }),
    );
    expect(output.viewerToken).toBe("short-viewer");
    expect(JSON.stringify(output)).not.toContain("rs_permanent");
    expect(JSON.stringify(output)).not.toContain("api:8080");
  });

  it("retries a torn snapshot and route pair until their identities match", async () => {
    const config = parseServerConfig(environment, () => "rs_permanent");
    const otherActivityId = "485cc805-e423-4dbf-bfa6-ddc0d07df784";
    const fetcher = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(
        Response.json(
          { token: "short-viewer", expiresAt: "2026-07-12T18:47:12.410Z" },
          { status: 201 },
        ),
      )
      .mockResolvedValueOnce(Response.json(fixtureSnapshot))
      .mockResolvedValueOnce(Response.json({ ...fixtureRoute, activityId: otherActivityId }))
      .mockResolvedValueOnce(Response.json(fixtureSnapshot))
      .mockResolvedValueOnce(Response.json(fixtureRoute));

    await expect(createLiveSession(config, fetcher)).resolves.toMatchObject({
      snapshot: { activityId: fixtureSnapshot.activityId },
      route: { activityId: fixtureRoute.activityId },
    });
    expect(fetcher).toHaveBeenCalledTimes(5);
  });

  it("bounds retries when the bootstrap pair remains inconsistent", async () => {
    const config = parseServerConfig(environment, () => "rs_permanent");
    const otherActivityId = "485cc805-e423-4dbf-bfa6-ddc0d07df784";
    let bootstrapCalls = 0;
    const fetcher = vi.fn<typeof fetch>(async (input) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      if (url.endsWith("/v1/viewer-tokens")) {
        return Response.json(
          { token: "short-viewer", expiresAt: "2026-07-12T18:47:12.410Z" },
          { status: 201 },
        );
      }
      bootstrapCalls += 1;
      return url.endsWith("/snapshot")
        ? Response.json(fixtureSnapshot)
        : Response.json({ ...fixtureRoute, activityId: otherActivityId });
    });

    await expect(createLiveSession(config, fetcher)).rejects.toThrow("after 3 attempts");
    expect(bootstrapCalls).toBe(6);
  });

  it("redacts bearer values from server errors", () => {
    expect(redactSessionForLog(new Error("upstream Bearer abc.def failed"))).toBe(
      "upstream Bearer [redacted] failed",
    );
  });
});
