# syntax=docker/dockerfile:1
FROM ghcr.io/voidzero-dev/vite-plus:0.2.4 AS build
WORKDIR /app
COPY --chown=vp:vp package.json pnpm-lock.yaml pnpm-workspace.yaml .node-version ./
RUN vp install --frozen-lockfile
COPY --chown=vp:vp . .
RUN RUNSYNC_USE_FIXTURES=true vp build
RUN vp env which node | { read node_path; cp "$node_path" /tmp/node; }

FROM ghcr.io/voidzero-dev/vite-plus:0.2.4 AS deps
WORKDIR /app
COPY --chown=vp:vp package.json pnpm-lock.yaml pnpm-workspace.yaml .node-version ./
RUN vp install --frozen-lockfile --prod

FROM debian:bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production PORT=3000
COPY --from=build /tmp/node /usr/local/bin/node
COPY --from=build /app/.output ./.output
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/package.json ./
USER nobody
EXPOSE 3000
CMD ["node", ".output/server/index.mjs"]
