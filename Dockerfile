# syntax=docker/dockerfile:1.7

# ============================================
# 可重现构建：所有基础镜像固定摘要
# 提示：定期运行以下命令更新摘要：
#   docker manifest inspect node:22-bookworm | grep "digest"
#   docker manifest inspect node:22-bookworm-slim | grep "digest"
# ============================================

ARG OPENCLAW_EXTENSIONS=""
ARG OPENCLAW_VARIANT=default

# 基础镜像摘要（定期更新）
ARG OPENCLAW_NODE_BOOKWORM_DIGEST="sha256:b501c082306a4f528bc4038cbf2fbb58095d583d0419a259b2114b5ac53d12e9"
ARG OPENCLAW_NODE_BOOKWORM_SLIM_DIGEST="sha256:9c2c405e3ff9b9afb2873232d24bb06367d649aa3e6259cbe314da59578e81e9"

FROM node:22-bookworm@${OPENCLAW_NODE_BOOKWORM_DIGEST} AS ext-deps
ARG OPENCLAW_EXTENSIONS
COPY extensions /tmp/extensions
RUN mkdir -p /out && \
    for ext in $OPENCLAW_EXTENSIONS; do \
      if [ -f "/tmp/extensions/$ext/package.json" ]; then \
        mkdir -p "/out/$ext" && \
        cp "/tmp/extensions/$ext/package.json" "/out/$ext/package.json"; \
      fi; \
    done

# ── Stage 2: Build ──────────────────────────────────────────────
FROM node:22-bookworm@${OPENCLAW_NODE_BOOKWORM_DIGEST} AS build

# 安装 Bun（使用官方安装脚本）
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app

# 复制依赖相关文件（优先利用缓存）
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY --from=ext-deps /out/ ./extensions/

# 挂载 pnpm store 缓存，并限制内存
RUN --mount=type=cache,id=openclaw-pnpm-store,target=/root/.local/share/pnpm/store,sharing=locked \
    NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile

# 复制剩余源码（扩展源码此时才引入，缓存依赖层）
COPY . .

# 统一设置目录权限
RUN for dir in /app/extensions /app/.agent /app/.agents; do \
      if [ -d "$dir" ]; then \
        find "$dir" -type d -exec chmod 755 {} +; \
        find "$dir" -type f -exec chmod 644 {} +; \
      fi; \
    done

# 构建 A2UI 并处理跨架构兼容性
RUN pnpm canvas:a2ui:bundle || \
    (echo "A2UI bundle: creating stub (non-fatal)" && \
     mkdir -p src/canvas-host/a2ui && \
     echo "/* A2UI bundle unavailable in this build */" > src/canvas-host/a2ui/a2ui.bundle.js && \
     echo "stub" > src/canvas-host/a2ui/.bundle.hash && \
     rm -rf vendor/a2ui apps/shared/OpenClawKit/Tools/CanvasA2UI)

# 构建主项目和 UI（强制 pnpm）
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm build:docker && pnpm ui:build

