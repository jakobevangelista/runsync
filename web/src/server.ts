import handler, { createServerEntry } from "@tanstack/react-start/server-entry";
import { assertServerConfig } from "./lib/config.server";

assertServerConfig();

export default createServerEntry({
  fetch(request) {
    return handler.fetch(request);
  },
});
