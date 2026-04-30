# CHIME on CXL — Presentation Outline

This document is a slide-by-slide skeleton for the project talk: porting
CHIME (a B+ tree for disaggregated memory) from RDMA to a NUMA-emulated CXL
data path on a single dual-socket box, and the experiments that followed.

---

## 1. Title slide
- **Title:** *Porting CHIME from RDMA to CXL: lessons from re-targeting a B+ tree for disaggregated memory*
- **Subtitle:** Course / project name, your name + collaborators
- **One image:** the two-socket NUMA topology with the "compute side" / "memory side" labels overlaid on sockets 1 and 0 — sets the metaphor for the rest of the talk.

---

## 2. Background — Disaggregated memory (DM) in one slide
- "Memory disaggregation" = compute nodes (CN) reach memory living on remote memory nodes (MN) over a network fabric.
- Two fabric generations:
  - **RDMA-DM** (today): InfiniBand / RoCE, ~1–3 µs RTT one-sided ops.
  - **CXL-DM** (emerging): cache-coherent load/store at ~80–300 ns per access, no software round-trip.
- **Why this project matters:** every existing DM data structure was designed under RDMA assumptions (asymmetric latency, batching, coroutines). CXL flips those assumptions.

---

## 3. CHIME in 90 seconds
*Goal: show what CHIME contributes vs. prior DM trees.*
- **What:** a B+ tree built directly on disaggregated memory, no per-MN compute kernel.
- **Why hard on RDMA:** every read/write/CAS is a network op; the tree has to work with one-sided primitives only.
- **Key ideas (the four CHIME contributions):**
  1. **Hopscotch leaf nodes** — bounded entry displacement so a leaf read fits in 1–2 RDMA ops.
  2. **Vacancy-Aware Lock (VALOCK)** — the lock word piggybacks the leaf's vacancy bitmap and max-key index, so the next reader knows what subset of the leaf to fetch.
  3. **Metadata replication** — leaf metadata is sprinkled across cache lines so it survives torn reads.
  4. **Sibling-based validation + speculative read** — readers can validate from a sibling's split key without re-reading the parent.
- The combined effect is that CHIME hits ~31.5 Mops on YCSB-A across 8 MNs / 256 client threads — the SoTA DM B+ tree at the time of writing.

---

## 4. Why CHIME vs. Sherman / SMART / DEFT / ROLEX?
*One slide of quick comparison so the audience knows where CHIME sits.*

| System | Year | Index | Key trick | Primary cost it attacks |
|---|---|---|---|---|
| **Sherman** | SOSP'22 | B+ tree | combine + selective read amplification | RDMA RTT |
| **SMART** | OSDI'23 | radix tree | path-compressed key fingerprints | RDMA + RPC overhead |
| **ROLEX** | EuroSys'23 | learned index | *learned* node placement on MN | tail latency from imbalanced load |
| **DEFT** | ATC'24 | B+ tree | decentralized fault tolerance for DM trees | replication cost on RDMA |
| **CHIME** | SIGMOD'24 | B+ tree | hopscotch + VALOCK + metadata replication | per-leaf RDMA op count |

> Position CHIME: same workload class as Sherman/DEFT, *richer leaf encoding* so it does fewer round-trips per op. Exactly the dimension that should evaporate under CXL.

---

## 5. The research question for this project
> **If we drop the RDMA-shaped data path and replace it with CXL-shaped load/store accesses, what stays useful in CHIME, what becomes redundant, and how do the numbers change?**

This is what every DM data structure paper will have to answer eventually; we run the experiment for one of them.

---

