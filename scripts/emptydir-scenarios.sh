#!/usr/bin/env bash
# =============================================================================
# emptydir-scenarios.sh
# Reproduces emptyDir cache-volume scenarios on a Kubernetes cluster and
# records what actually happens: eviction, OOMKill, ENOSPC, node pressure.
#
# Usage:
#   ./emptydir-scenarios.sh list
#   ./emptydir-scenarios.sh show <id>            # print the pod manifest only
#   ./emptydir-scenarios.sh run  <id> [<id>...]  # run selected scenarios
#   ./emptydir-scenarios.sh run  all             # run all scenarios (dangerous ones skipped)
#   ./emptydir-scenarios.sh cleanup
#
# Tunables (env vars):
#   NS=emptydir-test      namespace to use (created if missing)
#   NODE=<node-name>      pin test pods to one node (STRONGLY recommended)
#   SIZE_SMALL=3Gi        "small" emptyDir sizeLimit
#   SIZE_LARGE=10Gi       "large" emptyDir sizeLimit
#   MEM_LIMIT=10Gi        memory limit used in "with limits" scenarios
#   EPH_REQ=3Gi EPH_LIM=5Gi  ephemeral-storage request/limit (scenario 8)
#   WRITE_GB=12           how much the writer tries to write into the cache
#   CHUNK_MB=256          size of each written file
#   WRITE_DELAY=0         seconds to sleep between chunks (slow writer)
#   WATCH_SECS=300        max seconds to observe each scenario
#   POLL=5                seconds between samples
#   IMAGE=busybox:1.36
#   ALLOW_NODE_IMPACT=1   required for scenarios that can fill node disk/RAM
#
# Small test node? Scale everything down, e.g.:
#   SIZE_SMALL=1Gi SIZE_LARGE=2Gi MEM_LIMIT=2Gi WRITE_GB=3 ./emptydir-scenarios.sh run all
#
# Requires: kubectl, jq. Reading kubelet stats needs RBAC on nodes/proxy.
# =============================================================================
set -euo pipefail

NS="${NS:-emptydir-test}"
NODE="${NODE:-}"
SIZE_SMALL="${SIZE_SMALL:-3Gi}"
SIZE_LARGE="${SIZE_LARGE:-10Gi}"
MEM_LIMIT="${MEM_LIMIT:-10Gi}"
EPH_REQ="${EPH_REQ:-3Gi}"
EPH_LIM="${EPH_LIM:-5Gi}"
WRITE_GB="${WRITE_GB:-12}"
CHUNK_MB="${CHUNK_MB:-256}"
WRITE_DELAY="${WRITE_DELAY:-0}"
WATCH_SECS="${WATCH_SECS:-300}"
POLL="${POLL:-5}"
IMAGE="${IMAGE:-busybox:1.36}"
ALLOW_NODE_IMPACT="${ALLOW_NODE_IMPACT:-0}"
OUT_DIR="${OUT_DIR:-./emptydir-results-$(date +%Y%m%d-%H%M%S)}"

ALL_IDS="1 2 3 4 5 6 7 8 9 10"

