# Team notes: optimization log

Draft material for the README section the rules ask for. Numbers so far were
measured off-cluster (2-CPU Intel Sapphire Rapids VM, same CPU generation as
frnt201's Xeon Gold 6430). **Re-measure everything on frnt201 before quoting it.**

## Results so far (off-cluster, 2 CPUs, `scripts/score.sh <demo> 30 1`)

| Build | demo1 | demo2 | demo3 |
|---|---|---|---|
| Original kit (`-Os`, restart per demo) | 8 | 8 | 9 |
| This branch (defaults) | 36 | 37 | 34 |

All runs: 0 invalid demos. Single demo1 playback: 5.6 s → ~1.45 s.

## What changed and why

| # | Change | Files | Effect (demo1, 1 copy) |
|---|---|---|---|
| 1 | Screen-melt transition no longer sleeps on the wall clock. Every melt step is still drawn; all of them belong to one game tic, so only the final frame is fingerprinted, as in the original. | `d_main.c` | 5.6 s → 4.5 s (≈1.1 s of each demo was `usleep`) |
| 2 | Frame-buffer conversion rewritten. gprof showed `cmap_to_fb` at 70% of CPU: a per-pixel branch on bits-per-pixel and reloads of `s_Fb` on every store (char-pointer aliasing). Now: 32-bit palette built once per palette change, each pixel written as a 64-bit pair, finished row copied to the row below. Output is bit-identical; the full 640×400 image is still written every frame. | `i_video.c` | 3.6 s → 1.7 s (at `-O2`) |
| 3 | `-Os` → `-O3 -march=native` (`OPT=` overrides it). | `Makefile` | ~5–10%, within noise off-cluster |
| 4 | 2 MB-aligned frame buffer and zone memory with `MADV_HUGEPAGE` (fewer TLB misses on the 1 MB buffer rewritten every frame). | `doomgeneric.c`, `i_system.c` | not measurable off-cluster; harmless |
| 5 | Game data loaded once per copy. `-demofork` (default): load, then fork a fresh child per demo, so each child starts from untouched pre-demo state and its frames are bit-identical to a fresh process. `-demoloop`: replay inside one process (resets tic counters, D_Display state, status-bar face state and the spectre fuzz position). | `d_main.c`, `d_loop.[ch]`, `g_game.c`, `st_stuff.[ch]` | ~2% off-cluster (start-up is ~15–25 ms); likely more on the cluster's shared filesystem |
| 6 | `run.sh`: one copy per allowed CPU, physical cores first then hyperthread siblings, each pinned with `taskset`. `COPIES`, `MODE`, `PIN` knobs for tuning. | `scripts/run.sh` | to measure on frnt201 |

### Validity notes
- `-demofork`: matched = 7115 / 7088 / 6041 on every run (same as a fresh process).
- `-demoloop`: valid, but repeats lose 1–3 frames (demo1 7113–7115, demo2 7087,
  demo3 6040). That's vanilla Doom reading a byte or two past a graphic, which
  depends on leftover heap memory. It's inside the 5-frame allowance but uses
  some of it, which is why fork is the default.

## frnt201 results (2026-11-09, 16 CPUs = 8 cores x 2 threads, `score.sh <demo> 30 1`)

Raw output: `benchmarks/frnt201-2026-11-09.txt`. Every run 0 invalid.

| Demo | Stock (3 runs) | Optimized (3 runs) | Median | Speedup |
|---|---|---|---|---|
| demo1 | 64, 64, 64 | 214, 220, 224 | 220 | 3.4x |
| demo2 | 64, 64, 64 | 233, 235, 231 | 233 | 3.6x |
| demo3 | 64, 64, 65 | 217, 215, 215 | 215 | 3.4x |

Run-to-run spread: about +/-2%. (That build predates the `restrict` change below.)

### Projecting to the full node (120 s, 128 CPUs)
Scaling the 30 s score by 32 slightly undercounts, because each copy loses
about half a demo when the timer stops, and that loss is the same in a 30 s
and a 120 s run. Per copy:

    t      = seconds per demo = 30 / (score/16 + 0.5)
    score  = 128 x (120 / t - 0.5)

demo1: t = 2.10 s -> about 7,230. demo2: t = 1.99 s -> about 7,640.
demo3: t = 2.15 s -> about 7,080. Stock: about 2,100.

This assumes each core stays as fast with all 64 cores busy as it was with 8.
It won't fully hold: all-core turbo is lower, and 128 copies share two 60 MB L3
caches and memory bandwidth across two sockets. The `copies` sweep measures
per-copy speed at 1-16 copies; if it drops as copies rise, extend that trend
to 128 instead of assuming it stays flat. Only a full-node run gives the real
number.

## Round 2 experiments (off-cluster, CPU time, best of 5, all valid)

| Change | Result | Kept? |
|---|---|---|
| `restrict` locals in `R_DrawColumn` / `R_DrawSpan`: the byte store forced `dc_source`/`dc_colormap` (and `ds_*`) to be reloaded every pixel; now kept in registers (checked in the disassembly) | about 2% faster on all three demos | yes |
| AVX-512 frame conversion (gather + permutes, store both rows) | same on demo1, 7% slower on demo3 | no |
| Scalar conversion writing both rows directly (no memcpy) | 5% slower | no |
| Convert a row into an L1 buffer, then memcpy to both rows | 3-10% slower | no |
| PGO (trained on demo1-3) | 3-5% faster on demo2/3, mixed on demo1 | not by default: needs committed profile data or a training run in `make`; ask organizers whether that counts as precomputing (rule 3) |

Current profile (all demos): R_DrawColumn 22%, frame conversion 14%,
R_DrawSpan 9%, R_RenderSegLoop 8%, R_DrawSprite 5%, DG_DrawFrame (validator,
fixed) 4%.

## Round 3 (2026-11-11, off-cluster; frnt201 numbers still to be measured)

Measured on a 2-CPU Intel Emerald Rapids VM (the generation after frnt201's
Sapphire Rapids: same core design, 2 MB L2, AVX-512) with gcc 12.4 and
`-march=sapphirerapids`, which is what `-march=native` means on frnt201.
Timing there is noisy (about +/-1.5%), so each figure is the median of 9
interleaved runs of the per-tic frame time.

**Result: the frame loop needs about 8-10% fewer CPU cycles per demo than
round 2** (demo1 -9%, demo2 -7%, demo3 -9%), one copy on an otherwise idle
core. Start-up is no longer worth chasing: forking a demo costs 0.2 ms,
loading the level 2 ms, of a roughly 1.1 s demo.

### Where a frame's time goes now (one copy, before round 3)
wall drawing 35%, floors and ceilings 18-21%, sprites and masked walls
10-15%, frame conversion 13-16%, validator fingerprint 3%, game logic
12-16%, status bar 2%.

### What changed and why

| # | Change | Files | Effect |
|---|---|---|---|
| 7 | Link-time optimization (`-flto=auto`). The hot functions live in different files; LTO lets the compiler inline across them. | `Makefile` | 3-6% |
| 8 | Floor/ceiling spans drawn 8 pixels per pass with AVX-512VL gather loads (256-bit registers), masked for the last pass. Positions are `position + i*step`, the same values the scalar loop reaches, so the pixels are identical. Plain C loop on any other CPU. | `r_draw.c` | about 1.5% |
| 9 | Wall loop (`R_RenderSegLoop`) keeps its per-column state in locals instead of globals, and calls the column drawer inline. Each byte store used to force the compiler to reload every global. | `r_segs.c`, `r_draw.h` | about 1.5% |
| 10 | Column drawer: 4 pixels per pass, texture row taken with one shift. Same for sprite/masked columns. Fewer instructions per pixel (10 to about 6); on one idle core this is hidden by branch mispredictions, it should matter more when two copies share a core. | `r_draw.h`, `r_things.c` | within noise alone |
| 11 | A finished demo exits directly. The original went through `I_Error`, which started a shell to look for `zenity` once per demo (two extra processes, about 6 ms). | `g_game.c` | 0.5% |
| 12 | The WAD is read into memory once per process; lumps are copied from there. No file system calls during the timed run (was about 740 seek+read pairs per demo), and forked workers no longer share a file position. | `w_file_stdc.c` | start-up robustness |
| 13 | New launcher layout: one process per physical core loads the game, then forks one pinned worker per hardware thread. No `taskset`, no per-copy shell. | `d_workers.c`, `launcher.c`, `run.sh` | faster start; needed for 14 |
| 14 | Optional (`FBSHARE=1`, off by default): the two workers of a core take turns drawing into one shared frame buffer, under a lock held while the frame is written and fingerprinted. | `d_workers.c`, `i_video.c` | to measure on frnt201 |
| 15 | `-fwrapv -fno-strict-aliasing`: Doom relies on integer wrap-around and type punning; these stop a newer or more aggressive compiler from assuming otherwise. | `Makefile` | none (safety) |

### Tried and dropped in round 3
- Profile-guided optimization on top of LTO: no gain beyond noise.
- `-O2` instead of `-O3` with gcc 12: 5-7% slower.
- 512-bit vectors for spans (`-DDOOM_SPAN_ZMM`): 7% slower off-cluster. Kept as a build switch so the flags sweep can check it on frnt201.
- Eight more frame-conversion variants (AVX-512 VBMI table lookups, 64-bit
  gathers, `rep movsb` row copies, L1 row buffers): all within 10% of a bare
  1 MB `memset`. Writing the 640x400x4 frame is limited by moving 16,000
  cache lines between L1 and L2, not by the conversion arithmetic.
- clang 18 is about 4% faster than gcc 12 here, but organizers build with
  plain `make -C doom`, so it only helps if they agree to load its module.

### How every change is checked
Besides the official validator (every 61st pixel), a test build hashes all
256,000 pixels of every frame and compares each tic with the stock engine.
Stock itself is not fully repeatable: 6 frames in demo1, 2 in demo2 and 3
in demo3 differ between two runs of the same stock binary (the original
reads a few bytes past a graphic; what it finds depends on memory layout).
On every other frame, the default build is identical to stock for all three
demos, in fork mode, with workers, and with the shared frame buffer.
`matched` stays at 7115 / 7088 / 6041. `-demoloop` still differs on a few
frames per demo (valid, but not the default).

### Hyperthreads: the open question for the full node
Two copies on one core share its 48 KB L1 and 2 MB L2. Each copy rewrites
a 1 MB frame buffer every frame, so two private frame buffers fill the L2.
A cache-only model of that (one copy, plus the memory traffic of a sibling
after every frame) slows the copy by:

| Sibling's traffic per frame | Slowdown of our copy |
|---|---|
| own 1 MB frame buffer + 0.5 MB of data | +33% |
| writes the same (shared) frame buffer + 0.5 MB of data | +15% |
| own frame buffer + 1 MB of data | +33% |
| shared frame buffer + 1 MB of data | +25% |

So the shared frame buffer could be worth roughly 10-15% with two copies
per core, and one copy per core may be close to two. Only frnt201 can say;
`scripts/sweep.sh ht` measures all three settings. A 16-CPU job is enough,
because the L2 is per core.

`FBSHARE=1` rules note: every frame of every demo is still drawn in full
(640x400) and fingerprinted while it is in the buffer; nothing is skipped,
cached or reused. It is unusual, though, so ask an organizer before making
it the default: "May two copies take turns writing complete frames into one
frame buffer?"

### What limits us now
- **CPU:** the renderer's inner loops and branch mispredictions (one per
  wall column, one per span).
