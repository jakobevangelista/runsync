import { createServerFn } from "@tanstack/react-start";
import { notFound } from "@tanstack/react-router";
import { z } from "zod";
import { getServerConfig } from "./config.server";

export const validateOverlay = createServerFn({ method: "GET" })
  .validator(z.object({ overlayId: z.string() }))
  .handler(({ data }) => {
    const config = getServerConfig();
    if (data.overlayId !== config.overlayId) throw notFound();
    return { defaultUnits: config.defaultUnits, defaultPace: config.defaultPace };
  });
