#!/usr/bin/env bash
# End-to-end: deploy the chart into a k3d cluster and check it comes up.
#   tests/e2e/run.sh <image> [pgsql|sqlite ...]
# The image must exist locally (it is imported, pullPolicy Never). Tracker
# checks are not tested (they need tracker accounts).
set -euo pipefail

IMG=${1:?image (repository:tag)}
shift || true
MODES=("${@:-pgsql}")
[ $# -eq 0 ] && MODES=(pgsql sqlite)
HERE=$(cd "$(dirname "$0")" && pwd)
CHART=$HERE/../../charts/torrentmonitor
CLUSTER=${CLUSTER:-tm-e2e}
KEEP=${KEEP:-}
KUBECONFIG=$(mktemp)
export KUBECONFIG

cleanup() {
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "== FAILED, state:"; kubectl get all -A -o wide || true
        for ns in $(kubectl get ns -o name | grep -o 'tm-.*' || true); do
            kubectl -n "$ns" describe pods || true
            kubectl -n "$ns" logs -l app.kubernetes.io/name=torrentmonitor --all-containers --tail=50 --prefix || true
        done
    fi
    [ -n "$KEEP" ] || k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
    rm -f "$KUBECONFIG"
    exit $rc
}
trap cleanup EXIT

step() { echo; echo "== $*"; }

step "k3d cluster $CLUSTER"
k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
k3d cluster create "$CLUSTER" --no-lb --wait --timeout 180s \
    --k3s-arg '--disable=traefik@server:*' --k3s-arg '--disable=metrics-server@server:*' >/dev/null
k3d kubeconfig get "$CLUSTER" > "$KUBECONFIG"
k3d image import -c "$CLUSTER" "$IMG" >/dev/null
REPO=${IMG%:*}; TAG=${IMG##*:}

for mode in "${MODES[@]}"; do
    ns=tm-$mode
    step "$mode: install"
    kubectl create namespace "$ns" >/dev/null
    if [ "$mode" = pgsql ]; then
        kubectl -n "$ns" apply -f "$HERE/postgres.yaml" >/dev/null
        kubectl -n "$ns" rollout status deploy/tmdb --timeout=180s
    fi
    helm install tm "$CHART" -n "$ns" -f "$HERE/values-$mode.yaml" \
        --set image.repository="$REPO" --set image.tag="$TAG" \
        --set encryptionKey.value="$(openssl rand -hex 32)" --wait --timeout 300s
    kubectl -n "$ns" rollout status deploy/tm-torrentmonitor --timeout=120s
    kubectl -n "$ns" logs deploy/tm-torrentmonitor -c migrate

    step "$mode: HTTP"
    kubectl -n "$ns" port-forward svc/tm-torrentmonitor 18090:80 >/dev/null 2>&1 &
    pf=$!; sleep 3
    code() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:18090$1"; }
    [ "$(code /healthz)" = 200 ] || { echo "healthz: $(code /healthz)"; exit 1; }
    curl -s http://127.0.0.1:18090/ | grep -q 'type="password"' || { echo "no login form"; exit 1; }
    for p in /engine.php /config.php /class/Database.class.php /version.txt /migrate.php; do
        [ "$(code $p)" = 404 ] || { echo "$p: $(code $p), want 404"; exit 1; }
    done
    kill $pf; wait $pf 2>/dev/null || true
    echo "healthz 200, login form, internal paths 404"

    step "$mode: engine run"
    kubectl -n "$ns" create job --from=cronjob/tm-torrentmonitor-engine engine-e2e >/dev/null
    kubectl -n "$ns" wait --for=condition=complete job/engine-e2e --timeout=300s
    kubectl -n "$ns" logs job/engine-e2e -c engine | tail -3
    pod=$(kubectl -n "$ns" get pod -l app.kubernetes.io/component=web -o name | head -1)
    last=$(kubectl -n "$ns" exec "$pod" -c web -- php -r '
        require "/app/config.php"; require "/app/class/Database.class.php";
        echo Database::getSetting("lastStart");')
    [ -n "$last" ] || { echo "lastStart not set"; exit 1; }
    echo "lastStart: $last"

    step "$mode: upgrade (helm upgrade, migrator rerun)"
    helm upgrade tm "$CHART" -n "$ns" --reuse-values --set podAnnotations.e2e=upgrade --wait --timeout 300s
    kubectl -n "$ns" rollout status deploy/tm-torrentmonitor --timeout=120s
    # The newest web pod (the old one may still be terminating).
    newest=$(kubectl -n "$ns" get pod -l app.kubernetes.io/component=web \
        --sort-by=.metadata.creationTimestamp -o name | tail -1)
    kubectl -n "$ns" logs "$newest" -c migrate | tee /dev/stderr | grep -q 'up to date'
    echo "OK: $mode"
done
echo; echo "== all OK: ${MODES[*]}"
