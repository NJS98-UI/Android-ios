#pragma once
#include <stdint.h>

/* Boot the SWEETXNU payload found in the ABL ramdisk; returns only on error. */
const char *loader_boot(uintptr_t dtb);

/*
 * Read the framebuffer geometry the payload wants (v2 fb fields). Returns 1
 * and fills the out-params when a payload with a nonzero fb_base is present;
 * 0 when there is no payload or it carries no fb (shim should use the FDT).
 */
int loader_peek_fb(uintptr_t dtb, uint64_t *base, uint64_t *stride,
                   uint32_t *w, uint32_t *h, uint32_t *depth);
