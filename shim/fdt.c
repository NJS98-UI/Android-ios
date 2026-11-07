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

/* Read reg entry reg_index (<phys,size>, 2+2 cells or 1+1 when len==8). */
static int reg_entry(uintptr_t val, unsigned int len, unsigned int reg_index,
                     uint64_t *phys, uint64_t *size)
{
	unsigned int csz = (len == 8) ? 1 : 2;
	unsigned int pair = csz * 8;
	if (reg_index * pair + pair > len)
		return 0;
	const uint8_t *r = (const uint8_t *)val + reg_index * pair;
	uint64_t a = 0, s = 0;
	for (unsigned int i = 0; i < csz; i++) {
		a = (a << 32) | be32((uintptr_t)(r + i * 4));
		s = (s << 32) | be32((uintptr_t)(r + (csz + i) * 4));
	}
	*phys = a;
	*size = s;
	return 1;
}

/* Shared walker: first node whose compatible list has an entry matching
 * `match` (exact) or ending with `match` (when suffix). Returns its reg. */
static int find_compat_reg(uintptr_t fdt, const char *match, unsigned reg_index,
                           int suffix, uint64_t *phys, uint64_t *size)
{
	if (!fdt || be32(fdt) != FDT_MAGIC)
		return 0;
	uintptr_t p = fdt + be32(fdt + 8);
	uintptr_t strings = fdt + be32(fdt + 12);
	int depth = 0, matched = 0;

	for (;;) {
		uint32_t tok = be32(p);
		p += 4;
		switch (tok) {
		case FDT_BEGIN_NODE:
			depth++;
			matched = 0;
			p = align4(skip_str(p));
			break;
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
			/*
			 * A compatible list is a sequence of NUL-terminated strings;
			 * match when the sought string is one of them. A node matches
			 * only once, before its reg is read.
			 */
			if (!matched && streq(pname, "compatible")) {
				uintptr_t v = val;
				while ((uintptr_t)v < val + len) {
					const char *c = (const char *)v;
					if (suffix) {
						size_t cl = 0;
						while (c[cl])
							cl++;
						if (cl >= 5 && streq(c + cl - 5, match)) {
							matched = 1;
							break;
						}
					} else if (streq(c, match)) {
						matched = 1;
						break;
					}
					v += 1;
					while (*(const char *)v)
						v++;
					v += 1;
				}
			} else if (matched && streq(pname, "reg")) {
				if (reg_entry(val, len, reg_index, phys, size))
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
			child_is_splash = in_reserved && depth == 3 &&
					  (strstr_node(node_name, "splash") ||
					   strstr_node(node_name, "cont_"));
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
			/*
			 * A /reserved-memory child named *splash* (cont_splash_mem,
			 * splashfb, ...) holds the ABL's framebuffer. Match on a
			 * substring so vendor naming (OnePlus 12 etc.) is covered.
			 */
			if (child_is_splash && len >= 8 &&
			    streq((const char *)(strings + nameoff), "reg")) {
				if (len == 8) {
					*phys = be32(val);
					*size = be32(val + 4);
				} else if (len == 16) {
					*phys = (uint64_t)be32(val) << 32 | be32(val + 4);
					*size = (uint64_t)be32(val + 8) << 32 | be32(val + 12);
				} else {
					*phys = *size = 0;
					return 0;
				}
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
