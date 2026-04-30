#!/usr/bin/env bash
# Local / remote / split placement comparison.
#
# Memory is always pinned to NUMA 0 (the "memory node" in the emulated DM
# cluster). The CXL_PIN env var changes where the *threads* run:
#
#   local   -- threads on node 0 too: pure local DRAM, no UPI hops
#             (lower-bound for the CXL emulation).
#   remote  -- threads on node 1: every memory op crosses UPI
#             (upper-bound = a "100% CXL" workload).
#   split   -- 16/16 threads, the default emulated 2-node DM topology.
#
# Run from the repo root:  sudo bash scripts/run_numa_placement.sh
#
# Knobs:
#   -t THREADS    threads (default 32)
#   -w "a c"      workloads (default a b c d e)
#   -r TAG        run tag (default placement_<timestamp>)

set -euo pipefail

THREADS=32
WORKLOADS="a b c d e"
RUN_TAG="placement_$(date +%Y%m%d_%H%M%S)"
NODES=1
COROS=0
KEYTYPE=randint
LOADER_NUM=1
EPOCH_TIMEOUT=600
HUGEPAGES=8192

while getopts "t:w:r:T:" opt; do
  case "$opt" in
    t) THREADS="$OPTARG" ;;
    w) WORKLOADS="$OPTARG" ;;
    r) RUN_TAG="$OPTARG" ;;
    T) EPOCH_TIMEOUT="$OPTARG" ;;
    *) echo "unknown option"; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
RESULTS_ROOT="$REPO_ROOT/results/$RUN_TAG"
LAT_DIR="$BUILD_DIR/../us_lat"

mkdir -p "$RESULTS_ROOT"
cd "$BUILD_DIR"

echo "$HUGEPAGES" | sudo tee /proc/sys/vm/nr_hugepages >/dev/null || true
ulimit -l unlimited || true

SUMMARY="$RESULTS_ROOT/summary.csv"
echo "placement,workload,threads,coros,nodes,duration_s,total_ops,throughput_mops,p50_us,p95_us,p99_us,p999_us" > "$SUMMARY"

for PLACEMENT in local split remote; do
  for WL in $WORKLOADS; do
    echo
    echo "=========================================================="
    echo "[run] placement=$PLACEMENT  workload=$WL  threads=$THREADS"
    echo "=========================================================="

    python3 "$REPO_ROOT/ycsb/split_workload.py" "$WL" "$KEYTYPE" "$NODES" "$THREADS" "$LOADER_NUM"

    rm -rf "$LAT_DIR"
    mkdir -p "$LAT_DIR"

    LOG="$RESULTS_ROOT/cxl_${PLACEMENT}_${WL}_t${THREADS}.log"
    LAT_OUT="$RESULTS_ROOT/cxl_${PLACEMENT}_${WL}_t${THREADS}.lat"
    mkdir -p "$LAT_OUT"

    # snapshot numastat before/after
    numastat -m 2>/dev/null > "${LOG}.numastat.before" || true

    set +e
    CXL_PIN="$PLACEMENT" timeout "$EPOCH_TIMEOUT" stdbuf -oL -eL \
      numactl --membind=0 \
      ./ycsb_test "$NODES" "$THREADS" "$COROS" "$KEYTYPE" "$WL" \
      2>&1 | tee "$LOG"
    RC=${PIPESTATUS[0]}
    set -e

    numastat -m 2>/dev/null > "${LOG}.numastat.after" || true

    if [[ "$RC" -ne 0 ]]; then
      echo "[warn] placement=$PLACEMENT wl=$WL rc=$RC (continuing)"
    fi

    if compgen -G "$LAT_DIR/epoch_*.lat" >/dev/null; then
      cp "$LAT_DIR"/epoch_*.lat "$LAT_OUT/"
    fi

    PARSED=$(python3 "$REPO_ROOT/scripts/parse_ycsb_log.py" \
                --log "$LOG" --lat-dir "$LAT_OUT" \
                --workload "$WL" --threads "$THREADS" \
                --coros "$COROS" --nodes "$NODES")
    echo "${PLACEMENT},${PARSED}" >> "$SUMMARY"
  done
done

echo
echo "=========================================================="
echo "[done] $SUMMARY"
echo "=========================================================="
column -ts, "$SUMMARY"
