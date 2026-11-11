//
// DOOMATHON: process layout for the scoring run. See d_workers.c.
//

#ifndef __D_WORKERS__
#define __D_WORKERS__

int  D_WorkerCpus(int argc, char **argv, int *cpus, int max);
void D_PinToCpus(const int *cpus, int n);
void D_StartWorkers(void);

// Frame lock: only does anything in workers started with -sharefb.
extern int *d_framelock;
void D_FrameLockSlow(void);

static inline void D_FrameLock(void)
{
    if (d_framelock != 0)
        D_FrameLockSlow();
}

static inline void D_FrameUnlock(void)
{
    if (d_framelock != 0)
        __atomic_store_n(d_framelock, 0, __ATOMIC_RELEASE);
}

#endif
