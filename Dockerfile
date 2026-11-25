# ---------- Étape 1 : build ----------
FROM node:22.23.5-alpine3.24 AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build

# ---------- Étape 2 : runtime ----------
FROM nginxinc/nginx-unprivileged:1.30.6-alpine3.24
USER root
# Patch des paquets, suppression de curl et du binaire apk
# (on garde /lib/apk/db pour que les scanners voient les paquets)
RUN apk upgrade --no-cache \
 && apk del --no-cache curl \
 && rm -f /sbin/apk \
 && rm -rf /var/cache/apk/*
COPY --from=build --chown=root:root --chmod=755 /app/dist /usr/share/nginx/html
USER 101
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -q --spider http://127.0.0.1:8080/ || exit 1
