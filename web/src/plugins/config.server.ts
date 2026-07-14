import { definePlugin } from "nitro";
import { assertServerConfig } from "../lib/config.server";

export default definePlugin(() => {
  assertServerConfig();
});