- **Cache:** the 1 MB frame per tic. It passes through the 48 KB L1 into
  L2 and flushes L1 every frame; with two copies per core it also overflows
  the 2 MB L2 into L3.
- **Memory bandwidth:** fine as long as frame buffers stay in L2/L3
  (64 copies: 64 MB of frame buffers per socket against 64 MB of L2 plus
  60 MB of L3). Non-temporal stores would need about 450 GB/s and are out.
- **I/O and start-up:** negligible (logs: one small write per demo).

## Ideas considered and rejected (rules)
- `-nodraw`, lower resolution, skipping frames: breaks rule 2 (and fails validation).
- Other engines (FastDoom, Crispy, GZDoom): frames would not match `reference/`.
- Choosing short demos: the demo is fixed by the organizers.
- `setsid`/`nohup`/GNU parallel daemons: rule 5. Forked children stay in the
  process group, the parent waits for each one, and each child dies with its parent.
- Copying the WAD to `/dev/shm`: allowed in principle, but with fork mode the
  WAD is read once per copy, and files left in `/dev/shm` after the scorer's
  SIGKILL would clutter a shared node.

## To do on frnt201
1. Copy this tree to the cluster (see `CLUSTER-SETUP.md`, "Without pushing"),
   then `sbatch scripts/frnt201-sweep.job` from inside it. About 35 minutes.
   It writes `benchmarks/sweep-frnt201-<time>.txt`.
2. Read the `valid` block first: 0 invalid, matched 7115 (or 7116) / 7088 / 6041.
3. Read the two `ht` summaries (demo1 and demo3) and set `SMT` / `FBSHARE`
   in `scripts/run.sh` to the winner. Keep `FBSHARE=0` unless an organizer
   has said it is fine.
4. Read the `flags` summary; change `OPT` in `doom/Makefile` only for a
   clear win.
5. Ask the execs for a full-node slot: 128 copies share two 60 MB L3
   caches and the all-core clock is lower, which a 16-CPU job cannot show.

## AI tools
_(Required by RULES.md: state which AI tools you used, if any, and how. Write this yourself before tagging `final`.)_
