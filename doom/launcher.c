// QHPC DOOMATHON launcher: the program's entry point.
//
// TEAM-OWNED FILE: change it however you like.
//
// As shipped, it plays one demo and exits (Doom exits by itself at the end
// of a -timedemo run). Running more demos per process, so start-up cost is
// paid only once, is one of the optimizations open to you.

#include <string.h>

#include "doomgeneric.h"
#include "d_workers.h"

int main(int argc, char **argv)
{
    // With -workers <cpus> (see d_workers.c and scripts/run.sh), move to
    // those CPUs before anything is allocated, so the game data is placed
    // in memory on their side of the machine (NUMA first touch).
    int cpus[64];
    int n = D_WorkerCpus(argc, argv, cpus, 64);
    int i, nopin = 0;

    for (i = 1; i < argc; i++)
        nopin |= !strcmp(argv[i], "-nopin");
    if (n > 0 && !nopin)
        D_PinToCpus(cpus, n);

    doomgeneric_Create(argc, argv);

    for (;;)
        doomgeneric_Tick();

    return 0;
}
