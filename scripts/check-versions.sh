#!/usr/bin/env bash
# VERSION (<upstream>-<release>) must equal the chart version; the chart
# appVersion and VERSION's upstream part must equal upstream/version.txt
# (two-part upstream versions are written X.Y.0 in VERSION).
set -euo pipefail
cd "$(dirname "$0")/.."
v=$(cat VERSION)
upstream=$(sed -E 's/.*"system":"([^"]+)".*/\1/' upstream/version.txt)
chart_version=$(sed -nE 's/^version: *"?([^"]+)"?$/\1/p' charts/torrentmonitor/Chart.yaml)
app_version=$(sed -nE 's/^appVersion: *"?([^"]+)"?$/\1/p' charts/torrentmonitor/Chart.yaml)
[[ $v =~ ^([0-9]+\.[0-9]+(\.[0-9]+)?)-([0-9]+)$ ]] || { echo "VERSION '$v' is not <upstream>-<release>"; exit 1; }
base=${BASH_REMATCH[1]}
[ "$base" = "$upstream" ] || [ "$base" = "$upstream.0" ] || { echo "VERSION $v vs upstream $upstream"; exit 1; }
[ "$chart_version" = "$v" ] || { echo "Chart version $chart_version vs VERSION $v"; exit 1; }
[ "$app_version" = "$upstream" ] || { echo "Chart appVersion $app_version vs upstream $upstream"; exit 1; }
echo "versions OK: $v (upstream $upstream)"
