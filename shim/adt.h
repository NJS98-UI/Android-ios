#pragma once
#include <stdint.h>

/*
 * Apple Device Tree (little-endian) helper for the shim's loader: set the
 * physical base of the "sweet-fbcon" node's reg to the framebuffer that was
 * discovered from ABL's live FDT at boot. mkadt.py emits reg[0] = 0 for
 * oneplus,waffle because the splash address is only known at runtime; the
 * kernel's early console (patch 0003) maps reg[0], while AppleCLCD reads
 * boot_args.Video.v_baseAddr, so both must agree. Returns 1 when patched.
 */
int adt_set_fb(uintptr_t adt, uint64_t phys);