## 6. CXL emulation methodology
*Show the picture, then justify.*
- One **two-socket Intel Xeon Gold 6142** server (CloudLab `c6420` / `r650` profile).
- Treat **NUMA node 0 as the "memory node"** (host all DSM-allocated bytes there) and use threads on node 1 to act as "remote compute".
- "Network" = the **UPI bus** between sockets. CXL.mem's protocol is different but its *latency class* (~120 ns local, ~250 ns one-hop) is well approximated by NUMA-1 → NUMA-0 accesses.
- We **do not** emulate CXL bandwidth limits or device buffering — just latency and access asymmetry.
- The host:
  ```
  Intel Xeon Gold 6142 @ 2.6 GHz, 16 cores × 2 sockets, HT on (64 logical)
  192 GB DRAM per socket (384 GB total)
  L1d 32 KB, L2 1024 KB, L3 22 MB shared per socket
  Inter-socket distance: 21 (vs 10 local) per `numactl --hardware`
  Ubuntu 18.04.1, kernel 4.15
  ```

---

## 7. Porting journey — what we changed (the "lobotomy")
*One slide listing the structural edits, with file references.*

| Change | File | Rationale |
|---|---|---|
| Add `CXL_EMULATION` build option | `CMakeLists.txt` | Compile-time switch for the new data path |
| Replace `rdmaRead/Write` with `memcpy` | `src/rdma/Operation.cpp` | One-sided ops collapse to load/store |
| Replace RDMA CAS / FAA with `__atomic_*` builtins | `src/rdma/Operation.cpp` | UPI is cache-coherent, GCC atomics are correct & cheap |
| Stub `pollWithCQ`, `pollOnce` | `src/rdma/Operation.cpp` | No HCA, no completion queue |
| Fence-off all `ibv_exp_*` symbols | `src/rdma/{Resource,StateTrans,Utility}.cpp` | Modern `rdma-core` doesn't ship the experimental Mellanox ABI |
| `numa_alloc_onnode(size, 0)` for DSM base | `src/DSM.cpp` | Force memory residency on node 0 |
| Bypass DSM-keeper / memcached barrier | `src/DSM.cpp`, `include/DSM.h` | No control plane in single-host emulation |
| **Honor `align_bit` in CXL bump allocator** | `include/DSM.h` | Critical: `RootEntry` packs the root pointer as a `PackedGAddr` (lower 8 bits shifted off), so a 64-byte-aligned address gets corrupted on round-trip — this is what bit us hardest |
| Per-thread NUMA pinning via `CXL_PIN` env var | `test/ycsb_test.cpp` | local / remote / split topologies without rebuilding |
| Throughput aggregation with `kCoroCnt = 0` | `test/ycsb_test.cpp` | Pre-existing bug exposed by no-coro CXL config |

---

## 8. The bug that took the most time (worth a slide on its own)
- Symptom: loader hung after exactly one root split (`[INFO] new root level 2`); 32 threads idle for 180 s.
- Root cause: `RootEntry { uint16_t level; PackedGAddr ptr; }`. `PackedGAddr` constructor is `offset >> PACKED_ADDR_ALIGN_BIT` (= 8). Our first CXL bump allocator only aligned to 64 bytes, so the second-ever node-aligned alloc dropped 8 bits when the new root pointer round-tripped through the packed type. `get_root_ptr()` then read garbage; `decode_node_versions()` failed; `goto re_read;` looped forever.
- Lesson: **DM systems quietly trade off pointer width for alignment**. If you replace the allocator, replicate every alignment guarantee the original made.

---

## 9. What was *easy* / *hard* / *can't be ported*
- **Easy:** the data path itself — every one-sided RDMA call has an obvious `memcpy` / `__atomic_*` analogue once you accept the "no completion queue" simplification.
- **Hard:**
  - Stripping the experimental Mellanox API surface that CHIME used.
  - Reproducing CHIME's allocator alignment invariants (the bug above).
  - Convincing 32 threads to make forward progress without contention during loading; ended up using a single dedicated loader (`LOADER_NUM=1`) for cleanliness.
- **Out of scope / can't faithfully emulate without more hardware:**
  - True CXL.mem bandwidth and queuing behavior (use a Sapphire Rapids + EMR CXL device for that).
  - Failure-domain semantics (CXL is cache-coherent, RDMA is not — this changes consistency budgets).
  - Multi-host fabric effects (this project is single-host).

