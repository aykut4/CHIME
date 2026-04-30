# Results — CXL-emulated CHIME on Xeon Gold 6142

All numbers below come from a single dual-socket CloudLab `c6420` host:

```
2 x Intel Xeon Gold 6142 @ 2.6 GHz  (16 cores/socket, HT on => 64 logical CPUs)
192 GB DDR4 per socket, 384 GB total
L1d 32 KB, L2 1024 KB, L3 22.5 MB shared per socket
NUMA distances:  local=10  remote=21
Ubuntu 18.04.1 LTS, kernel 4.15
```

DSM memory is bound to NUMA 0 via `numa_alloc_onnode(...)` + `numactl --membind=0`.
Workloads come from `ycsb/small_workload_spec/` (60 K records, Zipfian θ=0.99).
Build flags: `-DCXL_EMULATION=ON -DENABLE_CORO=OFF -DSHORT_TEST_EPOCH=ON`.
Run config: 32 application threads, 0 coroutines, 5 epochs × 200 ms each.

## Files

- [`baseline_t32_summary.csv`](baseline_t32_summary.csv)
  — `scripts/run_ycsb_suite.sh -t 32`, default `split` placement (16/16
  threads across the two sockets). This is "the emulated 2-node DM cluster".
- [`placement_t32_summary.csv`](placement_t32_summary.csv)
  — `scripts/run_numa_placement.sh -t 32`, the `local` / `split` / `remote`
  ablation. **This is the central CXL-emulation experiment** (see slide 12 of
  `PRESENTATION_OUTLINE.md`).

## Headline takeaways

1. Per-thread throughput is ~**2.2× higher** than the original CHIME paper's
   RDMA setup (0.27 vs 0.12 Mops/thr on YCSB-A) once the data path is
   CXL-shaped.
2. `local ≈ remote ≫ split` for point ops. Raw cross-socket DRAM latency is
   *not* the bottleneck on this hardware; **inter-socket cache-coherence
   traffic is.** The realistic emulated DM topology pays a ~24% throughput
   tax purely from cache-line ping-pong on hot leaves and lock words.
3. Workload E (scans) inverts the order: bandwidth-bound, so using two
   sockets' memory controllers (`split`) beats either single-socket
   configuration.
4. p50 latency (1.7–2.4 µs) and p99 latency (4.4–11.6 µs for point ops) are
   essentially placement-independent — the throughput delta is parallelism-
   side, not per-op-latency-side.

## Reproducing

```bash
# from the repo root, on a 2-socket CloudLab box with rdma-core, libnuma,
# libtbb-dev, libcityhash-dev, libboost-context-dev installed:
mkdir -p build && cd build
cmake -DCXL_EMULATION=ON -DENABLE_CORO=OFF -DSHORT_TEST_EPOCH=ON ..
make -j"$(nproc)" ycsb_test
cd ..

sudo bash scripts/run_ycsb_suite.sh      -t 32 -r baseline_t32
sudo bash scripts/run_numa_placement.sh  -t 32 -r placement_t32
sudo bash scripts/run_thread_scaling.sh  -T "1 2 4 8 16 24 32" -r scaling
```

Each script writes its own `results/<tag>/summary.csv`; the snapshots in
this directory are copies of those for the `baseline_t32` and
`placement_t32` runs reported in the writeup.
