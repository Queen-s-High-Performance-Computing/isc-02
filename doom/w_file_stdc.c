//
// Copyright(C) 1993-1996 Id Software, Inc.
// Copyright(C) 2005-2014 Simon Howard
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// DESCRIPTION:
//	WAD I/O functions.
//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include "m_misc.h"
#include "w_file.h"
#include "z_zone.h"

typedef struct
{
    wad_file_t wad;
    FILE *fstream;
} stdc_wad_file_t;

extern wad_file_class_t stdc_wad_file;

// DOOMATHON: each WAD is read into memory once, when it is opened, and
// lumps are then copied out of that image instead of being read from the
// file one fseek()/fread() pair at a time. Two reasons:
//  - it takes the file system out of the timed run (hundreds of small
//    reads per demo, from every copy at once, on a shared file system);
//  - workers forked from one process (d_workers.c) inherit the same open
//    file, and so the same file position: seeking and reading from it in
//    two processes at once would hand each the other's data.
// Lumps are still copied into zone memory exactly as before (wad.mapped
// stays NULL), so the engine's memory layout is unchanged. The table is
// kept outside the zone for the same reason.
#define MAX_WAD_IMAGES 16

static struct
{
    wad_file_t *wad;
    byte *data;
    size_t length;
} wad_images[MAX_WAD_IMAGES];

static void W_StdC_LoadImage(stdc_wad_file_t *file)
{
    size_t length = file->wad.length;
    byte *data;
    int i;

    for (i = 0; i < MAX_WAD_IMAGES && wad_images[i].wad != NULL; i++)
        ;
    if (i == MAX_WAD_IMAGES || length == 0)
        return;

    // On huge pages when the kernel allows: every demo is a forked child
    // (d_main.c), and fork copies one page-table entry per page.
    {
        const size_t huge = (size_t) 2 << 20;

        data = aligned_alloc(huge, (length + huge - 1) & ~(huge - 1));
        if (data == NULL)
            return;
        madvise(data, length, MADV_HUGEPAGE);
    }

    if (fseek(file->fstream, 0, SEEK_SET) != 0
     || fread(data, 1, length, file->fstream) != length)
    {
        // Leave this file to the fseek()/fread() path below.
        free(data);
        return;
    }

    wad_images[i].wad = &file->wad;
    wad_images[i].data = data;
    wad_images[i].length = length;
}

static wad_file_t *W_StdC_OpenFile(char *path)
{
    stdc_wad_file_t *result;
    FILE *fstream;

    fstream = fopen(path, "rb");

    if (fstream == NULL)
    {
        return NULL;
    }

    // Create a new stdc_wad_file_t to hold the file handle.

    result = Z_Malloc(sizeof(stdc_wad_file_t), PU_STATIC, 0);
    result->wad.file_class = &stdc_wad_file;
    result->wad.mapped = NULL;
    result->wad.length = M_FileLength(fstream);
    result->fstream = fstream;

    W_StdC_LoadImage(result);

    return &result->wad;
}

static void W_StdC_CloseFile(wad_file_t *wad)
{
    stdc_wad_file_t *stdc_wad;

    int i;

    stdc_wad = (stdc_wad_file_t *) wad;

    for (i = 0; i < MAX_WAD_IMAGES; i++)
    {
        if (wad_images[i].wad == wad)
        {
            free(wad_images[i].data);
            wad_images[i].data = NULL;
            wad_images[i].length = 0;
            // keep the slot marked as used; files are opened once per run
        }
    }

    fclose(stdc_wad->fstream);
    Z_Free(stdc_wad);
}

// Read data from the specified position in the file into the 
// provided buffer.  Returns the number of bytes read.

size_t W_StdC_Read(wad_file_t *wad, unsigned int offset,
                   void *buffer, size_t buffer_len)
{
    stdc_wad_file_t *stdc_wad;
    size_t result;
    int i;

    for (i = 0; i < MAX_WAD_IMAGES && wad_images[i].wad != NULL; i++)
    {
        if (wad_images[i].wad == wad && wad_images[i].data != NULL)
        {
            // Same result as fread(): short if the request runs off the end.
            if (offset >= wad_images[i].length)
                return 0;
            if (buffer_len > wad_images[i].length - offset)
                buffer_len = wad_images[i].length - offset;
            memcpy(buffer, wad_images[i].data + offset, buffer_len);
            return buffer_len;
        }
    }

    stdc_wad = (stdc_wad_file_t *) wad;

    // Jump to the specified position in the file.

    fseek(stdc_wad->fstream, offset, SEEK_SET);

    // Read into the buffer.

    result = fread(buffer, 1, buffer_len, stdc_wad->fstream);

    return result;
}


wad_file_class_t stdc_wad_file = 
{
    W_StdC_OpenFile,
    W_StdC_CloseFile,
    W_StdC_Read,
};