# 修剪开发依赖并清理类型文件
FROM build AS runtime-assets
RUN CI=true pnpm prune --prod && \
    find dist -type f \( -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' -o -name '*.map' \) -delete

# ── Runtime base images ─────────────────────────────────────────
FROM node:22-bookworm@${OPENCLAW_NODE_BOOKWORM_DIGEST} AS base-default
LABEL org.opencontainers.image.base.name="docker.io/library/node:22-bookworm" \
      org.opencontainers.image.base.digest="${OPENCLAW_NODE_BOOKWORM_DIGEST}"

FROM node:22-bookworm-slim@${OPENCLAW_NODE_BOOKWORM_SLIM_DIGEST} AS base-slim
LABEL org.opencontainers.image.base.name="docker.io/library/node:22-bookworm-slim" \
      org.opencontainers.image.base.digest="${OPENCLAW_NODE_BOOKWORM_SLIM_DIGEST}"

# ── Stage 3: Runtime ────────────────────────────────────────────
FROM base-${OPENCLAW_VARIANT}
ARG OPENCLAW_VARIANT
ARG OPENCLAW_DOCKER_APT_PACKAGES=""
ARG OPENCLAW_INSTALL_BROWSER=""
ARG OPENCLAW_INSTALL_DOCKER_CLI=""
ARG OPENCLAW_DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

LABEL org.opencontainers.image.source="https://github.com/openclaw/openclaw" \
      org.opencontainers.image.url="https://openclaw.ai" \
      org.opencontainers.image.documentation="https://docs.openclaw.ai/install/docker" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.title="OpenClaw" \
      org.opencontainers.image.description="OpenClaw gateway and CLI runtime container image"

WORKDIR /app

# 合并系统依赖安装，减少层数
RUN --mount=type=cache,id=openclaw-bookworm-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=openclaw-bookworm-apt-lists,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      procps hostname curl git openssl \
      $OPENCLAW_DOCKER_APT_PACKAGES \
    && if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
         apt-get install -y --no-install-recommends xvfb; \
       fi \
    && if [ -n "$OPENCLAW_INSTALL_DOCKER_CLI" ]; then \
         apt-get install -y --no-install-recommends ca-certificates curl gnupg \
         && install -m 0755 -d /etc/apt/keyrings \
         && curl -fsSL https://download.docker.com/linux/debian/gpg -o /tmp/docker.gpg.asc \
         && expected_fingerprint="$(printf '%s' "$OPENCLAW_DOCKER_GPG_FINGERPRINT" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')" \
         && actual_fingerprint="$(gpg --batch --show-keys --with-colons /tmp/docker.gpg.asc | awk -F: '$1 == "fpr" { print toupper($10); exit }')" \
         && if [ -z "$actual_fingerprint" ] || [ "$actual_fingerprint" != "$expected_fingerprint" ]; then \
              echo "ERROR: Docker apt key fingerprint mismatch" >&2; exit 1; \
            fi \
         && gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg.asc \
         && rm -f /tmp/docker.gpg.asc \
         && chmod a+r /etc/apt/keyrings/docker.gpg \
         && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
         && apt-get update \
         && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin; \
       fi \
    && rm -rf /var/lib/apt/lists/*

# 准备用户目录
RUN chown node:node /app

# 合并 COPY 指令，减少层数（利用 --link 优化性能）
COPY --from=runtime-assets --chown=node:node --link /app/dist ./dist
COPY --from=runtime-assets --chown=node:node --link /app/node_modules ./node_modules
COPY --from=runtime-assets --chown=node:node --link /app/package.json .
COPY --from=runtime-assets --chown=node:node --link /app/openclaw.mjs .
COPY --from=runtime-assets --chown=node:node --link /app/extensions ./extensions
COPY --from=runtime-assets --chown=node:node --link /app/skills ./skills
COPY --from=runtime-assets --chown=node:node --link /app/docs ./docs

# 配置 Corepack（共享目录，避免运行时下载）
ENV COREPACK_HOME=/usr/local/share/corepack
RUN install -d -m 0755 "$COREPACK_HOME" && \
    corepack enable && \
    corepack prepare "$(node -p "require('./package.json').packageManager")" --activate && \
    chmod -R a+rX "$COREPACK_HOME"

# 安装浏览器（需要 node_modules 存在，且 playwright-core 可用）
RUN if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
      mkdir -p /home/node/.cache/ms-playwright && \
      PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright \
      node /app/node_modules/playwright-core/cli.js install --with-deps chromium && \
      chown -R node:node /home/node/.cache/ms-playwright; \
    fi

# 创建 CLI 软链接
RUN ln -sf /app/openclaw.mjs /usr/local/bin/openclaw && chmod 755 /app/openclaw.mjs

# 暴露新的网关端口
EXPOSE 7860

ENV NODE_ENV=production
USER node

# 健康检查使用新端口
HEALTHCHECK --interval=3m --timeout=10s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:7860/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# 启动网关时指定端口 7860
CMD ["node", "openclaw.mjs", "gateway", "--port", "7860", "--allow-unconfigured"]
