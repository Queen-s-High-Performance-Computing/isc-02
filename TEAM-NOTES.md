# Team notes: optimization log

Working notes behind the README. Newest results first.

## 1. Current result (round 3, frnt201)

`scripts/score.sh <demo> 120 3` (the official command: three 2-minute runs,
median) on 16 CPUs of frnt201 (8 physical cores x 2 hardware threads, CPUs
0-7 and 64-71). Slurm job 12449478, 2026-11-11. Not a full-node run.

| Demo | Run 1 | Run 2 | Run 3 | Score (median) | Invalid | Frames matched |
|---|---|---|---|---|---|---|
| demo1 | 1080 | 1080 | 1084 | **1080** | 0 | 7115 of 7116 tics |
| demo2 | 1116 | 1116 | 1116 | **1116** | 0 | 7088 of 7088 tics |
| demo3 | 1022 | 1024 | 1022 | **1022** | 0 | 6041 of 6041 tics |

Runs agree within 0.4%. Raw output: `benchmarks/run120-frnt201-20261111-0159.txt`,
`benchmarks/run120-12449478.out`.

## 2. Full-node estimate (128 CPUs, 120 s)

From the 120 s run, each copy takes this long per demo (it loses on average
half a demo when the clock stops):

    seconds per demo = 120 / (score / 16 + 0.5)

demo1 1.77 s, demo2 1.71 s, demo3 1.86 s. Scaled to the whole node:

    score = 128 x (120 / seconds per demo - 0.5)

Round 3: about 8,600 / 8,900 / 8,200. This is an upper bound: with all 64
cores busy the clock is lower and 128 copies share two 60 MB L3 caches. Only a
full-node run gives the real number.

## 3. The node (frnt201, verified in a job on 2026-11-10)

- 2 x Intel Xeon Gold 6430 (Sapphire Rapids): 2 sockets x 32 cores x 2 threads
  = 128 CPUs. CPU n and n+64 are the two threads of one core.
- NUMA node 0 = CPUs 0-31 and 64-95, node 1 = 32-63 and 96-127.
- Caches: L1 data 48 KB and L2 2 MB per core (shared by its two threads),
  L3 60 MB per socket.
- Clock: 2.1 GHz base, 3.4 GHz max turbo, governor `performance`.
- AVX-512, BMI2. `-march=native` there means `sapphirerapids`. gcc 12.3 by
  default; gcc 13/14, clang 17/18 and Intel compilers as modules.
- Rocky Linux 8.10, kernel 4.18. Full probe: `benchmarks/frnt201-hw-2026-11-10.txt`.

## 4. What changed, round by round

### Round 1
| # | Change | Files | Effect (one copy, demo1) |
|---|---|---|---|
| 1 | Screen melt no longer sleeps on the clock. Every melt step is still drawn; all of them belong to one game tic, so only the last is fingerprinted, as in the original. | `d_main.c` | 5.6 s to 4.5 s per demo |
| 2 | Frame conversion (320x200 to 640x400) rewritten: it was 70% of CPU time (a per-pixel branch, and the output pointer reloaded on every store). Now a 32-bit palette built once per palette change, two pixels per 64-bit store, each finished row copied to the row below. Bit-identical output. | `i_video.c` | 3.6 s to 1.7 s |
| 3 | `-O3 -march=native` instead of `-Os`. | `Makefile` | 5-10% |
| 4 | Frame buffer and zone memory 2 MB-aligned, with huge pages requested. | `doomgeneric.c`, `i_system.c` | small |
| 5 | Game data loaded once per copy; a fresh child is forked for each demo (`-demofork`), so every demo starts from the clean pre-demo state. `-demoloop` (replay in one process) also exists but is not the default. | `d_main.c`, `d_loop.[ch]`, `g_game.c`, `st_stuff.[ch]` | about 2% |
| 6 | `run.sh`: one pinned copy per CPU, physical cores first. | `scripts/run.sh` | |

