/*
 * Minimal little-endian Apple Device Tree walker. mkpayload.py places the ADT
 * in the payload; the shim copies it next to the kernel. On oneplus,waffle the
 * framebuffer base is only known at boot (ABL's live FDT), so mkadt.py emits
 * sweet-fbcon/reg[0] = 0 and adt_set_fb() patches in the discovered base.
 * The kernel's early console (patch 0003) and AppleCLCD (patch 0046) both
 * read that framebuffer, so it must agree with boot_args.Video.v_baseAddr.
 */
#include "adt.h"

static uint32_t rd32(uintptr_t p)
{
	return *(volatile uint32_t *)p;
}

static int name_is(uintptr_t p, const char *want)
{
	const char *n = (const char *)p;
	int i;
	for (i = 0; i < 32 && n[i] && want[i]; i++)
		if (n[i] != want[i])
			return 0;
	return n[i] == '\0' && want[i] == '\0';
}

/* Walk the node at 'off'; return the offset just past it. */
static uintptr_t walk(uintptr_t adt, uintptr_t off, uint64_t phys, int *done)
{
	uint32_t nprops = rd32(adt + off);
	uint32_t nchild = rd32(adt + off + 4);
	off += 8;
	int is_fbcon = 0;

	for (uint32_t i = 0; i < nprops; i++) {
		uint32_t len = rd32(adt + off + 32) & 0x7fffffff;
		uintptr_t val = adt + off + 36;
		if (name_is(adt + off, "name") && name_is(val, "sweet-fbcon"))
			is_fbcon = 1;
		/* reg = <phys size> as two little-endian u64 (mkadt.py u64()). */
		if (!*done && is_fbcon && len >= 8 && name_is(adt + off, "reg")) {
			uint64_t cur = (uint64_t)rd32(val) | (uint64_t)rd32(val + 4) << 32;
			if (!cur) {
				*(volatile uint32_t *)val = (uint32_t)phys;
				*(volatile uint32_t *)(val + 4) = (uint32_t)(phys >> 32);
				*done = 1;
			}
		}
		off = val + ((len + 3) & ~3UL) - adt;
	}
	if (*done)
		return off;
	for (uint32_t i = 0; i < nchild && !*done; i++)
		off = walk(adt, off, phys, done);
	return off;
}

int adt_set_fb(uintptr_t adt, uint64_t phys)
{
	int done = 0;
	if (!phys)
		return 0;
	walk(adt, 0, phys, &done);
	return done;
}
