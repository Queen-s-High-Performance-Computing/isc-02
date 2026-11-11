#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#include "m_argv.h"

#include "doomgeneric.h"

pixel_t* DG_ScreenBuffer = NULL;

void M_FindResponseFile(void);
void D_DoomMain (void);


void doomgeneric_Create(int argc, char **argv)
{
	// save arguments
    myargc = argc;
    myargv = argv;

	M_FindResponseFile();

	// DOOMATHON: the 1 MB frame buffer is rewritten every frame. Put it on
	// one 2 MB-aligned huge page (when the kernel allows) so it costs one
	// TLB entry instead of 256.
	{
		size_t bytes = DOOMGENERIC_RESX * DOOMGENERIC_RESY * 4;
		size_t huge = 2u << 20;
		DG_ScreenBuffer = aligned_alloc(huge, huge);
		if (DG_ScreenBuffer)
			madvise(DG_ScreenBuffer, huge, MADV_HUGEPAGE);
		else
			DG_ScreenBuffer = malloc(bytes);
		memset(DG_ScreenBuffer, 0, bytes);
	}

	DG_Init();

	D_DoomMain ();
}

