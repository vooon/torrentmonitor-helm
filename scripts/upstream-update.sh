#!/usr/bin/env bash
# Moves the submodule to upstream's latest "version" commit and prepares
# everything for review: migrations/update.xml refreshed from xml.tormon.ru,
# VERSION / Chart version / appVersion bumped to <new>-1, and a report of
# versions whose SQL covers other databases but not Postgres. Writes the PR
# body to $1 (default: pr-body.md). Exit 0 without changes if up to date.
set -euo pipefail
cd "$(dirname "$0")/.."
BODY=${1:-pr-body.md}

json_version() { sed -E 's/.*"system":"([^"]+)".*/\1/'; }
old=$(json_version < upstream/version.txt)
old_commit=$(git -C upstream rev-parse HEAD)
git -C upstream fetch --quiet origin master
new=$(git -C upstream show origin/master:version.txt | json_version)
if [ "$old" = "$new" ]; then echo "up to date: $old"; exit 0; fi

commit=$(git -C upstream log -1 --format=%H origin/master -- version.txt)
git -C upstream checkout --quiet "$commit"
echo "upstream $old -> $new ($commit)"

curl -fsSL https://xml.tormon.ru/update.xml -o migrations/update.xml.new
newest=$(python3 -c 'import sys,xml.etree.ElementTree as E; print(E.parse(sys.argv[1]).getroot().find("update").findtext("version"))' migrations/update.xml.new)
if [ "$newest" != "$new" ]; then
    echo "update.xml's newest version is $newest, not $new; try again later"
    rm migrations/update.xml.new; git -C upstream checkout --quiet -; exit 1
fi
mv migrations/update.xml.new migrations/update.xml

ver=$new; [[ $ver =~ ^[0-9]+\.[0-9]+$ ]] && ver=$ver.0
echo "$ver-1" > VERSION
sed -i -E "s/^version: .*/version: $ver-1/; s/^appVersion: .*/appVersion: \"$new\"/" charts/torrentmonitor/Chart.yaml

gaps=$(python3 - "$old" "$new" <<'PY'
import sys, os, xml.etree.ElementTree as E
from functools import cmp_to_key
def vt(v): return tuple(int(x) for x in v.split('.'))
old, new = vt(sys.argv[1]), vt(sys.argv[2])
for u in E.parse('migrations/update.xml').getroot().findall('update'):
    v = u.findtext('version')
    if not (old < vt(v) <= new): continue
    has = {s: len(u.findall(s + '/query')) for s in ('pgsql', 'sqlite', 'mysql', 'queryes')}
    if (has['sqlite'] or has['mysql']) and not has['pgsql'] and not os.path.exists(f'migrations/pgsql/{v}.sql'):
        print(f'- **{v}**: sqlite {has["sqlite"]}, mysql {has["mysql"]}, pgsql 0 queries: add `migrations/pgsql/{v}.sql` if needed')
PY
)

{
  echo "Upstream TorrentMonitor $old → **$new** (\`${commit:0:12}\`)."
  echo
  echo "- submodule \`upstream\` moved"
  echo "- \`migrations/update.xml\` refreshed from xml.tormon.ru: **review the SQL diff**, it runs against the database"
  echo "- \`VERSION\` / chart version \`$ver-1\`, appVersion \`$new\`"
  echo
  echo "Upstream changes: https://github.com/ElizarovEugene/TorrentMonitor/compare/${old_commit}...${commit}"
  echo
  if [ -n "$gaps" ]; then
    echo "### Postgres gaps (SQL for other databases only)"
    echo
    echo "$gaps"
  else
    echo "No Postgres gaps in update.xml for these versions."
  fi
  echo
  echo "CI runs the migration test (upgrade vs fresh install) and the k3d e2e."
} > "$BODY"
cat "$BODY"
