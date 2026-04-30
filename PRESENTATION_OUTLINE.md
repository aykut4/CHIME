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

## 11. Results — single-host CXL emulation (your existing table)
| Workload | Mix | Throughput (Mops) | p50 (µs) | p95 (µs) | p99 (µs) | p99.9 (µs) |
|---|---|---:|---:|---:|---:|---:|
| A | 50/50 R/U | **8.31** | 1.90 | 3.40 | 4.90 | 46.20 |
| B | 95/5 R/U | **8.67** | 1.90 | 3.90 | 6.10 | 45.70 |
| C | 100% R | **8.42** | 1.90 | 7.90 | 11.50 | 43.10 |
| D | 95/5 R/Insert(latest) | **8.56** | 1.90 | 3.20 | 4.40 | 48.60 |
| E | 95/5 Scan/Insert | **1.81** | 3.50 | 85.40 | 131.10 | 172.50 |

**Talking points for this slide:**
- Point ops (A/B/C/D) all sit ~8.3 Mops because each is single round-trip-ish in CXL ≈ ~120 ns hot, 4 µs throughput-per-op at saturation.
- Workload C (read-only) has the worst p99 of the point ops — unintuitive, but it's because reads exercise speculative-read + index-cache paths the most aggressively, so cache misses hurt.
- Workload E collapses to ~22% of the point-op throughput because each scan visits multiple leaves (range query). p99 jumps an order of magnitude.

---

## 12. Results — NUMA placement ablation *(needs the new run)*
*Bar chart: x=workload, y=Mops, three bars per group: local / split / remote.*

Expected story (fill in with real numbers from `scripts/run_numa_placement.sh`):
- **`local`** (every thread on NUMA 0) ≈ upper bound. No UPI hops.
- **`remote`** (every thread on NUMA 1) ≈ lower bound. Every memory op crosses UPI.
- **`split`** ≈ what a 2-node DM cluster would feel, halfway between the two.

Quantify: `(local - remote) / local` is the **CXL-hop tax** in your emulation. That number is the headline of this slide.

Optional second chart: `numastat -m` snapshot showing NUMA 1 → NUMA 0 traffic increases monotonically from `local → split → remote`.

---

## 13. Results — thread scaling *(needs the new run)*
*Two panels:*
- Throughput Mops vs. threads ∈ {1, 2, 4, 8, 16, 24, 32} for each workload (lines).
- p99 latency vs. threads (same x-axis).

Expected: linear scaling up to 16 (one socket worth of physical cores), super-linear flattening at 24, and either continued growth or contention plateau at 32 depending on workload.

---

## 14. Results — comparison to the CHIME paper
*Apples-to-oranges, but informative.*

| Setting | Hardware | Threads | YCSB-A Mops |
|---|---|---:|---:|
| CHIME paper (RDMA, 8 MNs) | 8× MN + 8× CN, 200 GbE RDMA | 256 client threads | 31.5 |
| **This project (CXL-emulated, 1 host)** | 1× dual-socket Xeon Gold 6142 | 32 threads | **8.3** |
| **per-thread** | — | — | RDMA: 0.12 Mops/thr · CXL-emu: **0.26 Mops/thr** |

Talking point: per-thread, CXL-emulation is ~2× more efficient. With more sockets / threads we'd expect the absolute number to scale near-linearly because each "memory op" is now a DRAM access, not a network round-trip — i.e. throughput is capped by cache-line bandwidth, not HCA queue depth.

This is precisely the prediction CXL-DM enthusiasts make. Your project is one of the first concrete empirical points on the "what does CHIME look like under CXL" line.

---

## 15. Discussion — what changes about CHIME under CXL?
*One slide of takeaways:*
1. **The four CHIME tricks pay off less.** Hopscotch / VALOCK / metadata replication / speculative read are amortizations of network latency. With UPI/CXL latency being 20–100× lower, they shrink to micro-optimizations rather than first-order wins.
2. **The bottleneck shifts from network to lock contention.** With per-op latency below 200 ns, even short critical sections matter; the lock-CAS retry rate becomes the relevant metric.
3. **Coroutines stop helping.** `kCoroCnt=8` exists to hide RDMA latency. With CXL there's not enough latency to hide; the no-coro path is competitive.
4. **The index cache becomes more about *capacity* than *latency*.** With cheap remote access, you stop caching to avoid round-trips and start caching only what fits in L3 (since DRAM ≈ remote-DRAM).
5. **Allocator/alignment invariants become subtle.** CXL-class "memory" is still indexed by full host VA, but DM systems often pack pointers — your bump allocator must keep every alignment promise the original made.

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
