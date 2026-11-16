# DOOMATHON ISC track: isc-02

## Result

**1366 valid demo2 demos in 120 seconds** (median of three runs: 1366, 1370, 1364; 0 invalid), measured with the submitted code and defaults using the official command `scripts/score.sh demo2 120 3` on 16 CPUs of `frnt201` (8 physical cores x 2 hardware threads). Slurm job 12478285, 16 November 2026. Practice jobs are limited to 16 CPUs, so this is not a full-node run, and the node was shared with other jobs at the time.

| Demo | **Submitted: round 4 + shared frame buffer** | Round 4, private frame buffers | Round 3 (11 Nov) |
|---|---|---|---|
| demo1 | **1306** (1308, 1306, 1306) | 1044 | 1010 |
| demo2 | **1366** (1366, 1370, 1364) | 1076 | 1024 |
| demo3 | **1306** (1306, 1310, 1306) | 1094 | 1022 |

All three setups ran in the same job, one after another for each demo, so they faced the same node conditions. Every run had 0 invalid demos, with 7115 / 7088 / 6041 frames matching the reference. Raw output is in [`benchmarks/`](benchmarks/).

For comparison, the unmodified kit finished 64 demos in 30 seconds on the same 16 CPUs, about 6.7 s per demo per copy. The submitted version needs about 1.4 s per demo per copy, roughly 4.8 times faster.

## Timeline

### 9 November: baseline and round 1

The first cluster run of the unmodified kit (job 12440760) gave 64 / 64 / 64 valid demos in 30 seconds. Profiling one copy showed where the time went:

| Change | Why it helped | Effect |
|---|---|---|
| Screen melt no longer waits on the clock | The level-start melt spent about 1.1 s per demo sleeping. Every melt step is still drawn. | 5.6 s to 4.5 s per demo |
| Frame conversion rewritten | Scaling 320x200 to 640x400 took 70% of the CPU time, with a branch and a pointer reload per pixel. Now a 32-bit palette is built once per palette change, two pixels go out per 64-bit store, and each finished row is copied to the row below. Bit-identical output. | 3.6 s to 1.7 s per demo |
| `-O3 -march=native` instead of `-Os` | The kit optimized for size. | 5-10% |
| 2 MB-aligned frame buffer and zone memory with huge pages | Fewer TLB misses. | small |
| Load once, fork a fresh child per demo | The game data is loaded once per copy; each demo starts from the clean pre-demo state in a new child process and is computed in full. | about 2% |
| `run.sh`: one pinned copy per CPU | Each copy keeps its cache warm. | |

Result: **220 / 233 / 215 valid demos in 30 s**, 3.4 to 3.6 times the kit.

### 10 November: hardware probe and round 2

A probe job (12449038) confirmed the node: 2 x Intel Xeon Gold 6430 (Sapphire Rapids), 64 cores / 128 hardware threads, 48 KB L1d and 2 MB L2 per core (shared by its two threads), 60 MB L3 per socket, AVX-512, gcc 12.3 by default.

Round 2 kept the wall and floor drawers' table pointers in registers instead of reloading them for every pixel (about 2%).

### 11 November: round 3

| Change | Effect |
|---|---|
| Link-time optimization, plus `-fwrapv -fno-strict-aliasing` so the 1993 fixed-point code cannot depend on how aggressive the compiler is | 3-6% |
| Floors and ceilings drawn 8 pixels at a time with AVX-512 | about 1.5% |
| Wall loop keeps its per-column state in local variables | about 1.5% |
| Wall and sprite columns drawn 4 pixels per step | small |
| A finished demo exits directly; the original went through `I_Error`, which started a shell every time | 0.5% |
| WAD read into memory once; no disk reads during the run | robustness |
| New launcher: one process per physical core loads the game and starts one pinned worker per hardware thread | faster start |
| Shared frame buffer written and verified, still off | |

Tried and dropped: nine frame-conversion variants (none faster), profile-guided optimization (no gain on top of LTO, and it reuses data from a training run), `-O2` (5-7% slower), 512-bit floor drawing (slower), clang (faster, but organizers build with the default gcc).

Result: **1080 / 1116 / 1022 valid demos in 120 s** (median of 3, job 12449478).

### 15-16 November: round 4

The biggest finding was that gcc 12, the compiler on `frnt201`, did not vectorize the round 1 conversion loop, while gcc 13 did. The round 3 numbers on the cluster had been running a scalar frame conversion.

