# DOOMATHON: ISC track starter kit

**Goal:** finish as many valid Doom demos as possible in **2 minutes** on `frnt201`, the club's node on Frontenac.

A *demo* is a recorded game that Doom plays back by itself. Your team decides how to run it: how many copies, how they're compiled, how they share the CPUs. Read [RULES.md](RULES.md) before you start, and [OPTIMIZATION.md](OPTIMIZATION.md) for ideas.



## Submission

### Best score

**1116 valid demos in 120 s on demo2** (`scripts/score.sh demo2 120 3`, median of 3 runs, 0 invalid).

Measured on frnt201 with **16 CPUs** (8 physical cores x 2 hardware threads, CPUs 0-7 and 64-71), the most a practice job may use. Slurm job 12449478, 2026-11-11 
Not a full-node run: the official run uses all 128 CPUs, and `scripts/run.sh` uses every CPU it is given.

### Results (frnt201, 16 CPUs, `scripts/score.sh <demo> 120 3`)

| Demo | Run 1 | Run 2 | Run 3 | Score (median) | Invalid | Frames matched |
|---|---|---|---|---|---|---|
| demo1 | 1080 | 1080 | 1084 | **1080** | 0 | 7115 / 7116 tics |
| demo2 | 1116 | 1116 | 1116 | **1116** | 0 | 7088 / 7088 tics |
| demo3 | 1022 | 1024 | 1022 | **1022** | 0 | 6041 / 6041 tics |

The three runs of each demo agree within 0.4%. Raw output: `benchmarks/run120-frnt201-20261111-0159.txt` and `benchmarks/run120-12449478.out`.

### What I changed and why it helped

Details and measurements for every change are in `TEAM-NOTES.md`.

1. **Screen melt no longer waits on the clock.** The level-start "melt" transition slept about 1.1 s per demo. Every step is still drawn; it just doesn't sleep between them
2. **Frame conversion rewritten** (`i_video.c`). Converting Doom's 320x200 image into the 640x400 frame took 70% of CPU time. It now uses a 32-bit palette built once, writes two pixels at a time and copies each finished row to the row below. The output is bit-identical.
3. **Compiler flags** (`Makefile`): `-O3 -march=native -flto=auto` instead of `-Os`. Link-time optimization lets the compiler optimize across source files. `-fwrapv -fno-strict-aliasing` keep the 1993 code behaving the same on any compiler version.
4. **Game data loaded once per process.** Each demo then runs in a freshly forked child process, so it starts from the clean pre-demo state and is computed in full from tic 0. The WAD file is read into memory once, so the timed run does no disk I/O.
5. **Renderer inner loops** (`r_segs.c`, `r_draw.c`, `r_draw.h`, `r_things.c`). The wall loop keeps its working values in registers instead of re-reading globals after every pixel; wall and sprite columns are drawn 4 pixels per step with less arithmetic; floors and ceilings are drawn 8 pixels at a time with AVX-512.
6. **A finished demo exits directly.** The original ended through an error handler that started a shell to look for a pop-up program, two extra processes per demo.
7. **Launcher** (`scripts/run.sh`, `doom/d_workers.c`). One process per physical core loads the game, then starts one copy per hardware thread, each pinned to its own CPU and writing its own log. All copies start within milliseconds, every process stays in the scorer's process group, and each child is killed if its parent dies.

Every frame is still the full 640x400 image and is validated. Beyond the official check, I compared all 256,000 pixels of every frame with the original engine on all three demos: they are identical wherever the original engine is itself repeatable

### What limits now 

- **CPU:** the renderer's inner loops (walls, floors, sprites) and branch mispredictions.
- **Cache:** each copy rewrites a 1 MB frame every tic. Two copies on one core share its 2 MB L2 cache, so they push each other's data out to the L3.
- **Memory bandwidth:** not a limit while frame buffers stay in L2/L3.
- **Memory capacity, I/O, start-up:** not limits. Starting each demo takes about 2 ms, and the logs are one short line per demo.


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
