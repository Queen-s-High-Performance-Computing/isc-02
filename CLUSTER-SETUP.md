# Running this branch on Frontenac (frnt201)

Target: frnt201, 2 x Intel Xeon Gold 6430 (Sapphire Rapids, AVX-512),
64 cores / 128 hardware threads, 250 GB RAM. Practice jobs: at most 16 CPUs.
Official scoring: whole node, `scripts/score.sh <demo> 120 3`.

## 1. Laptop: put the changes on a branch and push

```
cd /Volumes/Disk/QHPC/DOOMATHON/isc-02
git status                      # the changed files; results/ and *.wad are ignored
git checkout -b opt
git add -A
git commit -m "Faster frame conversion, unpaced melt, load-once demo modes, pinned run.sh"
git push -u origin opt
```

## 2. GitHub token (once)

GitHub > Settings > Developer settings > Personal access tokens > Tokens (classic)
> Generate new token (classic). Tick `repo`, expiry 30 days, save it.

## 3. Cluster login node: clone, switch branch, get game data

```
ssh <frontenac-username>@login.cac.queensu.ca
git config --global credential.helper 'cache --timeout=28800'
git clone https://github.com/Queen-s-High-Performance-Computing/isc-02.git
cd isc-02
git checkout opt
./get_freedoom.sh               # login node only: compute nodes have no internet
```
Username: `nistrib`. Password: the token.

Later updates: `cd ~/isc-02 && git pull`. Never edit code on the cluster.

## 4. Interactive job: check the node, build, validate

```
salloc --time=00:45:00 --cpus-per-task=16 --mem-per-cpu=1G
hostname                        # must be frnt201
lscpu | grep -E "Model name|Thread|Core|Socket|NUMA"
taskset -cp $$                  # the 16 CPUs Slurm gave you
cd ~/isc-02
module load gcc
make -C doom clean && make -C doom -j16
```

If `hostname` is not frnt201, ask the club execs which account/partition
reaches frnt201 and add it to `salloc`. Always build inside the job:
`-march=native` must see the frnt201 CPU (else "Illegal instruction").

Validate every demo (each line must say `0 invalid`):
```
scripts/score.sh demo1 30 1
scripts/score.sh demo2 30 1
scripts/score.sh demo3 30 1
```
Check frame matches: `grep -h DGVALID results/run1/*.log | sort | uniq -c`
(expected: demo1 matched=7115 or 7116, demo2 7088, demo3 6041).

Week-1 checkpoint: screenshot a `SCORE:` line.

Compare with the original launch method on the same build:
```
MODE=restart scripts/score.sh demo1 30 1
```
Type `exit` to end the job.

## 5. Tuning sweeps (batch job)

Save as `~/sweep.sh` on the cluster (job scripts are fine to keep there):
```
#!/bin/bash
#SBATCH --time=00:40:00
#SBATCH --cpus-per-task=16
#SBATCH --mem-per-cpu=1G
#SBATCH --output=sweep-%j.out
cd ~/isc-02
module load gcc
hostname; taskset -cp $$
scripts/sweep.sh flags demo1
scripts/sweep.sh copies demo1
scripts/score.sh demo2 30 1
scripts/score.sh demo3 30 1
```
Submit: `sbatch ~/sweep.sh`. Watch: `squeue -u $USER`. Read: `cat sweep-<jobid>.out`.

Reading the results:
- `flags`: keep the best `OPT` only if it wins by more than the run-to-run
  spread on 2-3 repeats. To adopt it, change the `OPT ?=` line in
  `doom/Makefile` on the laptop, commit, push, pull.
- `copies`: run.sh fills one CPU per physical core first, then the second
  hyperthread of each core. If your 16 CPUs are 8 cores x 2 threads,
  COPIES=8 vs COPIES=16 tells you whether hyperthreads add throughput; that
  maps to 64 vs 128 copies on the full node. The default uses every CPU
  (128 at scoring). If 64 wins clearly, set `COPIES=${COPIES:-64}` style
  default in run.sh only after confirming with repeats.
- Shared node: other teams' jobs add noise. Repeat anything that looks
  like a win; prefer runs at quiet times.

## 6. Before November 16

1. README.md: best score and its demo, what changed and why, current limits
   (see TEAM-NOTES.md), AI tools used.
2. Tag and push:
   ```
   git checkout main && git merge opt && git push
   git tag final && git push origin final
   ```
3. Organizers build with plain `make -C doom` and run `scripts/score.sh`,
   so the submitted defaults (Makefile `OPT`, run.sh `MODE`/`COPIES`) are
   what gets scored.
