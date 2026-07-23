import { createServerFn } from "@tanstack/react-start";
import { notFound } from "@tanstack/react-router";
import { z } from "zod";
import { getServerConfig } from "./config.server";

const accessValidator = z.object({ accessId: z.string() });

export const validateOverlay = createServerFn({ method: "GET" })
  .validator(z.object({ overlayId: z.string() }))
  .handler(({ data }) => {
    const config = getServerConfig();
    if (data.overlayId !== config.overlayId) throw notFound();
    return {
      defaultUnits: config.defaultUnits,
      defaultPace: config.defaultPace,
      embedId: config.embedId,
    };
  });

export const validateShare = createServerFn({ method: "GET" })
  .validator(accessValidator)
  .handler(({ data }) => {
    const config = getServerConfig();
    if (data.accessId !== config.shareId) throw notFound();
    return { defaultUnits: config.defaultUnits, defaultPace: config.defaultPace };
  });

export const validateEmbed = createServerFn({ method: "GET" })
  .validator(accessValidator)
  .handler(({ data }) => {
    const config = getServerConfig();
    if (data.accessId !== config.embedId) throw notFound();
    return { defaultUnits: config.defaultUnits, defaultPace: config.defaultPace };
  });

export const validateStudio = createServerFn({ method: "GET" })
  .validator(accessValidator)
  .handler(({ data }) => {
    const config = getServerConfig();
    if (data.accessId !== config.overlayId) throw notFound();
    return {
      defaultUnits: config.defaultUnits,
      defaultPace: config.defaultPace,
      embedId: config.embedId,
    };
  });

export const landingLinks = createServerFn({ method: "GET" }).handler(() => {
  const config = getServerConfig();
  return { shareId: config.shareId, studioId: config.overlayId };
});
