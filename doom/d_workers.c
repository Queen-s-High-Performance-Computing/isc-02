//
// DOOMATHON: process layout for the scoring run (TEAM-OWNED, new file).
//
// scripts/run.sh starts one "core" process per physical core:
//
//     doomgeneric ... -timedemo demoN -demofork -workers 0,64 -worklog <dir>/w
//
// That process loads the game data once, then starts one worker per listed
// CPU. Each worker pins itself to its CPU, sends its output to its own log
// file (<dir>/w0.log, <dir>/w64.log) and plays the demo over and over
// (d_main.c, -demofork). Every process stays in the scorer's process
// group, and every child is killed if its parent dies.
//
//   -workers <cpu>[,<cpu>...]  one worker per CPU, pinned to it
//   -nopin                     do not pin (tuning runs)
//   -worklog <prefix>          worker on CPU c writes to <prefix><c>.log
//   -sharefb                   the workers of this process draw into one
//                              frame buffer, one at a time (see below)
//
// Why -sharefb exists: two workers on the two hyperthreads of one core
// share that core's 2 MB L2 cache. Each worker rewrites its whole 1 MB
// frame buffer every frame, so two private frame buffers alone fill the L2
// and push everything else out to L3. With one shared frame buffer the
// workers take turns: a worker takes the lock, writes its complete
// 640x400 frame, lets the validator fingerprint it (DG_DrawFrame), then
// releases the lock. Every frame of every demo is still drawn in full and
// checked while it is in the buffer; nothing is skipped, reused or stored.
//

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "doomgeneric.h"
#include "doomtype.h"
#include "i_system.h"
#include "m_argv.h"
#include "m_misc.h"

#include "d_workers.h"

#define MAX_WORKERS 64

// Non-NULL only in workers that share a frame buffer. Points at a lock
// word in memory shared by those workers (0 = free, 1 = held).
int *d_framelock = NULL;

static int ParseCpus(const char *list, int *cpus, int max)
{
    int n = 0;

    while (*list != '\0' && n < max)
    {
        char *end;
        long v = strtol(list, &end, 10);

        if (end == list)
            break;
        cpus[n++] = (int) v;
        list = (*end == ',') ? end + 1 : end;
    }

    return n;
}

// The CPUs named by -workers, or 0 if the option is absent. Used by
// launcher.c before anything is allocated, so that the game data ends up
// in memory next to the CPUs that will use it (NUMA first touch).
int D_WorkerCpus(int argc, char **argv, int *cpus, int max)
{
    int i;

    for (i = 1; i < argc - 1; i++)
    {
        if (!strcmp(argv[i], "-workers"))
            return ParseCpus(argv[i + 1], cpus, max);
    }

    return 0;
}

void D_PinToCpus(const int *cpus, int n)
{
    cpu_set_t set;
    int i;

    CPU_ZERO(&set);
    for (i = 0; i < n; i++)
    {
        if (cpus[i] >= 0 && cpus[i] < CPU_SETSIZE)
            CPU_SET(cpus[i], &set);
    }

    // Not fatal: an unpinned worker is slower, not wrong.
    if (CPU_COUNT(&set) > 0 && sched_setaffinity(0, sizeof(set), &set) != 0)
        fprintf(stderr, "D_PinToCpus: sched_setaffinity: %s\n", strerror(errno));
}

//
// Called once the game data is loaded, just before the demo starts.
// In the core process it starts the workers and waits for them; it only
// returns in a worker.
//
void D_StartWorkers(void)
{
    int cpus[MAX_WORKERS];
    pid_t pids[MAX_WORKERS];
    int n, i, p;
    boolean pin;
    const char *logprefix = NULL;

    p = M_CheckParmWithArgs("-workers", 1);
    if (p <= 0)
        return;

    n = ParseCpus(myargv[p + 1], cpus, MAX_WORKERS);
    if (n <= 0)
        I_Error("-workers: expected a list of CPU numbers, e.g. -workers 0,64");

    pin = !M_ParmExists("-nopin");

    p = M_CheckParmWithArgs("-worklog", 1);
    if (p > 0)
        logprefix = myargv[p + 1];

    if (M_ParmExists("-sharefb") && n > 1)
    {
        // One page for the lock, then the frame buffer, shared by every
        // process forked from here on.
        size_t page = 4096;
        size_t bytes = (size_t) DOOMGENERIC_RESX * DOOMGENERIC_RESY * sizeof(pixel_t);
        size_t len = page + ((bytes + page - 1) & ~(page - 1));
        void *mem = mmap(NULL, len, PROT_READ | PROT_WRITE,
                         MAP_SHARED | MAP_ANONYMOUS, -1, 0);

        if (mem == MAP_FAILED)
        {
            fprintf(stderr, "-sharefb: mmap failed (%s); using private "
                            "frame buffers\n", strerror(errno));
        }
        else
        {
            madvise(mem, len, MADV_HUGEPAGE);
            memset(mem, 0, len);
            d_framelock = (int *) mem;
            DG_ScreenBuffer = (pixel_t *) ((char *) mem + page);
        }
    }

    fflush(stdout);
    fflush(stderr);

    for (i = 0; i < n; i++)
    {
        pids[i] = fork();

        if (pids[i] < 0)
            I_Error("D_StartWorkers: fork failed");

        if (pids[i] == 0)
        {
            // Worker. Die with the core process.
            prctl(PR_SET_PDEATHSIG, SIGKILL);
            if (getppid() == 1)
                _exit(1);

            if (pin)
                D_PinToCpus(&cpus[i], 1);

            if (logprefix != NULL)
            {
                char path[4096];
                int fd;

                M_snprintf(path, sizeof(path), "%s%d.log", logprefix, cpus[i]);
                fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
                if (fd >= 0)
                {
                    dup2(fd, STDOUT_FILENO);
                    dup2(fd, STDERR_FILENO);
                    if (fd > STDERR_FILENO)
                        close(fd);
                }
            }

            return;
        }
    }

    // Core process: nothing left to do but wait for the workers.
    for (i = 0; i < n; i++)
    {
        while (waitpid(pids[i], NULL, 0) < 0 && errno == EINTR)
            ;
    }

    exit(0);
}

//
// The frame lock. Held only while one complete frame is written to the
// shared frame buffer and fingerprinted, a few tens of microseconds.
// Workers are pinned to their own CPUs, so the holder is always running:
// spinning is cheaper than sleeping. The yield is a safety net in case the
// holder was descheduled after all.
//
void D_FrameLockSlow(void)
{
    unsigned spins = 0;

    for (;;)
    {
        if (__atomic_load_n(d_framelock, __ATOMIC_RELAXED) == 0
         && __atomic_exchange_n(d_framelock, 1, __ATOMIC_ACQUIRE) == 0)
            return;

#if defined(__x86_64__) || defined(__i386__)
        __builtin_ia32_pause();
#endif
        if (++spins >= 20000)
        {
            sched_yield();
            spins = 0;
        }
    }
}
