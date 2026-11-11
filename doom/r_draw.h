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
//	System specific interface stuff.
//


#ifndef __R_DRAW__
#define __R_DRAW__

#include "doomdef.h"
#include "i_system.h"
#include "i_video.h"
#include "m_fixed.h"
#include "r_defs.h"




extern lighttable_t*	dc_colormap;
extern int		dc_x;
extern int		dc_yl;
extern int		dc_yh;
extern fixed_t		dc_iscale;
extern fixed_t		dc_texturemid;

// first pixel in a column
extern byte*		dc_source;		


// The span blitting interface.
// Hook in assembler or system specific BLT
//  here.
void 	R_DrawColumn (void);

// DOOMATHON: the body of R_DrawColumn, as an inline function taking the
// column as arguments instead of through the dc_* globals. R_DrawColumn()
// itself is now a call of this with the globals. The wall and sprite loops
// (r_segs.c, r_things.c) call it directly when the column function in use
// is R_DrawColumn, which saves an indirect call and a round trip through
// memory for every column. Same checks, same arithmetic, same pixels.
extern byte*		ylookup[];
extern int		columnofs[];
extern int		centery;

static inline void
R_DrawColumnInline
( int			x,
  int			yl,
  int			yh,
  fixed_t		iscale,
  fixed_t		texturemid,
  const byte*		src,
  const lighttable_t*	cmap )
{
    int			count;
    byte*		dest;
    fixed_t		frac;
    fixed_t		fracstep;

    count = yh - yl;

    // Zero length, column does not exceed a pixel.
    if (count < 0)
	return;

#ifdef RANGECHECK
    if ((unsigned)x >= SCREENWIDTH
	|| yl < 0
	|| yh >= SCREENHEIGHT)
	I_Error ("R_DrawColumn: %i to %i at %i", yl, yh, x);
#endif

    // Framebuffer destination address.
    // Use ylookup LUT to avoid multiply with ScreenWidth.
    // Use columnofs LUT for subwindows?
    dest = ylookup[yl] + columnofs[x];

    // Determine scaling,
    //  which is the only mapping to be done.
    fracstep = iscale;
    frac = texturemid + (yl-centery)*fracstep;

    // Inner loop that does the actual texture mapping,
    //  e.g. a DDA-lile scaling.
    //
    // Same pixels as the original loop
    //     *dest = dc_colormap[dc_source[(frac>>FRACBITS)&127]];
    // written so the CPU has less to do per pixel:
    //  - locals with restrict: a store through dest (a byte pointer may
    //    alias anything) otherwise forces the colormap and source
    //    pointers to be reloaded from memory on every pixel;
    //  - frac is kept shifted left by 9, so the texture row
    //    (frac>>16)&127 is the top 7 bits: one shift instead of a shift
    //    and a mask (bits above bit 22 never reach the result anyway);
    //  - four pixels per pass, each from its own multiple of the step, so
    //    the four lookups do not wait on one another.
    {
	const lighttable_t *restrict colormap = cmap;
	const byte *restrict source = src;
	byte *restrict d = dest;
	unsigned int f = (unsigned int) frac << 9;
	const unsigned int s1 = (unsigned int) fracstep << 9;
	const unsigned int s2 = s1 + s1;
	const unsigned int s3 = s2 + s1;
	const unsigned int s4 = s2 + s2;
	int n = count + 1;

	while (n >= 4)
	{
	    const byte p0 = colormap[source[f >> 25]];
	    const byte p1 = colormap[source[(f + s1) >> 25]];
	    const byte p2 = colormap[source[(f + s2) >> 25]];
	    const byte p3 = colormap[source[(f + s3) >> 25]];

	    d[0] = p0;
	    d[SCREENWIDTH] = p1;
	    d[SCREENWIDTH * 2] = p2;
	    d[SCREENWIDTH * 3] = p3;

	    d += SCREENWIDTH * 4;
	    f += s4;
	    n -= 4;
	}

	while (n > 0)
	{
	    *d = colormap[source[f >> 25]];
	    d += SCREENWIDTH;
	    f += s1;
	    n--;
	}
    }
}

void 	R_DrawColumnLow (void);

// The Spectre/Invisibility effect.
void 	R_DrawFuzzColumn (void);
void 	R_DrawFuzzColumnLow (void);

// Draw with color translation tables,
//  for player sprite rendering,
//  Green/Red/Blue/Indigo shirts.
void	R_DrawTranslatedColumn (void);
void	R_DrawTranslatedColumnLow (void);

void
R_VideoErase
( unsigned	ofs,
  int		count );

extern int		ds_y;
extern int		ds_x1;
extern int		ds_x2;

extern lighttable_t*	ds_colormap;

extern fixed_t		ds_xfrac;
extern fixed_t		ds_yfrac;
extern fixed_t		ds_xstep;
extern fixed_t		ds_ystep;

// start of a 64*64 tile image
extern byte*		ds_source;		

extern byte*		translationtables;
extern byte*		dc_translation;


// Span blitting for rows, floor/ceiling.
// No Sepctre effect needed.
void 	R_DrawSpan (void);

// Low resolution mode, 160x200?
void 	R_DrawSpanLow (void);


void
R_InitBuffer
( int		width,
  int		height );


// Initialize color translation tables,
//  for player rendering etc.
void	R_InitTranslationTables (void);



// Rendering function.
void R_FillBackScreen (void);

// If the view size is not full screen, draws a border around it.
void R_DrawViewBorder (void);



#endif