---

## 10. Experimental setup (one slide)
- Hardware: Intel Xeon Gold 6142 ×2, 384 GB total DRAM, UPI fabric.
- Software: Ubuntu 18.04.1 (4.15 kernel), GCC 9, CMake 3.10, `numactl`, `numa-tools`, hugetlbfs (8192 × 2 MiB pages reserved).
- DSM bound to NUMA 0 via `numa_alloc_onnode` + `numactl --membind=0`.
- 32 worker threads, 16 on each NUMA node (`split` placement) unless noted.
- Workloads: YCSB A/B/C/D/E with 60 K records / 60 K ops (small spec from CHIME repo, Zipfian θ=0.99 except D).
- 5 epochs × 200 ms benchmark window per run (`SHORT_TEST_EPOCH=ON`); first epoch dropped as warmup when computing latency percentiles.

---

## 11. Results — baseline CXL emulation (split placement, 32 threads)

This is the default emulated 2-node DM cluster: **memory bound to NUMA 0**, threads pinned 16/16 across sockets, every "remote" op crossing UPI.

| Workload | Mix | Throughput (Mops) | p50 (µs) | p95 (µs) | p99 (µs) | p99.9 (µs) |
|---|---|---:|---:|---:|---:|---:|
| A | 50/50 R/U | **8.69** | 2.00 | 3.60 | 5.10 | 45.00 |
| B | 95/5 R/U | **8.34** | 2.00 | 4.00 | 5.90 | 42.00 |
| C | 100% R | **8.26** | 1.90 | 7.80 | 11.60 | 40.20 |
| D | 95/5 R/Insert(latest) | **9.11** | 1.70 | 3.20 | 4.80 | 44.60 |
| E | 95/5 Scan/Insert | **1.69** | 3.70 | 90.40 | 116.00 | 150.80 |

**Talking points for this slide:**
- Point ops (A/B/C/D) all sit ~8.3–9.1 Mops because each is essentially one cache-line-sized load + one CAS in CXL — ~120 ns hot, ~4 µs throughput-per-op at saturation.
- Workload C (read-only) has the worst point-op p99 (11.6 µs) — counter-intuitive, but reads exercise the speculative-read + index-cache paths the most aggressively, so the misses are concentrated.
- Workload E collapses to ~20% of point-op throughput: each scan visits multiple leaves and is bandwidth-bound, not latency-bound.
- Per-thread efficiency: 8.7 Mops / 32 threads ≈ **0.27 Mops/thr**, vs ~0.12 Mops/thr in the original CHIME paper running over RDMA on 8 MNs / 256 threads.

---

## 12. Results — NUMA placement ablation (the central slide)

*Bar chart: x = workload, y = Mops, three bars per group:* `local` / `split` / `remote`. Memory always pinned to NUMA 0; only thread placement changes.

| placement | how to read it | A | B | C | D | E |
|---|---|---:|---:|---:|---:|---:|
| `local`  (32 threads on NUMA 0) | "all data is local" upper bound | **11.01** | **11.70** | **10.86** | **11.32** | 1.60 |
| `split`  (16 + 16 across sockets) | emulated 2-node DM cluster | 8.69 | 8.34 | 8.26 | 9.11 | **1.69** |
| `remote` (32 threads on NUMA 1) | "every op crosses UPI" upper bound | 11.08 | 11.70 | 10.85 | 11.70 | 1.58 |

p50 latency is essentially identical across placements (1.7–2.4 µs); p99 is also nearly invariant for point ops (4.4–11.6 µs). The throughput delta is parallelism-side, not per-op latency.

### The unexpected finding — and the headline of the talk

> *On this hardware, raw NUMA-remote DRAM latency is **not** the bottleneck for CHIME at YCSB scale. **Inter-socket cache-coherence traffic is.***

