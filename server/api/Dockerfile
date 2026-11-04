# MUSE API image. Works with either build context (the context is the folder Docker can see):
#
#   context server/api (recommended)    Koyeb: Work directory = server/api, Dockerfile location = Dockerfile
#                                       Railway: Root Directory = /server/api (railway.json is there)
#                                       By hand: docker build -t muse-api server/api
#   context = the repository root       docker build -t muse-api -f server/api/Dockerfile --build-arg APP_DIR=server/api .
#                                       (Koyeb without a work directory: Dockerfile location = server/api/Dockerfile and
#                                        the build argument APP_DIR=server/api)
#
# Sized for a 512 MB instance: production dependencies only, V8 heap capped at 384 MB (NODE_OPTIONS).
ARG APP_DIR=.

FROM node:22-bookworm-slim AS build
ARG APP_DIR
WORKDIR /app
COPY ${APP_DIR}/package.json ${APP_DIR}/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY ${APP_DIR}/tsconfig.json ${APP_DIR}/tsconfig.build.json ./
COPY ${APP_DIR}/src ./src
RUN npm run build && npm prune --omit=dev && npm cache clean --force

FROM node:22-bookworm-slim
ARG APP_DIR
# PORT: Koyeb's default port is 8000 (Railway and Koyeb both set PORT themselves when configured otherwise).
ENV NODE_ENV=production \
    PORT=8000 \
    NODE_OPTIONS=--max-old-space-size=384
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY ${APP_DIR}/package.json ./
COPY ${APP_DIR}/drizzle ./drizzle
COPY ${APP_DIR}/assets ./assets
COPY ${APP_DIR}/scripts/invite.mjs ./scripts/invite.mjs
# Only used without R2 (STORAGE=local): writable, but gone on every redeploy. Production uses R2.
RUN mkdir -p /app/data && chown node:node /app/data
USER node
EXPOSE 8000
# For plain `docker run`; Koyeb and Railway use their own health checks on GET /health (it never wakes the database).
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8000)+'/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"
# Migrations run on start (one transaction, advisory lock). SIGTERM on redeploy or scale-down: the server drains and exits.
CMD ["node", "dist/index.js"]
