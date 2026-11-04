# MUSE API. Build context: server/api (Railway: set the service's Root Directory to /server/api).
FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM node:22-bookworm-slim
ENV NODE_ENV=production PORT=8787
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
COPY drizzle ./drizzle
COPY assets ./assets
COPY scripts/invite.mjs ./scripts/invite.mjs
USER node
EXPOSE 8787
# Migrations run on start. Railway sends SIGTERM on redeploy; the server drains and exits.
CMD ["node", "dist/index.js"]