| Change | Effect |
|---|---|
| Frame conversion written with AVX2: 8 source pixels per step, one palette gather, both output rows stored directly | 9-16% |
| Texture column tables fetched once per wall instead of once per column; a cached column is returned without a function call | 1.5% fewer instructions |
| Status bar numbers redrawn only when they change | about 1% |
| Plain executable: no PIE, stack protector or CET where the compiler enables them by default (each flag tested first) | up to 3% fewer instructions |
| Floor and ceiling setup checks 32 columns at once with AVX-512 and only builds spans where one starts or ends (85-88% of columns need no work) | about 5% |
| A moving monster no longer searches the BSP tree twice for the same position | 0.3% |
| **Shared frame buffer turned on** (see below) | **+19-27% on frnt201** |

Checks on the cluster:

- Job 12477797: the code builds with no modules loaded (gcc 12.3.1); demo1-3 valid. Copies per core on demo1 + demo3 (30 s runs): one copy per core 17.9 demos/s, two copies 19.0, two copies with a shared frame buffer 23.1.
- Job 12478285: round 3, round 4 and round 4 with the shared frame buffer on all three demos at 120 s x 3 (table above). Round 4 alone beats round 3 by 3-7%; the shared frame buffer adds 19-27% on top, and its runs agree within 0.5% even with the node at load 244.

## The shared frame buffer

The two hardware threads of a core share its 2 MB L2 cache. Each copy rewrites a 1 MB frame every tic, so two copies with private frame buffers do not fit, and both keep pushing data out to the slower shared L3.

With `FBSHARE=1` (the default in `scripts/run.sh`) the two copies on a core take turns using one frame buffer. A copy takes a lock, writes its complete 640x400 frame, `platform.c` fingerprints it, and the lock is released. Each copy still draws every frame of every demo in full, and each frame is checked while it is in the buffer. Nothing is skipped, stored or reused. Code: `doom/d_workers.c` and `doom/i_video.c`. `FBSHARE=0` turns it off.

## What limits us now

- **CPU:** the renderer's inner loops, mainly wall columns (about a quarter of the time), sprites and floor spans, and the branch mispredictions they cause.
- **Memory writes:** each copy writes a 1 MB frame every tic; the conversion now runs at about the speed of a plain 1 MB memory write.
- **Cache:** with the shared frame buffer, the two copies of a core fit in its L2. On the full node, 128 copies share two 60 MB L3 caches and the clock is lower with all cores busy, so the 16-CPU numbers are an upper bound per core.
- **Not limits:** memory capacity, disk I/O (none during the run) and start-up (about 2 ms per demo).

## How every change was checked

- The official validator on demo1-3 after every change: 0 invalid, 7115 (or 7116) / 7088 / 6041 frames matching.
- A test build that hashes all 256,000 pixels of every frame and compares each tic with the original engine. The original itself varies between runs on 6, 2 and 3 frames of demo1, 2 and 3; on every other frame our version is identical, in every launch mode and with gcc 12, gcc 13 and clang.
- `doom/platform.c`, `reference/`, `scripts/score.sh` and `get_freedoom.sh` are unchanged. `run.sh` uses no `srun`, `sbatch` or `ssh`, and starts no `setsid`, `nohup`, `disown` or daemons; every process stays in the scorer's process group.

More detail on each change: [TEAM-NOTES.md](TEAM-NOTES.md).

## AI tools

<!-- Required by RULES.md: which AI tools were used, if any, and how. -->

---

# The starter kit

**Goal:** finish as many valid Doom demos as possible in **2 minutes** on `frnt201`, the club's node on Frontenac.

A *demo* is a recorded game that Doom plays back by itself. Your team decides how to run it: how many copies, how they're compiled, how they share the CPUs. Read [RULES.md](RULES.md) before you start, and [OPTIMIZATION.md](OPTIMIZATION.md) for ideas.

## What's in here

