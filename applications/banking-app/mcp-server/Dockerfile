FROM node:22-alpine

WORKDIR /app

# Install dependencies first (cache layer)
COPY package.json package-lock.json* ./
RUN npm ci --only=production=false

# Copy source and build
COPY tsconfig.json ./
COPY src/ ./src/
RUN npm run build

# Remove dev dependencies after build
RUN npm prune --production

EXPOSE 3001

ENV NODE_ENV=production \
    MCP_PORT=3001

CMD ["node", "dist/index.js"]
