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

## 5. Tuning sweep (batch job)

The repo carries the job file. From inside the repo on the login node:
```
sbatch scripts/frnt201-sweep.job      # 16 CPUs on frnt201, about 35 minutes
squeue -u $USER                        # is it still running?
cat sweep-<jobid>.out                  # same text as benchmarks/sweep-frnt201-<time>.txt
```
It runs `scripts/sweep.sh all`: a validity check on demo1-3, the
hyperthread test (`ht`) on demo1 and demo3, and the compiler-flag test
(`flags`). Other parts: `sbatch scripts/frnt201-sweep.job copies` or `cc`.

Reading the results (each block ends with a summary, best setting first):
- `valid`: every line must say `0 invalid`; matched is 7115 (or 7116) /
  7088 / 6041.
- `ht`: compares one copy per core, two copies per core, and two copies
  sharing one frame buffer, by `demos/s` (average demo time per copy, from
  the logs; steadier than the count). A 16-CPU job is 8 cores x 2 threads,
  and the cache the copies fight over is per core, so the winner here is
  the setting for the full node: `SMT=1` means 64 copies, `SMT=2` means 128.
  To adopt it, change the `SMT=${SMT:-2}` / `FBSHARE=${FBSHARE:-0}` lines
  in `scripts/run.sh` on the laptop. Ask an organizer before turning
  `FBSHARE` on (see TEAM-NOTES.md).
- `flags`: change `OPT` in `doom/Makefile` only for a clear win.
- A setting wins only if its worst run beats the other's best, or it wins
  every round. Other teams' jobs add noise; prefer quiet times.

### Without pushing (testing local commits)

To try commits that are not on GitHub yet, copy the working tree from the
laptop into a separate folder on the cluster, so the clone in `~/isc-02`
stays as it is:
```
# on the laptop
rsync -av --exclude .git --exclude results --exclude 'doom/build' \
      --exclude doom/doomgeneric --exclude '*.wad' \
      /Volumes/Disk/QHPC/DOOMATHON/isc-02/ \
      <frontenac-username>@login.cac.queensu.ca:isc-02-r3/

# on the cluster login node
cp ~/isc-02/freedoom1.wad ~/isc-02-r3/
cd ~/isc-02-r3 && sbatch scripts/frnt201-sweep.job

# afterwards, on the laptop: fetch the result file
scp '<frontenac-username>@login.cac.queensu.ca:isc-02-r3/benchmarks/sweep-*.txt' \
    /Volumes/Disk/QHPC/DOOMATHON/isc-02/benchmarks/
```

## 6. Before November 16

1. README.md: best score and its demo, what changed and why, current limits
   (see TEAM-NOTES.md), AI tools used.
2. Tag and push:
   ```
   git checkout main && git merge opt && git push
   git tag final && git push origin final
   ```
3. Organizers build with plain `make -C doom` and run `scripts/score.sh`,
   so the submitted defaults (Makefile `OPT`, run.sh `MODE`/`SMT`/`FBSHARE`) are
   what gets scored.
