FROM node:22-alpine

WORKDIR /app

# Install dependencies
COPY package.json package-lock.json* ./
RUN npm ci

# Copy source and build
COPY svelte.config.js vite.config.ts tsconfig.json ./
COPY src/ ./src/
COPY static/ ./static/
RUN npx svelte-kit sync && npm run build

# Remove dev dependencies after build
RUN npm prune --production

EXPOSE 5173

ENV NODE_ENV=production \
    PORT=5173 \
    HOST=0.0.0.0

CMD ["node", "build/index.js"]