- `local` and `remote` give **identical** point-op throughput (~11 Mops). Once a hot cache line lives in the executing socket's L3, every subsequent access is local — regardless of whether the *home* DRAM is across UPI or not.
- `split` is *slower* than either extreme (~8.5 Mops, ~24% lower) because the same hot lines (root pointer, level-1 internal nodes, leaf locks) get modified from threads on **both** sockets. Cache-coherence ping-pong via UPI dominates the cost, and that cost only happens in the cross-socket configuration.
- The exception is **workload E**: scans are bandwidth-bound, mostly read-only, and benefit from using *both* memory controllers and *both* L3 caches in parallel — so `split (1.69)` *beats* both `local (1.60)` and `remote (1.58)`.

### Implication for CXL.mem

CXL.mem is going to look much more like the cross-socket case than the all-local one because compute hosts share the same CXL-attached memory and modify it concurrently. **The dominant cost will not be the device's load-store latency — it will be the cache-coherence protocol** that keeps multiple compute hosts' caches in sync over CXL.cache / CXL.io. CHIME's contributions (hopscotch, VALOCK, metadata replication) shrink the *number of remote ops*, but they do not reduce the *coherence traffic* introduced by sharing — that's what a CXL-aware redesign would have to attack.

---

## 13. Results — thread scaling *(needs the new run)*
*Two panels:*
- Throughput Mops vs. threads ∈ {1, 2, 4, 8, 16, 24, 32} for each workload (lines).
- p99 latency vs. threads (same x-axis).

Expected: linear scaling up to 16 (one socket worth of physical cores), super-linear flattening at 24, and either continued growth or contention plateau at 32 depending on workload.

---

## 14. Results — comparison to the CHIME paper
*Apples-to-oranges, but informative.*

| Setting | Hardware | Threads | YCSB-A Mops | per-thread |
|---|---|---:|---:|---:|
| CHIME paper (RDMA, 8 MNs) | 8× MN + 8× CN, 200 GbE RDMA | 256 client threads | 31.5 | 0.123 Mops/thr |
| **CXL-emulated `split` (this project)** | 1× dual-socket Xeon Gold 6142 | 32 threads | **8.69** | **0.272 Mops/thr** |
| **CXL-emulated `local` upper bound** | 1× socket NUMA 0 only | 32 threads (HT) | **11.01** | **0.344 Mops/thr** |

**Talking points:**
- Per-thread, the CXL-emulated 2-node cluster is ~**2.2×** more efficient than the published 8-node RDMA cluster. The "ideal CXL" upper bound (no cross-socket traffic) is **2.8×**.
- This factor is consistent with replacing a ~2 µs RDMA RTT with a few-hundred-ns CXL/UPI hop *when caches are hot*.
- It is *not* a 20× speedup, because at this scale the workload was never network-bound to begin with — it was *contention*-bound, and contention exists in both fabrics.
- This makes CHIME a strong concrete data point on the line "what does CHIME look like under CXL" — and shows that the headline number we should track post-port is *coherence traffic*, not raw RTT.

---

## 15. Discussion — what changes about CHIME under CXL?
*One slide of takeaways, now backed by the placement experiment:*

