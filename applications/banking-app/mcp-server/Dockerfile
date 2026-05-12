FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

COPY dist/ ./dist/

EXPOSE 3001

ENV NODE_ENV=production \
    MCP_PORT=3001

CMD ["node", "dist/index.js"]
