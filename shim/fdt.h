#pragma once
#include <stdint.h>

/* Read a u32/u64 (cell-size agnostic) property of /chosen. Returns 0 if absent. */
int fdt_chosen_u64(uintptr_t fdt, const char *prop, uint64_t *out);

/*
 * Find the ABL's splash framebuffer in /reserved-memory: the first child
 * whose node name contains "splash" (cont_splash_mem, splashfb, ...). Fills
 * phys (absolute) and size. Returns 0 if not found.
 */
int fdt_fb_probe(uintptr_t fdt, uint64_t *phys, uint64_t *size);

/*
 * Find the first node with the given "compatible" string (e.g. "arm,gic-v3")
 * and return its reg entry reg_index as an absolute <phys, size> pair.
 * Returns 0 if not found. Used by the shim diagnostics so the same binary
 * probes the GIC of any Qualcomm SoC.
 */
int fdt_compatible_reg(uintptr_t fdt, const char *compat, unsigned reg_index,
                       uint64_t *phys, uint64_t *size);

/*
 * Like fdt_compatible_reg but matches any compatible entry that ends with
 * `suffix` (e.g. "-imem"), which is how Qualcomm names syscons per SoC
 * (qcom,sm7150-imem / qcom,sm8650-imem). The shim uses this to find the
 * imem base without knowing the exact SoC.
 */
int fdt_compatible_reg_suffix(uintptr_t fdt, const char *suffix,
                              unsigned reg_index, uint64_t *phys, uint64_t *size);
