# CHIME RDMA -> CXL Emulation Porting Notes

This branch introduces a **CXL emulation mode** for CHIME on a single dual-socket machine, where remote memory is emulated by cross-socket accesses.

## What Changed

### 1) Build system (`CMakeLists.txt`)
- Added `CXL_EMULATION` CMake option (default `ON`).
- Added compile definition `-DCXL_EMULATION` when enabled.
- Removed `-libverbs` from default link flags so OFED link dependency does not block CXL builds.

### 2) One-sided transport path (`src/rdma/Operation.cpp`)
When `CXL_EMULATION` is enabled:
- `rdmaRead(...)` now performs `memcpy(local, remote, size)`.
- `rdmaWrite(...)` now performs `memcpy(remote, local, size)`.
- Batch read/write variants are converted to loops over local `memcpy`.
- CAS/F&A are replaced with local atomics:
  - `std::atomic<uint64_t>::compare_exchange_*`
  - `std::atomic<uint64_t>::fetch_add`
- Completion polling returns immediate success in emulation mode.

### 3) Memory node allocation (`src/DSM.cpp`)
- Replaced DSM memory backing:
  - from hugepage allocator
  - to `numa_alloc_onnode(size, 0)`
- Memory free path changed to `numa_free(...)`.
- This forces DSM memory residency on **NUMA node 0** for CXL emulation experiments.

### 4) NUMA worker placement (`test/ycsb_test.cpp`)
- Added `<numa.h>`.
- Added per-thread NUMA pinning at worker launch:
  - first half of threads -> node 0
  - second half of threads -> node 1
- This emulates local vs remote workers on a dual-socket host.

### 5) Allocator alignment (`include/DSM.h`) — CRITICAL CXL FIX
The CXL bump allocator now honors the `align_bit` argument. CHIME stores the
root pointer as a `PackedGAddr`, which shifts away the lower
`PACKED_ADDR_ALIGN_BIT=8` bits. With the previous 64-byte-only alignment, any
internal-root address allocated after the first split would silently lose its
lower 8 bits during the round-trip through `PackedGAddr`, so subsequent
`get_root_ptr` reads pointed at corrupted memory and the
`decode_node_versions` re-read loop spun indefinitely. The new allocator
aligns both the bump cursor and the allocation size to `1 << align_bit`,
making the round-trip identity for every node address.

## Build Instructions

```bash
cd ~/CHIME
mkdir -p build
cd build
cmake -DCXL_EMULATION=ON -DENABLE_CORO=OFF ..
make -j
```

## Run Instructions (CXL Emulation)

Run with memory strictly on node 0:

```bash
cd ~/CHIME/build
numactl --membind=0 ./ycsb_test 1 72 0 randint a
```

Notes:
- `1` node, `72` threads, `0` coroutines, randint key type, workload `a`.
- If machine has fewer physical/logical cores, reduce thread count accordingly.

## CloudLab Deployment Checklist

1. Provision dual-socket node (for example `d760-hbm` or `c6420`).
2. Install required deps:
   - compiler toolchain (`gcc/g++`, `cmake`, `make`)
   - `libnuma-dev`/`numactl`
   - CHIME dependencies (`cityhash`, `boost`, `memcached`, `tbb`)
3. Clone your patched CHIME branch onto the node.
4. Generate workloads and set `workloads.conf` path.
5. Build with `CXL_EMULATION=ON` and `ENABLE_CORO=OFF`.
6. Execute with `numactl --membind=0 ...` command above.
7. Save stdout logs + latency files (`us_lat`) for plotting and paper comparison.

## Suggested Experiment Metadata to Record

For each run, log:
- machine type, CPU model, socket/core/thread topology
- NUMA layout (`numactl --hardware`, `lscpu`)
- memory capacity/speed
- kernel + distro version
- workload (A/B/C/...), key distribution, key count
- thread count, coroutine count
- pinning policy (local/remote split)
- throughput and latency outputs

This metadata is required for a faithful comparison against original CHIME RDMA results.
