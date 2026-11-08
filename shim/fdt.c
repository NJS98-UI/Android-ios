/*
 * Just enough flattened-device-tree parsing to find what ABL put in
 * /chosen (initrd location). Big-endian, 4-byte aligned tokens.
 */
#include "fdt.h"
#include <stddef.h>

#define FDT_MAGIC	0xd00dfeed
#define FDT_BEGIN_NODE	1
#define FDT_END_NODE	2
#define FDT_PROP	3
#define FDT_NOP		4
#define FDT_END		9
#define FDT_MAX_DEPTH	32

static uint32_t be32(uintptr_t a)
{
	return __builtin_bswap32(*(volatile uint32_t *)a);
}

static int streq(const char *a, const char *b)
{
	while (*a && *a == *b)
		a++, b++;
	return *a == *b;
}

static size_t slen(const char *s)
{
	size_t n = 0;
	while (s[n])
		n++;
	return n;
}

static int strstr_node(const char *haystack, const char *needle)
{
	while (*haystack) {
		const char *a = haystack, *b = needle;
		while (*a && *b && *a == *b)
			a++, b++;
		if (!*b)
			return 1;
		haystack++;
	}
	return 0;
}

static uintptr_t align4(uintptr_t a)
{
	return (a + 3) & ~3UL;
}

static uintptr_t skip_str(uintptr_t p)
{
	/* byte loads are fine on Device memory as long as they are aligned to 1 */
	while (*(volatile char *)p)
		p++;
	return p + 1;
}

int fdt_chosen_u64(uintptr_t fdt, const char *prop, uint64_t *out)
{
	if (!fdt || be32(fdt) != FDT_MAGIC)
		return 0;
	uintptr_t p = fdt + be32(fdt + 8);		/* off_dt_struct */
	uintptr_t strings = fdt + be32(fdt + 12);	/* off_dt_strings */
	int depth = 0, in_chosen = 0;

	for (;;) {
		uint32_t tok = be32(p);
		p += 4;
		switch (tok) {
		case FDT_BEGIN_NODE: {
			const char *name = (const char *)p;
			depth++;
			in_chosen = depth == 2 && streq(name, "chosen");
			p = align4(skip_str(p));
			break;
		}
		case FDT_END_NODE:
			if (in_chosen)
				return 0;
			depth--;
			break;
		case FDT_PROP: {
			uint32_t len = be32(p), nameoff = be32(p + 4);
			uintptr_t val = p + 8;
			if (in_chosen && streq((const char *)(strings + nameoff), prop)) {
				if (len == 4)
					*out = be32(val);
				else if (len == 8)
					*out = (uint64_t)be32(val) << 32 | be32(val + 4);
				else
					return 0;
				return 1;
			}
			p = align4(val + len);
			break;
		}
		case FDT_NOP:
			break;
		default:	/* FDT_END or garbage */
			return 0;
		}
	}
}

/* Decode reg entry reg_index as <phys,size>. A node's reg uses the cell
 * sizes its PARENT bus declared in #address-cells / #size-cells: SM8650's
 * /soc is 1/1 (GIC reg = four 1-cell values), while /reserved-memory and the
 * root are 2/2. Never guess from the property length - a 16-byte reg can be
 * one 2+2 pair or two 1+1 pairs. */
static int reg_entry(uintptr_t val, unsigned int len, unsigned ac, unsigned sc,
                     unsigned reg_index, uint64_t *phys, uint64_t *size)
{
	unsigned pair = (ac + sc) * 4;
	if (!ac || ac > 2 || sc > 2 || !pair)
		return 0;
	if ((uint64_t)reg_index * pair + pair > len)
		return 0;
	const uint8_t *r = (const uint8_t *)val + reg_index * pair;
	uint64_t a = 0, s = 0;
	for (unsigned i = 0; i < ac; i++)
		a = (a << 32) | be32((uintptr_t)(r + i * 4));
	for (unsigned i = 0; i < sc; i++)
		s = (s << 32) | be32((uintptr_t)(r + (ac + i) * 4));
	*phys = a;
	*size = s;
	return 1;
}

/* Shared walker: first node whose compatible list has an entry matching
 * `match` (exact) or ending with `match` (when suffix). Returns its reg.
 *
 * A node's reg is decoded with the cell sizes its PARENT declared in
 * #address-cells / #size-cells (default 2/2 for trees that omit them, which
 * is what the original sweet shim assumed). Qualcomm trees declare 1/1 on
 * /soc, so the GIC's four 1-cell values are two (phys,size) pairs. */
