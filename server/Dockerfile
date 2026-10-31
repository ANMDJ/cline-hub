FROM node:22-alpine AS deps
WORKDIR /app
# 国内构建时用 npmmirror：docker compose build --build-arg NPM_REGISTRY=https://registry.npmmirror.com
ARG NPM_REGISTRY=https://registry.npmjs.org
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --registry=$NPM_REGISTRY

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production \
    HUB_HOST=0.0.0.0 \
    HUB_PORT=3100 \
    HUB_AUTO_MIGRATE=0
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
COPY migrations ./migrations
COPY scripts ./scripts
EXPOSE 3100
USER node
CMD ["node", "src/index.js"]