| Path | What it is | Can you change it? |
|---|---|---|
| `doom/` | The Doom engine ([doomgeneric](https://github.com/ozkl/doomgeneric)), its `Makefile` and `launcher.c` | Yes |
| `doom/platform.c` | Runs Doom headless and checks every demo | **No** (replaced at scoring) |
| `scripts/run.sh` | How your team launches Doom | Yes |
| `scripts/score.sh` | The official scorer | No |
| `reference/` | Correct frame fingerprints for demo1–demo3 | No |
| `get_freedoom.sh` | Downloads the game data | No |

## How you'll work

You edit code on **your laptop** and push it to GitHub. On Frontenac you only **pull** it on the login node, then build and run it in a job.
```
laptop: edit → commit → push  ──►  GitHub  ──►  Frontenac login node: pull  ──►  job: build → score
```
Don't edit code on the cluster. The only files worth editing there are your own job scripts.

You need a Frontenac account with MFA, and you need to have accepted the GitHub org invite.

## One-time setup

**1. On your laptop: connect to GitHub with an SSH key.** In a terminal (PowerShell on Windows):
```
ssh-keygen -t ed25519 -C "<your-github-email>"    # press Enter at every prompt
cat ~/.ssh/id_ed25519.pub                         # copy the whole line it prints
```
On GitHub: **Settings → SSH and GPG keys → New SSH key**, paste the line, and save. Then check it:
```
ssh -T git@github.com        # type "yes" if asked; it should say "Hi <your-github-name>!"
```

**2. On your laptop: clone your team's repo**
```
git clone git@github.com:Queen-s-High-Performance-Computing/<your-team-repo>.git
```

**3. For the cluster: make a GitHub token.** The cluster pulls over HTTPS, which needs a token rather than your password. On GitHub: **Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token (classic)**. Tick the **`repo`** scope, set the expiry to 30 days, and copy the token somewhere safe. GitHub shows it only once.

**4. On the cluster: clone your team's repo and get the game data**
```
ssh <username>@login.cac.queensu.ca
git config --global credential.helper 'cache --timeout=28800'   # remember the token for 8 hours
git clone https://github.com/Queen-s-High-Performance-Computing/<your-team-repo>.git
cd <your-team-repo>
./get_freedoom.sh
```
When git asks, enter your GitHub username, and paste the **token** as the password.

## Every time you test a change

**1. On your laptop:** edit, then
```
git commit -am "describe what you changed"
git push
```

**2. On the Frontenac login node: pull**
```
cd ~/<your-team-repo>
git pull
```

**3. Start a job, then build and score inside it.** Never run Doom on the login node.
```
salloc --time=00:30:00 --cpus-per-task=16 --mem-per-cpu=1G
cd ~/<your-team-repo>
module load gcc
make -C doom clean && make -C doom -j16
scripts/score.sh demo1 30 1
```
All teams share `frnt201`, so use at most 16 CPUs per job. Your practice numbers will vary while other teams are running. The clean build makes sure changes to compiler flags take effect. You'll see compiler warnings; that's normal for 1990s code. You should then see something like:
```
Scoring demo1: 1 run(s) of 30s on frnt201, 16 CPUs
  run 1: 64 valid demos, 0 invalid
SCORE: 64 valid demo1 demos in 30s (median of 1)
```
Each copy's output is in `results/run1/`. The official score is `scripts/score.sh demo1 120 3` with the whole node reserved.

Type `exit` to end the job.

**Or run it as a batch job,** so you don't wait at the terminal. Pull first (step 2), then save this as `~/test.sh`:
```bash
#!/bin/bash
#SBATCH --time=00:15:00
#SBATCH --cpus-per-task=16
#SBATCH --mem-per-cpu=1G
#SBATCH --output=test-%j.out
cd ~/<your-team-repo>
module load gcc
make -C doom clean && make -C doom -j16
scripts/score.sh demo1 30 1
```
Submit it with `sbatch ~/test.sh`. The results appear in `test-<jobid>.out`, and `squeue -u $USER` shows whether it's still running.

**Week-1 checkpoint (November 9):** post a screenshot of your first `SCORE:` line in the club channel.

## Common problems

| Problem | Fix |
|---|---|
| `Not inside a Slurm job` | Start a job with `salloc` first |
| `Please specify memory per cpu using --mem-per-cpu` | Use `--mem-per-cpu`, not `--mem` |
| `Get the game data first` | Run `./get_freedoom.sh` in your repo on the cluster |
| `Authentication failed` on the cluster | Paste the token, not your GitHub password, and check it has the `repo` scope |
| `git pull` says your local changes would be overwritten | You edited on the cluster. Run `git stash`, then `git pull` |
| `has exceeded its time limit` | Your files are safe. Start a new job with a longer `--time` |
| Every demo is `invalid` | Your change altered what's drawn. See *Valid demos* in RULES.md |
| `ssh -T git@github.com` hangs on your laptop | Your network blocks SSH's port. See *SSH over port 443* below |
| `Permission denied (publickey)` on your laptop | Your key isn't on GitHub yet, or you copied only part of the line |
| `Illegal instruction` | You built with `-march=native` somewhere other than `frnt201`. Build inside a job |

### SSH over port 443

Some networks block SSH's normal port. GitHub also accepts SSH on port 443. On your laptop, add this to `~/.ssh/config` (create the file if it doesn't exist):
```
Host github.com
    HostName ssh.github.com
    Port 443
```

## Licence

`doom/` is doomgeneric, licensed under the GNU GPL v2 (see `LICENSE`). Keep the licence file in your repo.