static int find_compat_reg(uintptr_t fdt, const char *match, unsigned reg_index,
                           int suffix, uint64_t *phys, uint64_t *size)
{
	if (!fdt || be32(fdt) != FDT_MAGIC)
		return 0;
	uintptr_t p = fdt + be32(fdt + 8);
	uintptr_t strings = fdt + be32(fdt + 12);
	/* index by node depth: cells for this node's reg, and cells it declares
	 * for its children. Both default to 2/2 when undeclared. */
	unsigned own_ac[FDT_MAX_DEPTH], own_sc[FDT_MAX_DEPTH];
	unsigned child_ac[FDT_MAX_DEPTH], child_sc[FDT_MAX_DEPTH];
	int depth = 0, matched = 0;
	uintptr_t node_reg = 0;
	unsigned node_reg_len = 0;
	size_t mlen = slen(match);

	for (;;) {
		uint32_t tok = be32(p);
		p += 4;
		switch (tok) {
		case FDT_BEGIN_NODE: {
			depth++;
			matched = 0;
			node_reg = 0;
			node_reg_len = 0;
			if (depth >= FDT_MAX_DEPTH)
				return 0;
			if (depth == 1) {
				own_ac[1] = own_sc[1] = 2;	/* root reg fallback */
			} else {
				own_ac[depth] = child_ac[depth - 1];
				own_sc[depth] = child_sc[depth - 1];
			}
			child_ac[depth] = child_sc[depth] = 2;	/* default until declared */
			p = align4(skip_str(p));
			break;
		}
		case FDT_END_NODE:
			if (depth == 1)
				return 0;
			depth--;
			matched = 0;
			break;
		case FDT_PROP: {
			uint32_t len = be32(p), nameoff = be32(p + 4);
			uintptr_t val = p + 8;
			const char *pname = (const char *)(strings + nameoff);
			if (streq(pname, "#address-cells") && len >= 4)
				child_ac[depth] = be32(val);
			else if (streq(pname, "#size-cells") && len >= 4)
				child_sc[depth] = be32(val);
			else if (streq(pname, "reg")) {
				node_reg = val;
				node_reg_len = len;
				if (matched && reg_entry(node_reg, node_reg_len,
				                         own_ac[depth], own_sc[depth],
				                         reg_index, phys, size))
					return 1;
			} else if (!matched && streq(pname, "compatible")) {
				/* A compatible list is a sequence of NUL-terminated strings;
				 * match when the sought string is one of them. */
				uintptr_t v = val;
				while (v < val + len) {
					const char *c = (const char *)v;
					if (suffix) {
						size_t cl = slen(c);
						if (cl >= mlen && streq(c + cl - mlen, match))
							matched = 1;
					} else if (streq(c, match)) {
						matched = 1;
					}
					if (matched)
						break;
					v += slen(c) + 1;
				}
				if (matched && node_reg &&
				    reg_entry(node_reg, node_reg_len, own_ac[depth],
				              own_sc[depth], reg_index, phys, size))
					return 1;
			}
			p = align4(val + len);
			break;
		}
		case FDT_NOP:
			break;
		default:	/* FDT_END or garbage */
			return 0;
		}
	}
}

int fdt_compatible_reg(uintptr_t fdt, const char *compat, unsigned reg_index,
                       uint64_t *phys, uint64_t *size)
{
	return find_compat_reg(fdt, compat, reg_index, 0, phys, size);
}

int fdt_compatible_reg_suffix(uintptr_t fdt, const char *suffix,
                              unsigned reg_index, uint64_t *phys, uint64_t *size)
{
	return find_compat_reg(fdt, suffix, reg_index, 1, phys, size);
}

int fdt_fb_probe(uintptr_t fdt, uint64_t *phys, uint64_t *size)
{
	if (!fdt || be32(fdt) != FDT_MAGIC)
		return 0;
	uintptr_t p = fdt + be32(fdt + 8);
	uintptr_t strings = fdt + be32(fdt + 12);
	/* Cell sizes of /reserved-memory's children (it declares 2/2 on Qualcomm;
	 * default there for trees that omit the declaration, e.g. test FDTs). */
	unsigned rm_ac = 2, rm_sc = 2;
	int depth = 0, in_reserved = 0, child_is_splash = 0;
	char node_name[64];

	for (;;) {
		uint32_t tok = be32(p);
		p += 4;
		switch (tok) {
		case FDT_BEGIN_NODE: {
			const char *name = (const char *)p;
			unsigned int i;
			for (i = 0; i < sizeof(node_name) - 1 && name[i]; i++)
				node_name[i] = name[i];
			node_name[i] = '\0';
			depth++;
			if (depth == 2)
				in_reserved = streq(node_name, "reserved-memory");
			/* The splash region ABL fills at boot is named cont_splash_mem
			 * or splash_region. The C16 PJD110 static DTB only carries a
			 * dynamic non_secure_display_region (no reg until ABL patches
			 * the live FDT), so waffle also accepts display/framebuffer
			 * names. Sweet keeps the original narrow match. */
			child_is_splash = in_reserved && depth == 3 &&
					  (strstr_node(node_name, "splash") ||
					   strstr_node(node_name, "cont_")
#ifdef DEVICE_WAFFLE
					   || strstr_node(node_name, "display") ||
					   strstr_node(node_name, "framebuffer")
#endif
					   );
			p = align4(skip_str(p));
			break;
		}
		case FDT_END_NODE:
			if (depth == 2 && in_reserved)
				return 0;	/* scanned every reserved-memory child */
			if (depth == 2)
				in_reserved = 0;
			depth--;
			child_is_splash = 0;
			break;
		case FDT_PROP: {
			uint32_t len = be32(p), nameoff = be32(p + 4);
			uintptr_t val = p + 8;
			const char *pname = (const char *)(strings + nameoff);
			/* Only the cell-size props of the reserved-memory node itself
			 * apply to its children, not those of a splash child. */
			if (in_reserved && depth == 2) {
				if (streq(pname, "#address-cells") && len >= 4)
					rm_ac = be32(val);
				else if (streq(pname, "#size-cells") && len >= 4)
					rm_sc = be32(val);
			}
			if (child_is_splash && streq(pname, "reg") &&
			    reg_entry(val, len, rm_ac, rm_sc, 0, phys, size))
				return 1;
			p = align4(val + len);
			break;
		}
		case FDT_NOP:
			break;
		default:	/* FDT_END or garbage */
			return 0;
		}
	}
}