# -----------------------------------------------------------------------------
# Scenario definitions
#   MEDIUM   : "" (node disk) | Memory (tmpfs) | none (no emptyDir, container rootfs)
#   SIZE     : emptyDir sizeLimit or "none"
#   MEM      : memory limit or "none"
#   EREQ/ELIM: ephemeral-storage request/limit or "none"
#   DANGER   : 1 = can exhaust node disk or RAM
# -----------------------------------------------------------------------------
scenario_def() {
  MEDIUM=""; SIZE="none"; MEM="none"; EREQ="none"; ELIM="none"; DANGER=0; DESC=""
  case "$1" in
    1)  SIZE="$SIZE_SMALL";                       DESC="disk emptyDir sizeLimit=$SIZE_SMALL, no limits" ;;
    2)  SIZE="$SIZE_SMALL"; MEM="$MEM_LIMIT";     DESC="disk emptyDir sizeLimit=$SIZE_SMALL, mem limit=$MEM_LIMIT" ;;
    3)  SIZE="$SIZE_LARGE"; MEM="$MEM_LIMIT";     DESC="disk emptyDir sizeLimit=$SIZE_LARGE, mem limit=$MEM_LIMIT" ;;
    4)  DANGER=1;                                 DESC="disk emptyDir unlimited, no limits" ;;
    5)  MEDIUM="Memory"; DANGER=1;                DESC="tmpfs emptyDir, no sizeLimit, no limits" ;;
    6)  MEDIUM="Memory"; MEM="$MEM_LIMIT";        DESC="tmpfs emptyDir, no sizeLimit, mem limit=$MEM_LIMIT" ;;
    7)  MEDIUM="Memory"; SIZE="$SIZE_SMALL"; MEM="$MEM_LIMIT"; DESC="tmpfs emptyDir sizeLimit=$SIZE_SMALL, mem limit=$MEM_LIMIT (recommended tmpfs pattern)" ;;
    8)  EREQ="$EPH_REQ"; ELIM="$EPH_LIM";         DESC="disk emptyDir unlimited, ephemeral-storage req=$EPH_REQ lim=$EPH_LIM (recommended disk pattern)" ;;
    9)  MEDIUM="none"; DANGER=1;                  DESC="no emptyDir: cache written to container writable layer, no limits" ;;
    10) MEDIUM="Memory"; SIZE="$SIZE_LARGE"; MEM="$MEM_LIMIT"; DESC="tmpfs sizeLimit == mem limit ($SIZE_LARGE/$MEM_LIMIT): zero headroom for the app" ;;
    *)  echo "Unknown scenario: $1" >&2; return 1 ;;
  esac
}

pod_name() { echo "edt-s$1"; }

