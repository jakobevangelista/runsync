import { readFileSync } from "node:fs";
import { parseServerConfig, type ServerConfig } from "./config";

let cached: ServerConfig | undefined;

export function getServerConfig() {
  cached ??= parseServerConfig(process.env, (path) => readFileSync(path, "utf8"));
  return cached;
}

export function assertServerConfig() {
  getServerConfig();
}
