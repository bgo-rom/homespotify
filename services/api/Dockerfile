# Contexte de build attendu : racine du monorepo (voir infra/compose.yaml)
FROM node:22-bookworm-slim AS build
RUN corepack enable
WORKDIR /repo
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml tsconfig.base.json ./
COPY services/api/package.json services/api/
RUN pnpm install --frozen-lockfile --filter @homespotify/api
COPY services/api services/api
RUN pnpm --filter @homespotify/api build \
 && pnpm --filter @homespotify/api deploy --prod /app \
 && cp -r services/api/dist services/api/drizzle /app/

FROM node:22-bookworm-slim
ENV NODE_ENV=production HOST=0.0.0.0 PORT=3000 DB_PATH=/data/db/homespotify.db
WORKDIR /app
COPY --from=build /app /app
RUN useradd --system --create-home appuser \
 && mkdir -p /data/db /data/music \
 && chown -R appuser:appuser /data
USER appuser
EXPOSE 3000
CMD ["node", "dist/server.js"]
