/* k1os-stream: text overlay drawn into an NV12 frame. MIT License, part of Datel OS. */
#ifndef OVERLAY_H
#define OVERLAY_H

#include <stddef.h>
#include <stdint.h>

#define OVERLAY_MAX_LINES 3

struct overlay {
	unsigned width, height;     /* frame size */
	unsigned font_w, font_h;
	const unsigned char (*font)[];  /* glyph rows, (font_w+7)/8 bytes per row */
	unsigned glyph_bytes;
	unsigned pad;               /* pixels around the text */
	unsigned nlines;
	char lines[OVERLAY_MAX_LINES][128];
};

/* size: 0 = small (12x24), 1 = large (16x32) */
void overlay_init(struct overlay *o, unsigned width, unsigned height, int size);
/* Draws a dark bar with o->lines at the bottom of the frame: y = luma
 * plane (stride = width), uv = interleaved chroma plane (stride = width). */
void overlay_draw(const struct overlay *o, uint8_t *y, uint8_t *uv);
/* Height of that bar in luma rows (even). */
unsigned overlay_bar_height(const struct overlay *o);

/* Text with the small (large = 0, 12x24) or large (16x32) font into a luma
 * buffer of the given stride, white, clipped at x = clip_w; glyph pixels also
 * set mask (same stride) to 1 when it is not NULL. For the graph panel. */
void overlay_text(int large, uint8_t *y, uint8_t *mask, unsigned stride, unsigned clip_w,
                  unsigned x0, unsigned y0, const char *s);
/* Width in pixels of s in that font. */
unsigned overlay_text_width(int large, const char *s);

#endif
