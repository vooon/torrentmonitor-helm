# torrentmonitor-helm

Reproducible container image (and, next, a Helm chart) for
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
tests/migrations.sh       fresh install + upgrade test against a throwaway Postgres
VERSION                   <upstream version>-<release>
```

## Versions

`VERSION` is `<upstream version>-<release>`, e.g. `3.3.6-1`, used for the
image tag and (next) the chart version. A new upstream version resets the
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

## Updating upstream

1. Move the submodule to the new "version X" commit.
2. Refresh `migrations/update.xml` from https://xml.tormon.ru/update.xml and
   review the diff (it is SQL that will run against the database).
3. Add `migrations/pgsql/<v>.sql` where the new version has SQL for other
   databases but not for Postgres.
4. `VERSION` = `<new version>-1`, build, run the test.
