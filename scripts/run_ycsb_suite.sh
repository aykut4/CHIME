#!/usr/bin/env bash
# CXL-emulation YCSB suite runner for CHIME.
#
# Runs YCSB workloads A,B,C,D,E end-to-end and produces:
#   - results/<run_tag>/cxl_<wl>_t<threads>.log         (raw stdout)
#   - results/<run_tag>/cxl_<wl>_t<threads>.lat/        (per-epoch *.lat)
#   - results/<run_tag>/summary.csv                     (throughput + latency)
#
# Assumes the binary already built into <repo>/build/ycsb_test.
#
# Usage:
#   scripts/run_ycsb_suite.sh [-t THREADS] [-w "a b c d e"] [-r RUN_TAG]
#
# Example:
#   sudo bash scripts/run_ycsb_suite.sh -t 32 -w "a b c"

set -euo pipefail

# ---------- defaults ----------
THREADS=32
WORKLOADS="a b c d e"
RUN_TAG="$(date +%Y%m%d_%H%M%S)"
NODES=1
COROS=0
KEYTYPE=randint
LOADER_NUM=1
EPOCH_TIMEOUT=600        # seconds per workload run
HUGEPAGES=8192

while getopts "t:w:r:T:" opt; do
  case "$opt" in
    t) THREADS="$OPTARG" ;;
    w) WORKLOADS="$OPTARG" ;;
    r) RUN_TAG="$OPTARG" ;;
    T) EPOCH_TIMEOUT="$OPTARG" ;;
    *) echo "unknown option: $opt"; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
RESULTS_ROOT="$REPO_ROOT/results/$RUN_TAG"
LAT_DIR="$BUILD_DIR/../us_lat"

if [[ ! -x "$BUILD_DIR/ycsb_test" ]]; then
  echo "[error] $BUILD_DIR/ycsb_test not found. Build first with:"
  echo "        cmake -DCXL_EMULATION=ON -DENABLE_CORO=OFF -DSHORT_TEST_EPOCH=ON .."
  exit 1
fi

mkdir -p "$RESULTS_ROOT"
cd "$BUILD_DIR"

# ---------- one-time host setup ----------
echo "[setup] reserving $HUGEPAGES huge pages and unlocking memlock"
if [[ "$EUID" -ne 0 ]]; then
  echo "[setup] not root: 'sudo' required for hugepages/ulimit; continuing best-effort"
fi
echo "$HUGEPAGES" | sudo tee /proc/sys/vm/nr_hugepages >/dev/null || true
ulimit -l unlimited || true

# ---------- run loop ----------
SUMMARY_CSV="$RESULTS_ROOT/summary.csv"
echo "workload,threads,coros,nodes,duration_s,total_ops,throughput_mops,p50_us,p95_us,p99_us,p999_us" > "$SUMMARY_CSV"

for WL in $WORKLOADS; do
  echo
  echo "=========================================================="
  echo "[run] workload=$WL  threads=$THREADS  coros=$COROS  tag=$RUN_TAG"
  echo "=========================================================="

  # 1) regenerate per-thread splits for this workload + thread count.
  echo "[split] python3 ycsb/split_workload.py $WL $KEYTYPE $NODES $THREADS $LOADER_NUM"
  python3 "$REPO_ROOT/ycsb/split_workload.py" "$WL" "$KEYTYPE" "$NODES" "$THREADS" "$LOADER_NUM"

  # 2) clear previous latency dir
  rm -rf "$LAT_DIR"
  mkdir -p "$LAT_DIR"

  LOG="$RESULTS_ROOT/cxl_${WL}_t${THREADS}.log"
  LAT_OUT="$RESULTS_ROOT/cxl_${WL}_t${THREADS}.lat"
  mkdir -p "$LAT_OUT"

  # 3) run the benchmark
  set +e
  timeout "$EPOCH_TIMEOUT" stdbuf -oL -eL \
    numactl --membind=0 \
    ./ycsb_test "$NODES" "$THREADS" "$COROS" "$KEYTYPE" "$WL" \
    2>&1 | tee "$LOG"
  RC=${PIPESTATUS[0]}
  set -e

  if [[ "$RC" -ne 0 ]]; then
    echo "[warn] workload=$WL exited with code=$RC (continuing)"
  fi

  # 4) collect per-epoch latency files
  if compgen -G "$LAT_DIR/epoch_*.lat" >/dev/null; then
    cp "$LAT_DIR"/epoch_*.lat "$LAT_OUT/"
  fi

  # 5) parse summary stats from the log
  python3 "$REPO_ROOT/scripts/parse_ycsb_log.py" \
      --log "$LOG" \
      --lat-dir "$LAT_OUT" \
      --workload "$WL" \
      --threads "$THREADS" \
      --coros "$COROS" \
      --nodes "$NODES" \
      >> "$SUMMARY_CSV"

done

echo
echo "=========================================================="
echo "[done] summary => $SUMMARY_CSV"
echo "=========================================================="
column -ts, "$SUMMARY_CSV"
