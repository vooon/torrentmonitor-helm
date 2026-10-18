# syntax=docker/dockerfile:1
# TorrentMonitor, immutable: upstream (git submodule, pinned) + patches/ +
# our config.php, migrator and committed migrations. Nothing is downloaded or
# changed at runtime. Build from the repo root (submodule checked out):
#   podman build --build-arg VERSION=$(cat VERSION) -t torrentmonitor:$(cat VERSION) .

# --- source: upstream + patches ----------------------------------------------
FROM docker.io/library/alpine:3.22 AS src
ARG VERSION
RUN apk add --no-cache patch jq
COPY upstream/ /src/
COPY patches/ /patches/
RUN set -eu; \
    for p in /patches/*.patch; do echo "applying $p"; patch -p1 -d /src --no-backup-if-mismatch < "$p"; done; \
    upstream="$(jq -r .system /src/version.txt)"; \
    case "$VERSION" in "$upstream"-*|"$upstream".0-*) ;; *) echo "VERSION=$VERSION does not match upstream version.txt ($upstream)"; exit 1;; esac; \
    rm -rf /src/.git /src/wiki /src/config.php.example /src/torrents/*; \
    find /src -type f -exec chmod 0644 {} +; find /src -type d -exec chmod 0755 {} +

# --- runtime -----------------------------------------------------------------
FROM docker.io/dunglas/frankenphp:1.12.7-php8.4-bookworm
ARG VERSION
LABEL org.opencontainers.image.title="torrentmonitor" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.source="https://github.com/vooon/torrentmonitor-helm"

RUN set -eu; \
    install-php-extensions pdo_pgsql pdo_sqlite zip opcache; \
    # The binary carries cap_net_bind_service (for :80). With all capabilities
    # dropped and no-new-privileges (Kubernetes restricted), exec then fails
    # with EPERM; we listen on :8080 and need none.
    apt-get update; apt-get install -y --no-install-recommends libcap2-bin; \
    setcap -r /usr/local/bin/frankenphp; \
    apt-get purge -y --auto-remove libcap2-bin; rm -rf /var/lib/apt/lists/*; \
    useradd --uid 1000 --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin tm

COPY --from=src /src/ /app/
COPY image/config.php image/migrate.php /app/
COPY migrations/ /usr/share/torrentmonitor/migrations/
# Default extended settings (upstream's, all commented out); mount your own.
COPY upstream/config.xml /etc/torrentmonitor/config.xml
COPY image/Caddyfile /etc/frankenphp/Caddyfile
COPY image/php.ini /usr/local/etc/php/conf.d/zz-torrentmonitor.ini

# Writable at runtime (emptyDir with a read-only root filesystem):
#   /app/torrents  .torrent files on their way to the client
#   /tmp           PHP temp files, Caddy's data/config dirs
RUN install -d -o tm -g tm -m 0755 /app/torrents
ENV XDG_DATA_HOME=/tmp/caddy/data \
    XDG_CONFIG_HOME=/tmp/caddy/config \
    TM_TIMEZONE=UTC

USER 1000:1000
WORKDIR /app
EXPOSE 8080
CMD ["frankenphp", "run", "--config", "/etc/frankenphp/Caddyfile"]
