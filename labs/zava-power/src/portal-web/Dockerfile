# ── Build stage ───────────────────────────────────────────
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY . .
ARG VITE_GRID_API_URL=""
ARG VITE_OUTAGE_API_URL=""
ENV VITE_GRID_API_URL=$VITE_GRID_API_URL
ENV VITE_OUTAGE_API_URL=$VITE_OUTAGE_API_URL
RUN chmod -R +x node_modules/.bin && npx vite build

# ── Production stage ─────────────────────────────────────
FROM nginx:alpine
COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