### Round 2
| Change | Files | Effect |
|---|---|---|
| Column and span drawers keep their table pointers in registers (`restrict` locals) instead of reloading them for every pixel. | `r_draw.c` | about 2% |

### Round 3
| # | Change | Files | Effect (off-cluster) |
|---|---|---|---|
| 7 | Link-time optimization (`-flto=auto`): the hot functions live in different files; LTO lets the compiler inline across them. | `Makefile` | 3-6% |
| 8 | Floors and ceilings drawn 8 pixels per step with AVX-512 gathers. Same positions and pixels as the plain loop, which other CPUs still use. | `r_draw.c` | about 1.5% |
| 9 | Wall loop keeps its per-column state in local variables instead of globals and calls the column drawer directly. | `r_segs.c`, `r_draw.h` | about 1.5% |
| 10 | Wall and sprite columns drawn 4 pixels per step; texture row from one shift. About 6 instructions per pixel instead of 10. | `r_draw.h`, `r_things.c` | small alone; more with two copies per core |
| 11 | A finished demo exits directly. The original went through `I_Error`, which started a shell to look for `zenity` once per demo. | `g_game.c` | 0.5% |
| 12 | WAD read into memory once per process; no file reads during the timed run, and forked copies never share a file position. | `w_file_stdc.c` | robustness |
| 13 | Launcher: one process per physical core loads the game, then forks one pinned worker per hardware thread, each with its own log. | `d_workers.[ch]`, `launcher.c`, `run.sh` | faster start |
| 14 | Optional, off by default (`FBSHARE=1`): the two workers of a core take turns writing complete frames into one shared frame buffer. | `d_workers.c`, `i_video.c` | not yet measured on frnt201 |
| 15 | `-fwrapv -fno-strict-aliasing`: Doom relies on integer wrap-around and type punning; these keep any compiler version from assuming otherwise. | `Makefile` | none (safety) |

Off-cluster, round 3 needs 7-10% fewer CPU cycles per demo than round 2
(2-CPU Intel VM, median of 9 interleaved runs).

## 5. How changes are checked

- The official validator (every 61st pixel of every frame) on all three demos:
  0 invalid, matched 7115 (sometimes 7116) / 7088 / 6041.
- A test build that hashes all 256,000 pixels of every frame and compares each
  tic with the stock engine. The stock engine itself varies between runs on 6,
  2 and 3 frames of demo1, 2 and 3 (it reads a few bytes past a graphic). On
  every other frame round 3 is identical to stock: in fork mode, with workers,
  with the shared frame buffer, and with gcc 12, gcc 13 and clang 18.
- `doom/platform.c`, `reference/` and `scripts/score.sh` are unchanged.

## 6. Tried and dropped

- AVX-512 frame conversion and eight other conversion variants: none faster
  than the round 1 version. Writing the 1 MB frame costs about as much as a
  bare 1 MB `memset`; the conversion arithmetic is not the limit.
- Profile-guided optimization: 3-5% on its own, nothing on top of LTO.
- `-O2`: 5-7% slower than `-O3`.
- 512-bit vectors for floors: 7% slower off-cluster (kept as the
  `-DDOOM_SPAN_ZMM` build switch for testing on frnt201).
- clang 18: about 4% faster than gcc 12 off-cluster, but organizers build with
  plain `make -C doom` and the default gcc.
- Ruled out by RULES.md: skipping frames or lower resolution (rule 2), other
  engines (frames would not match), `setsid`/`nohup`/daemons (rule 5).

## 7. What limits us now

- **CPU:** the renderer's inner loops and branch mispredictions (one per wall
  column, one per floor span).
- **Cache:** each copy rewrites a 1 MB frame every tic. Two copies on one core
  share its 2 MB L2, so they push each other's data out to L3.
- **Memory bandwidth:** fine while frame buffers stay in L2/L3.
- **Memory capacity, I/O, start-up:** not limits (about 2 ms to start a demo).
