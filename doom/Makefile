# QHPC DOOMATHON build. Team-owned: change compiler flags freely.
#
# Default flags (make OPT="..." overrides all of them for experiments):
#   -O3              optimize for speed (the kit shipped with -Os, for size)
#   -march=native    use every instruction set of the CPU this is built on
#                    (AVX-512 on frnt201). Build inside a job on frnt201:
#                    the binary may crash with "Illegal instruction" on
#                    older CPUs.
#   -flto=auto       link-time optimization: optimize across all source
#                    files at once (lets the hot drawing functions be
#                    inlined into their callers).
#   -fwrapv -fno-strict-aliasing
#                    Doom's 1993 fixed-point code relies on integer overflow
#                    wrapping around and on reading memory through pointers
#                    of another type. These tell the optimizer not to assume
#                    otherwise, so the frames cannot depend on how
#                    aggressive this particular compiler version is.
# Each optional flag is tried first and left out if this compiler does not
# accept it, so "make" works with any gcc.

CC      = gcc

probe = $(shell mkdir -p $(OBJDIR) && echo 'int main(void){return 0;}' | \
	$(CC) $(1) -x c - -o $(OBJDIR)/.probe >/dev/null 2>&1 && echo ok; \
	rm -f $(OBJDIR)/.probe)

OBJDIR = build
OUTPUT = doomgeneric

ifndef OPT
  ifeq ($(call probe,-march=native),ok)
    ARCH = -march=native
  endif
  ifeq ($(call probe,-O2 -flto=auto),ok)
    LTO = -flto=auto
  else ifeq ($(call probe,-O2 -flto),ok)
    LTO = -flto
  endif
  OPT = -O3 $(ARCH) $(LTO) -fwrapv -fno-strict-aliasing
endif

CFLAGS  += -ggdb3 $(OPT) -Wall -DNORMALUNIX -DLINUX -DSNDSERV -D_DEFAULT_SOURCE
LDFLAGS += -Wl,--gc-sections
LIBS    += -lm -lc

ifeq ($(V),1)
	VB=
else
	VB=@
endif

SRC_DOOM = dummy.o am_map.o doomdef.o doomstat.o dstrings.o d_event.o d_items.o d_iwad.o d_loop.o d_main.o d_workers.o d_mode.o d_net.o f_finale.o f_wipe.o g_game.o hu_lib.o hu_stuff.o info.o i_cdmus.o i_endoom.o i_joystick.o i_scale.o i_sound.o i_system.o i_timer.o memio.o m_argv.o m_bbox.o m_cheat.o m_config.o m_controls.o m_fixed.o m_menu.o m_misc.o m_random.o p_ceilng.o p_doors.o p_enemy.o p_floor.o p_inter.o p_lights.o p_map.o p_maputl.o p_mobj.o p_plats.o p_pspr.o p_saveg.o p_setup.o p_sight.o p_spec.o p_switch.o p_telept.o p_tick.o p_user.o r_bsp.o r_data.o r_draw.o r_main.o r_plane.o r_segs.o r_sky.o r_things.o sha1.o sounds.o statdump.o st_lib.o st_stuff.o s_sound.o tables.o v_video.o wi_stuff.o w_checksum.o w_file.o w_main.o w_wad.o z_zone.o w_file_stdc.o i_input.o i_video.o doomgeneric.o platform.o launcher.o
OBJS = $(addprefix $(OBJDIR)/, $(SRC_DOOM))

all: $(OUTPUT)

clean:
	rm -rf $(OBJDIR) $(OUTPUT) $(OUTPUT).map

$(OUTPUT): $(OBJS)
	@echo [Linking $@]
	$(VB)$(CC) $(CFLAGS) $(LDFLAGS) $(OBJS) -o $(OUTPUT) $(LIBS) -Wl,-Map,$(OUTPUT).map

$(OBJS): | $(OBJDIR)

$(OBJDIR):
	mkdir -p $(OBJDIR)

$(OBJDIR)/%.o: %.c
	@echo [Compiling $<]
	$(VB)$(CC) $(CFLAGS) -c $< -o $@
