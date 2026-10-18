# torrentmonitor-helm

Reproducible container image and Helm chart for
[TorrentMonitor](https://github.com/ElizarovEugene/TorrentMonitor).

The image contains everything it runs and never changes itself: no
self-update, no code or SQL downloaded at runtime.

## Layout

```
upstream/                 TorrentMonitor, git submodule pinned to a "version X" commit
patches/                  applied to upstream at build time, in order
image/config.php          replaces upstream's: all settings from the environment
image/migrate.php         database migrator (run before the app)
image/Caddyfile           FrankenPHP: :8080, allowlist of public paths
image/php.ini
migrations/update.xml     upstream's per-version SQL, committed and reviewed
migrations/<db>/<v>.sql   our additions where update.xml has no SQL for a type
charts/torrentmonitor/    Helm chart
tests/migrations.sh       fresh install + upgrade test against a throwaway Postgres
tests/e2e/                k3d end-to-end test of the chart (pgsql and sqlite)
scripts/                  version check, upstream update
.github/                  CI, release, upstream watch, Dependabot
VERSION                   <upstream version>-<release>
```

## Versions

`VERSION` is `<upstream version>-<release>`, e.g. `3.3.6-1`: the image tag
and the chart `version`. The chart `appVersion` is the upstream version
(`3.3.6`); the chart's default image tag is its `version`. A new upstream version resets the
release to 1; changes here (patches, image, chart) increment it. Upstream
versions with two parts (`3.3`) become `3.3.0-N`. The build fails if
`VERSION` does not match `upstream/version.txt`.

## Patches

- `0001-disable-self-update`: `Sys::checkUpdate()` returns false and
  `Update::main()` does nothing: no requests to xml.tormon.ru, no code
  downloads, no runtime schema changes.
- `0002-last-start-in-database`: the last engine run is stored in
  `settings.lastStart` instead of `laststart.txt` (read-only code, engine in a
  separate pod).
- `0003-no-remote-news`: no news from xml.tormon.ru. Upstream stores that
  text and renders it unescaped in the logged-in UI (and sends it as a
  notification), i.e. remote HTML in an authenticated page.

The only remaining tormon.ru address is `lf.tormon.ru`, the feed of the
optional "lostfilm mirror" tracker, used only if you add that tracker.

## Configuration (environment)

| Variable | |
|---|---|
| `TM_ENCRYPTION_KEY` | **required**, 64 hex characters: encrypts the stored tracker and client passwords (upstream would store them in plain text without it) |
| `TM_DB_TYPE` | `pgsql` (default) or `sqlite` |
| `TM_DB_HOST`, `TM_DB_PORT`, `TM_DB_NAME`, `TM_DB_USER`, `TM_DB_PASSWORD` | pgsql |
| `TM_DB_PATH` | sqlite: database file |
| `TM_CONFIG_XML` | extended settings (default `/etc/torrentmonitor/config.xml`, upstream's template); read-only, so the UI's "extended settings" save fails: manage the file instead |
| `TM_TIMEZONE` | PHP time zone (default `UTC`) |
| `TM_DB_BASELINE_VERSION` | migrator only: adopt an existing database at this version |

Runs as uid 1000 with a read-only root filesystem; writable: `/tmp` and
`/app/torrents` (.torrent files on their way to the client).

## Database migrations

Upstream records the database version in `version.txt` next to the code and
changes both by self-update. Here `php /app/migrate.php`:

- empty database: loads upstream's `db_schema/<type>.sql`, records the version
  in `tm_schema_version`;
- otherwise applies every `update.xml` step newer than the recorded version, up
  to the image's, oldest first, one transaction per step, plus
  `migrations/<type>/<version>.sql`;
- refuses a database newer than the image, and an existing install without
  `tm_schema_version` unless `TM_DB_BASELINE_VERSION` is set;
- moves Postgres sequences past existing ids (upstream's schema inserts rows
  with explicit ids behind the sequences' backs).

Upstream's update.xml has gaps for Postgres (e.g. 3.3.4 adds `cf_userAgent`
for sqlite and mysql only); `migrations/pgsql/3.3.4.sql` fills it.
`tests/migrations.sh` catches such gaps: it upgrades an older upstream schema
and compares it with a fresh install.

## Build and test

```sh
git submodule update --init
podman build --build-arg VERSION=$(cat VERSION) -t torrentmonitor:$(cat VERSION) .
tests/migrations.sh torrentmonitor:$(cat VERSION)
```

## Chart

```sh
helm install tm oci://ghcr.io/vooon/charts/torrentmonitor --version 3.3.6-1 \
  --set encryptionKey.value=$(openssl rand -hex 32) \
  --set database.pgsql.existingSecret=<cnpg-cluster>-app
```

- Deployment (web, FrankenPHP :8080) with the migrator as init container;
  CronJob `<release>-torrentmonitor-engine` runs `engine.php`
  (`engine.schedule`), also behind the migrator, so neither runs on an older
  schema after an upgrade.
- `database.type: pgsql` reads the connection from `database.pgsql.existingSecret`
  (keys default to CloudNativePG's `<cluster>-app`); `sqlite` uses a PVC shared
  by web and engine (ReadWriteOnce: the engine runs on the web pod's node).
- `encryptionKey`: `existingSecret` or `value` (the chart's Secret is kept on
  uninstall).
- `configXml`: extended settings (per-tracker mirrors/proxies).
- Optional: Ingress, NetworkPolicy (ingress peers, egress rules; DNS always),
  FlareSolverr (rutracker's Cloudflare challenge; URL in the UI settings).
- The first login uses upstream's default password: change it.

## Tests

```sh
podman build --build-arg VERSION=$(cat VERSION) -t localhost/torrentmonitor:$(cat VERSION) .
tests/migrations.sh localhost/torrentmonitor:$(cat VERSION)
tests/e2e/run.sh localhost/torrentmonitor:$(cat VERSION) pgsql sqlite
```

The e2e test creates a k3d cluster, imports the image, installs the chart
(pgsql: with a plain Postgres and the NetworkPolicy on; sqlite) and checks:
rollout, `/healthz`, the login page, internal paths 404, an engine run
(`settings.lastStart` set), and a `helm upgrade` (migrator: up to date).
Tracker checks are not tested (accounts needed). With rootless podman, k3s
needs the `cpuset` controller delegated to the user
(`Delegate=cpu cpuset io memory pids` in a `user@.service` drop-in).

## CI and releases

- `ci.yml` (push, PR): versions, helm lint, image build, migration test, k3d
  e2e.
- `release.yml` (tag `v<VERSION>`, e.g. `v3.3.6-1`): image
  `ghcr.io/vooon/torrentmonitor:<VERSION>` (amd64, arm64) and the chart
  `oci://ghcr.io/vooon/charts/torrentmonitor`.
- `upstream.yml` (daily): new upstream version → PR (below). Set the secret
  `PR_TOKEN` (fine-grained PAT: contents and pull requests write), or the PR
  does not trigger CI.
- Dependabot: GitHub Actions and the Dockerfile base images. Not the
  submodule (upstream.yml), and not image tags in `values.yaml` (FlareSolverr)
  or the tests: bump those by hand.

A change of our own (patches, image, chart) bumps the release:
`VERSION` and the chart `version` to `<upstream>-<release+1>`, then tag.

## Updating upstream

`scripts/upstream-update.sh` (run daily by `upstream.yml`, or by hand):

1. moves the submodule to upstream's latest commit that changed `version.txt`;
2. refreshes `migrations/update.xml` from https://xml.tormon.ru/update.xml
   (must already list the new version): **review the SQL diff**;
3. sets `VERSION` and the chart version to `<new>-1`, appVersion to `<new>`;
4. lists versions with SQL for sqlite/mysql but none for Postgres: add
   `migrations/pgsql/<v>.sql` where needed.
