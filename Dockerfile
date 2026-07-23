# ---- Stage 1: install production dependencies ----
FROM node:20-alpine AS deps

WORKDIR /app

COPY app/package.json app/package-lock.json ./
RUN npm ci --omit=dev

# ---- Stage 2: runtime ----
FROM node:20-alpine AS runtime

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

# node:alpine ships with an unprivileged "node" user (uid 1000) - run as that
# instead of root.
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node app/ ./

USER node

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:'+(process.env.PORT||3000)+'/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

CMD ["node", "server.js"]