1. **The four CHIME tricks pay off less.** Hopscotch leaves / VALOCK / metadata replication / speculative read all *amortize a network round-trip*. With UPI/CXL one-hop latency 20–100× lower than RDMA RTT, they shrink to micro-optimizations rather than first-order wins.
2. **The bottleneck shifts from network latency → cache-coherence traffic.** Our placement ablation (slide 12) shows `local ≈ remote ≪ split` — the ~24% throughput loss in the split (i.e. realistic) topology is *coherence ping-pong on hot lines*, not raw remote-DRAM latency. CXL-aware DM trees will need to attack *write-side sharing*, e.g. with delegation, sharded locks, or per-host hot copies.
3. **Coroutines stop helping.** `kCoroCnt=8` exists to hide RDMA latency. With CXL there's not enough latency to hide, and the no-coro path is competitive — our entire run uses `kCoroCnt=0`.
4. **The index cache becomes more about *capacity* than *latency*.** With cheap remote access, you stop caching to avoid round-trips and start caching only what fits in L3 (since remote-DRAM ≈ local-DRAM). The cache-hit rate (99.84%) was high simply because the entire 60 K-key working set fit in L3.
5. **Allocator/alignment invariants become subtle.** CXL-class "memory" is still indexed by full host VA, but DM systems pack pointers (e.g. CHIME's `PackedGAddr`). A re-targeted allocator must keep every alignment promise the original made — we hit this exact bug and it cost us a day.
6. **Bandwidth wins, sometimes.** Workload E (scans) is the only configuration where `split` beats `local` and `remote` (slide 12). Once you're bandwidth-bound, using *more* memory controllers helps, even if it costs coherence — a useful design dial for read-heavy scan workloads.

---

## 16. Threats to validity / limitations
- UPI ≠ CXL; we model latency only, not bandwidth or device buffering.
- One host means we cannot demonstrate multi-CN coherence at scale.
- 60 K records is small; cache hit rate (~99.8%) inflates throughput vs. a real OLTP workload.
- CHIME's full feature set (var-len KV, full SMART comparison, range scans with greedy IO) was not exercised; we run with the default knobs.
- We did not enable Linux's "memory tier" support or real CXL devices; this is purely an emulation.

---

## 17. Future work / next steps
- Re-run on Sapphire Rapids + an Astera Labs or Samsung CMM-D CXL.mem device.
- Repeat the same "lobotomy" exercise on Sherman, ROLEX, and DEFT — does each system's headline trick hold up under CXL latency? Build a single ablation table.
- Add real CXL bandwidth modeling (use `cxl-cli` / `cxl-stress` / `intel-pcm`) to bound throughput, not just latency.
- Measure failure-domain semantics — CXL.mem is coherent; the "torn read" patterns CHIME guards against are a strict subset of what RDMA had to handle.
- Open-source the porting harness as a recipe for "how to take any DM system and CXL-ify it".

---

## 18. Q&A / backup slides

Backup materials worth keeping in the deck:
- The bug deep-dive (slide 8) expanded with a code diff.
- A NUMA topology diagram with measured `lat_mem_rd` numbers.
- Full `summary.csv` from each run.
- The `CXL_PORTING_NOTES.md` checklist as an appendix slide.

---

## Run order to produce every chart in this deck

```bash
cd ~/CHIME && git pull --ff-only origin cxl-pure-fastpath

# rebuild once with all CHIME features ON (default config)
rm -rf build && mkdir build && cd build
cmake -DCXL_EMULATION=ON -DENABLE_CORO=OFF -DSHORT_TEST_EPOCH=ON ..
make -j$(nproc) ycsb_test
cd ..

# slide 11 -- baseline single-host CXL emulation, A..E at 32 threads
sudo bash scripts/run_ycsb_suite.sh -t 32 -r baseline_t32

# slide 12 -- local / split / remote NUMA-placement ablation
sudo bash scripts/run_numa_placement.sh -t 32 -r placement_t32

# slide 13 -- thread scaling sweep
sudo bash scripts/run_thread_scaling.sh -T "1 2 4 8 16 24 32" -r scaling

# (optional) slide 15.4 -- cache ablation
rm -rf build_nocache && mkdir build_nocache && cd build_nocache
cmake -DCXL_EMULATION=ON -DENABLE_CORO=OFF -DSHORT_TEST_EPOCH=ON \
      -DENABLE_CACHE=OFF -DSPECULATIVE_READ=OFF ..
make -j$(nproc) ycsb_test
cd .. && sudo bash scripts/run_ycsb_suite.sh -t 32 -r baseline_t32_nocache

# (optional) larger working set
python3 ycsb/gen_workload.py workloada randint full   # if not already generated
sudo bash scripts/run_ycsb_suite.sh -t 32 -r baseline_t32_full
```

Every script writes a `summary.csv`; concatenate them and you have all the
data points you need for slides 11, 12, 13, and 15.