# -----------------------------------------------------------------------------
# Writer script that runs inside the test container
# -----------------------------------------------------------------------------
writer_script() {
cat <<'EOS'
T="${TARGET_DIR:-/cache}"; mkdir -p "$T"
if [ -f /sys/fs/cgroup/memory.current ]; then MF=/sys/fs/cgroup/memory.current
elif [ -f /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then MF=/sys/fs/cgroup/memory/memory.usage_in_bytes
else MF=""; fi
mem() { if [ -n "$MF" ]; then echo $(( $(cat "$MF") / 1048576 )); else echo "?"; fi; }
used() { du -sm "$T" 2>/dev/null | cut -f1; }
echo "[start] $(date +%T) dir=$T existing_cache=$(used)MB cgroup_mem=$(mem)MB fs=$(df -h "$T" | tail -1)"
i=0
while :; do
  u=$(used)
  if [ "$u" -ge $(( WRITE_GB * 1024 )) ]; then break; fi
  if ! dd if=/dev/zero of="$T/chunk_$(date +%s)_$i" bs=1M count="$CHUNK_MB" 2>/tmp/dd.err; then
    echo "[write-error] $(date +%T) cache=${u}MB err=$(tail -1 /tmp/dd.err)"; sleep 10; continue
  fi
  i=$((i+1))
  echo "[progress] $(date +%T) cache=$(used)MB cgroup_mem=$(mem)MB"
  [ "$WRITE_DELAY" -gt 0 ] && sleep "$WRITE_DELAY"
done
echo "[done] $(date +%T) cache=$(used)MB cgroup_mem=$(mem)MB"
while true; do sleep 3600; done
EOS
}

# -----------------------------------------------------------------------------
# Manifest generator
# -----------------------------------------------------------------------------
gen_manifest() {
  local id="$1" name; scenario_def "$id"; name="$(pod_name "$id")"
  local target="/cache"; [ "$MEDIUM" = "none" ] && target="/scratch"

  echo "apiVersion: v1"
  echo "kind: Pod"
  echo "metadata:"
  echo "  name: $name"
  echo "  namespace: $NS"
  echo "  labels: {app: emptydir-test, scenario: \"$id\"}"
  echo "  annotations: {emptydir-test/description: \"$DESC\"}"
  echo "spec:"
  echo "  restartPolicy: Always"
  echo "  terminationGracePeriodSeconds: 1"
  [ -n "$NODE" ] && echo "  nodeName: $NODE"
  echo "  containers:"
  echo "  - name: writer"
  echo "    image: $IMAGE"
  echo "    command: [\"sh\", \"-c\"]"
  echo "    args:"
  echo "    - |"
  writer_script | sed 's/^/      /'
  echo "    env:"
  echo "    - {name: TARGET_DIR, value: \"$target\"}"
  echo "    - {name: WRITE_GB, value: \"$WRITE_GB\"}"
  echo "    - {name: CHUNK_MB, value: \"$CHUNK_MB\"}"
  echo "    - {name: WRITE_DELAY, value: \"$WRITE_DELAY\"}"

  local lim="" req=""
  [ "$MEM"  != "none" ] && lim="${lim}memory: $MEM, "
  [ "$ELIM" != "none" ] && lim="${lim}ephemeral-storage: $ELIM, "
  [ "$EREQ" != "none" ] && req="${req}ephemeral-storage: $EREQ, "
  if [ -n "$lim$req" ]; then
    echo "    resources:"
    [ -n "$req" ] && echo "      requests: {${req%, }}"
    [ -n "$lim" ] && echo "      limits: {${lim%, }}"
  fi

  if [ "$MEDIUM" != "none" ]; then
    echo "    volumeMounts:"
    echo "    - {name: cache, mountPath: /cache}"
    echo "  volumes:"
    echo "  - name: cache"
    local ed=""
    [ "$MEDIUM" = "Memory" ] && ed="${ed}medium: Memory, "
    [ "$SIZE" != "none" ]    && ed="${ed}sizeLimit: $SIZE, "
    echo "    emptyDir: {${ed%, }}"
  fi
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
log()  { echo "[$(date +%T)] $*"; }

node_cond() { # node, condition type
  kubectl get node "$1" -o jsonpath="{.status.conditions[?(@.type==\"$2\")].status}" 2>/dev/null || echo "?"
}

stats_sample() { # node pod -> "cacheMB wsMB ephMB nodeFsAvailMB nodeMemAvailMB"
  kubectl get --raw "/api/v1/nodes/$1/proxy/stats/summary" 2>/dev/null | jq -r --arg p "$2" --arg ns "$NS" '
    (.node.fs.availableBytes // 0) as $nfs | (.node.memory.availableBytes // 0) as $nmem |
    ([.pods[] | select(.podRef.name==$p and .podRef.namespace==$ns)][0]) as $pod |
    [ (($pod.volume // []) | map(select(.name=="cache"))[0].usedBytes // 0),
      ($pod.memory.workingSetBytes // 0),
      ($pod["ephemeral-storage"].usedBytes // 0), $nfs, $nmem ]
    | map(. / 1048576 | floor) | @tsv' 2>/dev/null || printf '?\t?\t?\t?\t?\n'
}

ensure_ns() { kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null; }

# -----------------------------------------------------------------------------
# Run one scenario
# -----------------------------------------------------------------------------
run_one() {
  local id="$1" name; scenario_def "$id"; name="$(pod_name "$id")"
  local dir="$OUT_DIR/s$id"; mkdir -p "$dir"

  if [ "$DANGER" = "1" ] && [ "$ALLOW_NODE_IMPACT" != "1" ]; then
    log "S$id SKIPPED (can exhaust node disk/RAM). Re-run with ALLOW_NODE_IMPACT=1 on a test node."
    echo "$id|$DESC|SKIPPED|-|-|-|-|-|-" >> "$OUT_DIR/summary.psv"; return
  fi

  log "===== Scenario $id: $DESC ====="
  kubectl -n "$NS" delete pod "$name" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  gen_manifest "$id" > "$dir/pod.yaml"
  kubectl apply -f "$dir/pod.yaml" >/dev/null

  local node="" t=0
  while [ -z "$node" ] && [ $t -lt 60 ]; do
    node=$(kubectl -n "$NS" get pod "$name" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
    sleep 2; t=$((t+2))
  done
  if [ -z "$node" ]; then
    log "S$id not scheduled within 60s (check requests vs node capacity)."
    kubectl -n "$NS" describe pod "$name" > "$dir/describe.txt" 2>&1 || true
    echo "$id|$DESC|UNSCHEDULABLE|-|-|-|-|-|-" >> "$OUT_DIR/summary.psv"; return
  fi
  log "S$id scheduled on $node"

  printf "time\tphase\treason\trestarts\tlastTerm\tcacheMB\tworkingSetMB\tephMB\tnodeFsAvailMB\tnodeMemAvailMB\tDiskPressure\tMemoryPressure\n" > "$dir/samples.tsv"

  local start; start=$(date +%s)
  local outcome="RUNNING" peak_cache=0 peak_ws=0 disk_p="False" mem_p="False"
  while :; do
    local now=$(( $(date +%s) - start ))
    local js; js=$(kubectl -n "$NS" get pod "$name" -o json 2>/dev/null || echo '{}')
    local phase reason restarts lastterm waiting
    phase=$(echo "$js"    | jq -r '.status.phase // "Gone"')
    reason=$(echo "$js"   | jq -r '.status.reason // "-"')
    restarts=$(echo "$js" | jq -r '.status.containerStatuses[0].restartCount // 0')
    lastterm=$(echo "$js" | jq -r '.status.containerStatuses[0].lastState.terminated.reason // "-"')
    waiting=$(echo "$js"  | jq -r '.status.containerStatuses[0].state.waiting.reason // "-"')

    local s; s=$(stats_sample "$node" "$name")
    local cache ws eph nfs nmem; IFS=$'\t' read -r cache ws eph nfs nmem <<< "$s"
    local dp mp; dp=$(node_cond "$node" DiskPressure); mp=$(node_cond "$node" MemoryPressure)
    [ "$dp" = "True" ] && disk_p="True"
    [ "$mp" = "True" ] && mem_p="True"
    if [[ "$cache" =~ ^[0-9]+$ ]] && [ "$cache" -gt "$peak_cache" ]; then peak_cache=$cache; fi
    if [[ "$ws"    =~ ^[0-9]+$ ]] && [ "$ws"    -gt "$peak_ws"    ]; then peak_ws=$ws; fi

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$now" "$phase" "$reason" "$restarts" "$lastterm" "$cache" "$ws" "$eph" "$nfs" "$nmem" "$dp" "$mp" >> "$dir/samples.tsv"
    log "S$id t=${now}s phase=$phase reason=$reason restarts=$restarts lastTerm=$lastterm waiting=$waiting cache=${cache}MB ws=${ws}MB nodeFsAvail=${nfs}MB nodeMemAvail=${nmem}MB DiskP=$dp MemP=$mp"

    if [ "$reason" = "Evicted" ]; then outcome="EVICTED"; break; fi
    if [ "$phase" = "Failed" ] || [ "$phase" = "Gone" ]; then outcome="FAILED($reason)"; break; fi
    if [ "$restarts" -ge 3 ]; then outcome="${lastterm}_LOOP(restarts=$restarts)"; break; fi
    if kubectl -n "$NS" logs "$name" --tail=50 2>/dev/null | grep -q '^\[done\]'; then
      sleep "$((POLL*3))"   # give kubelet a few housekeeping cycles to react
      js=$(kubectl -n "$NS" get pod "$name" -o json 2>/dev/null || echo '{}')
      if [ "$(echo "$js" | jq -r '.status.reason // "-"')" = "Evicted" ]; then outcome="EVICTED"; else outcome="COMPLETED_NO_ACTION"; fi
      break
    fi
    if kubectl -n "$NS" logs "$name" --tail=5 2>/dev/null | grep -q '^\[write-error\]'; then
      outcome="ENOSPC"
    fi
    if [ "$now" -ge "$WATCH_SECS" ]; then [ "$outcome" = "RUNNING" ] && outcome="TIMEOUT"; break; fi
    sleep "$POLL"
  done

  kubectl -n "$NS" get pod "$name" -o yaml           > "$dir/pod-final.yaml"    2>&1 || true
  kubectl -n "$NS" describe pod "$name"              > "$dir/describe.txt"      2>&1 || true
  kubectl -n "$NS" logs "$name"                      > "$dir/logs.txt"          2>&1 || true
  kubectl -n "$NS" logs "$name" --previous           > "$dir/logs-previous.txt" 2>&1 || true
  kubectl -n "$NS" get events --field-selector "involvedObject.name=$name" --sort-by=.lastTimestamp > "$dir/events.txt" 2>&1 || true
  kubectl get events -A --field-selector "involvedObject.kind=Node,involvedObject.name=$node" --sort-by=.lastTimestamp > "$dir/node-events.txt" 2>&1 || true
  local msg; msg=$(kubectl -n "$NS" get pod "$name" -o jsonpath='{.status.message}' 2>/dev/null | tr '|' '/' | cut -c1-160 || true)

  log "S$id OUTCOME: $outcome  ${msg:+($msg)}"
  echo "$id|$DESC|$outcome|$node|$peak_cache|$peak_ws|$disk_p|$mem_p|${msg:--}" >> "$OUT_DIR/summary.psv"

  kubectl -n "$NS" delete pod "$name" --wait=true >/dev/null 2>&1 || true
  local w=0
  while [ "$(node_cond "$node" DiskPressure)" = "True" ] || [ "$(node_cond "$node" MemoryPressure)" = "True" ]; do
    [ $w -ge 300 ] && break
    log "waiting for node $node pressure to clear..."; sleep 10; w=$((w+10))
  done
}

print_summary() {
  local f="$OUT_DIR/summary.psv"; [ -f "$f" ] || return 0
  {
    echo "# emptyDir scenario results ($(date))"
    echo
    echo "WRITE_GB=$WRITE_GB SIZE_SMALL=$SIZE_SMALL SIZE_LARGE=$SIZE_LARGE MEM_LIMIT=$MEM_LIMIT EPH=$EPH_REQ/$EPH_LIM"
    echo
    echo "| # | Scenario | Outcome | Node | Peak cache MB | Peak workingSet MB | DiskPressure | MemoryPressure | Message |"
    echo "|---|---|---|---|---|---|---|---|---|"
    while IFS='|' read -r a b c d e f2 g h i; do
      echo "| $a | $b | $c | $d | $e | $f2 | $g | $h | $i |"
    done < "$f"
  } > "$OUT_DIR/summary.md"
  echo; cat "$OUT_DIR/summary.md"; echo; log "Evidence saved in $OUT_DIR"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
cmd="${1:-help}"; shift || true
case "$cmd" in
  list)
    for i in $ALL_IDS; do scenario_def "$i"; printf "%3s  %-6s %s\n" "$i" "$([ "$DANGER" = 1 ] && echo DANGER || echo safe)" "$DESC"; done ;;
  show)
    [ $# -ge 1 ] || { echo "usage: $0 show <id>"; exit 1; }
    gen_manifest "$1" ;;
  run)
    need kubectl; need jq
    [ $# -ge 1 ] || { echo "usage: $0 run <id...|all>"; exit 1; }
    [ -z "$NODE" ] && log "WARNING: NODE not set - pods may land on any worker. Set NODE=<test-node>."
    ids="$*"; [ "$1" = "all" ] && ids="$ALL_IDS"
    mkdir -p "$OUT_DIR"; : > "$OUT_DIR/summary.psv"; ensure_ns
    trap 'print_summary' EXIT
    for i in $ids; do run_one "$i"; done ;;
  cleanup)
    need kubectl
    kubectl delete ns "$NS" --wait=true ;;
  *)
    sed -n '2,32p' "$0" ;;
esac
