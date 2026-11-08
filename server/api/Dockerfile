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
# onnxruntime-node (Recreate's pose model, workstream 1): no CUDA download (CPU only).
ENV ONNXRUNTIME_NODE_INSTALL=skip
RUN npm ci --no-audit --no-fund
COPY ${APP_DIR}/tsconfig.json ${APP_DIR}/tsconfig.build.json ./
COPY ${APP_DIR}/src ./src
# ...and only this platform's onnxruntime binaries (about 47 MB of 294 MB on linux/x64).
RUN npm run build && npm prune --omit=dev && npm cache clean --force \
 && ORT=node_modules/onnxruntime-node/bin/napi-v6 && ARCH=$(node -p process.arch) \
 && rm -rf $ORT/darwin $ORT/win32 && find $ORT/linux -mindepth 1 -maxdepth 1 ! -name "$ARCH" -exec rm -rf {} +

FROM node:22-bookworm-slim
ARG APP_DIR
# PORT: Koyeb's default port is 8000 (Railway and Koyeb both set PORT themselves when configured otherwise).
ENV NODE_ENV=production \
    PORT=8000 \
    NODE_OPTIONS=--max-old-space-size=384
# ffmpeg/ffprobe for Replicate renders: pad the source to whole seconds, trim the result back, mux the audio, thumbnails.
# tesseract (English) reads on-screen words for Recreate this edit (workstream 1; about +22 MB; one item at a time,
# OMP_THREAD_LIMIT=1). Set TESSERACT_PATH to empty to switch it off.
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg tesseract-ocr tesseract-ocr-eng && rm -rf /var/lib/apt/lists/*
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
