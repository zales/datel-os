/* k1os-stream: text overlay. MIT License, part of Datel OS.
 * The glyphs are Spleen (BSD-2-Clause, see LICENSE.spleen), converted by
 * bdf2c.py; glyph 95 is the degree sign (U+00B0), written as UTF-8 in text. */
#include <string.h>

#include "overlay.h"
#include "font12x24.h"
#include "font16x32.h"

#define Y_BACK 20     /* near black */
#define Y_TEXT 235    /* white */
#define UV_NEUTRAL 128

void overlay_init(struct overlay *o, unsigned width, unsigned height, int size)
{
	memset(o, 0, sizeof *o);
	o->width = width;
	o->height = height;
	if (size) {
		o->font_w = FONT16X32_W;
		o->font_h = FONT16X32_H;
		o->font = font16x32;
	} else {
		o->font_w = FONT12X24_W;
		o->font_h = FONT12X24_H;
		o->font = font12x24;
	}
	o->glyph_bytes = o->font_h * ((o->font_w + 7) / 8);
	o->pad = o->font_h / 4;
}

/* Map one UTF-8 character to a glyph index; advances *s. */
static int next_glyph(const char **s)
{
	unsigned char c = (unsigned char)**s;
	if (c == 0) {
		return -1;
	}
	(*s)++;
	if (c >= 32 && c < 127) {
		return c - 32;
	}
	if (c == 0xC2 && (unsigned char)**s == 0xB0) {   /* degree sign */
		(*s)++;
		return 95;
	}
	/* skip the rest of a multi-byte sequence, draw a space */
	while (((unsigned char)**s & 0xC0) == 0x80) {
		(*s)++;
	}
	return 0;
}

void overlay_text(int large, uint8_t *y, uint8_t *mask, unsigned stride, unsigned clip_w,
                  unsigned x0, unsigned y0, const char *s)
{
	unsigned font_w = large ? FONT16X32_W : FONT12X24_W;
	unsigned font_h = large ? FONT16X32_H : FONT12X24_H;
	const unsigned char *font = large ? (const unsigned char *)font16x32
	                                  : (const unsigned char *)font12x24;
	unsigned bpr = (font_w + 7) / 8;
	unsigned glyph_bytes = font_h * bpr;
	unsigned x = x0;
	int g;

	while ((g = next_glyph(&s)) >= 0) {
		const unsigned char *glyph = font + (unsigned)g * glyph_bytes;
		unsigned r, c;
		if (x + font_w > clip_w) {
			break;
		}
		for (r = 0; r < font_h; r++) {
			uint8_t *row = y + (size_t)(y0 + r) * stride + x;
			uint8_t *mrow = mask ? mask + (size_t)(y0 + r) * stride + x : NULL;
			for (c = 0; c < font_w; c++) {
				if (glyph[r * bpr + c / 8] & (0x80 >> (c & 7))) {
					row[c] = Y_TEXT;
					if (mrow) {
						mrow[c] = 1;
					}
				}
			}
		}
		x += font_w;
	}
}

unsigned overlay_text_width(int large, const char *s)
{
	unsigned n = 0;
	while (next_glyph(&s) >= 0) {
		n++;
	}
	return n * (large ? FONT16X32_W : FONT12X24_W);
}

unsigned overlay_bar_height(const struct overlay *o)
{
	unsigned bar_h = o->nlines * o->font_h + 2 * o->pad;
	return (bar_h + 1) & ~1u;
}

void overlay_draw(const struct overlay *o, uint8_t *y, uint8_t *uv)
{
	unsigned bar_h, bar_y0, i;

	if (o->nlines == 0) {
		return;
	}
	bar_h = overlay_bar_height(o);          /* whole chroma rows */
	if (bar_h > o->height) {
		return;
	}
	bar_y0 = o->height - bar_h;

	/* The buffer is uncached DMA memory: write whole rows, never read. */
	memset(y + (size_t)bar_y0 * o->width, Y_BACK, (size_t)bar_h * o->width);
	memset(uv + (size_t)(bar_y0 / 2) * o->width, UV_NEUTRAL, (size_t)(bar_h / 2) * o->width);

	for (i = 0; i < o->nlines; i++) {
		overlay_text(o->font == font16x32, y, NULL, o->width, o->width,
		             o->pad, bar_y0 + o->pad + i * o->font_h, o->lines[i]);
	}
}
