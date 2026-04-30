#!/usr/bin/env bash
# Thread-scaling sweep for CXL emulation.
#
# Runs every workload at multiple thread counts in the default split
# placement (half threads on NUMA 0, half on NUMA 1; memory on NUMA 0).
#
# Output: results/<tag>/summary.csv with one row per (workload, threads).

set -euo pipefail

THREAD_LIST="1 2 4 8 16 24 32"
WORKLOADS="a b c d e"
RUN_TAG="scaling_$(date +%Y%m%d_%H%M%S)"
NODES=1
COROS=0
KEYTYPE=randint
LOADER_NUM=1
EPOCH_TIMEOUT=600
HUGEPAGES=8192

while getopts "T:w:r:" opt; do
  case "$opt" in
    T) THREAD_LIST="$OPTARG" ;;
    w) WORKLOADS="$OPTARG" ;;
    r) RUN_TAG="$OPTARG" ;;
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
echo "workload,threads,coros,nodes,duration_s,total_ops,throughput_mops,p50_us,p95_us,p99_us,p999_us" > "$SUMMARY"

for T in $THREAD_LIST; do
  for WL in $WORKLOADS; do
    echo
    echo "=========================================================="
    echo "[run] threads=$T  workload=$WL  tag=$RUN_TAG"
    echo "=========================================================="

    python3 "$REPO_ROOT/ycsb/split_workload.py" "$WL" "$KEYTYPE" "$NODES" "$T" "$LOADER_NUM"

    rm -rf "$LAT_DIR"; mkdir -p "$LAT_DIR"

    LOG="$RESULTS_ROOT/cxl_${WL}_t${T}.log"
    LAT_OUT="$RESULTS_ROOT/cxl_${WL}_t${T}.lat"
    mkdir -p "$LAT_OUT"

    set +e
    CXL_PIN=split timeout "$EPOCH_TIMEOUT" stdbuf -oL -eL \
      numactl --membind=0 \
      ./ycsb_test "$NODES" "$T" "$COROS" "$KEYTYPE" "$WL" \
      2>&1 | tee "$LOG"
    RC=${PIPESTATUS[0]}
    set -e

    if compgen -G "$LAT_DIR/epoch_*.lat" >/dev/null; then
      cp "$LAT_DIR"/epoch_*.lat "$LAT_OUT/"
    fi

    python3 "$REPO_ROOT/scripts/parse_ycsb_log.py" \
        --log "$LOG" --lat-dir "$LAT_OUT" \
        --workload "$WL" --threads "$T" \
        --coros "$COROS" --nodes "$NODES" \
        >> "$SUMMARY"
  done
done

echo
echo "=========================================================="
echo "[done] $SUMMARY"
echo "=========================================================="
column -ts, "$SUMMARY"
