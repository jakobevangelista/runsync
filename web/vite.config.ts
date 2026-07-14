import { defineConfig } from "vite-plus";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import { nitro } from "nitro/vite";
import viteReact from "@vitejs/plugin-react";

const appPlugins = process.env.VITEST
  ? []
  : [
      tanstackStart(),
      nitro({
        preset: "node_server",
        builder: "rolldown",
        plugins: ["./src/plugins/config.server.ts"],
      }),
      viteReact(),
    ];

export default defineConfig({
  server: { port: 3000 },
  resolve: { tsconfigPaths: true },
  plugins: appPlugins,
  lint: {
    ignorePatterns: [".output/**", "src/routeTree.gen.ts"],
    options: { typeAware: true, typeCheck: true },
  },
  fmt: {
    ignorePatterns: [".output/**", "src/routeTree.gen.ts"],
  },
  test: {
    environment: "jsdom",
    include: ["tests/**/*.test.{ts,tsx}"],
    restoreMocks: true,
    server: { deps: { external: ["react", "react-dom"] } },
  },
});
