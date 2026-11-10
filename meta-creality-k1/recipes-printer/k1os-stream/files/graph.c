/* k1os-stream: graph panel. MIT License, part of Datel OS.
 *
 * A 320x128 panel: a legend row with the current nozzle (red) and bed
 * (blue) temperature and the top of the scale, the last 20 minutes of both
 * temperatures with their targets dashed over faint 100 and 200 degree
 * lines and 5 minute ticks, autoscaled from 0 to at least 260 degrees, and
 * below it a progress bar with the percentage and the remaining time (or
 * the printer's state while it does not print). The stream is 720p at
 * 2.5 Mbit/s, so lines are 3 px thick and the digits 16x32: thin detail
 * would smear.
 *
 * NV12 chroma is a quarter of the luma, so a coloured pixel also colours
 * the 2x2 block it lies in; lines are at least 2 px thick for that.
 * Colours are BT.601 limited range. */
#include <stdio.h>
#include <string.h>

#include "graph.h"
#include "overlay.h"

/* layout */
#define LEGEND_Y 2          /* 12x24 text row */
#define PLOT_X 2
#define PLOT_Y 28
#define PLOT_W (GRAPH_W - 2 * PLOT_X)
#define PLOT_H 62
#define BAR_Y 96
#define BAR_H 28
#define BAR_X 2
#define BAR_W (GRAPH_W - 2 * BAR_X)
#define TEXT_Y 94           /* 16x32 digits over the bar */
#define T_MIN_MAX 2600      /* the axis spans 0 to at least 260 degrees (tenths) */

struct color { uint8_t y, u, v; };
static const struct color RED    = { 140, 104, 198 };   /* nozzle line */
static const struct color BLUE   = { 146, 179,  93 };   /* bed line */
static const struct color RED_T  = { 185, 108, 190 };   /* nozzle text, lighter */
static const struct color BLUE_T = { 190, 170, 100 };   /* bed text, lighter */
static const struct color GREEN  = { 140,  96,  75 };   /* progress */
static const struct color GRAY   = { 150, 128, 128 };   /* bar frame, ticks */
static const struct color DIM    = { 110, 128, 128 };   /* grid lines */
static const struct color LABEL  = { 180, 128, 128 };   /* axis label */
static const struct color WHITE  = { 235, 128, 128 };   /* values in the statistics panel */
static const struct color WARN   = { 190, 100, 180 };   /* a value worth a look, orange */

int graph_init(struct graph *g, unsigned width, unsigned height, unsigned bar_h,
               enum graph_corner corner)
{
	unsigned margin = 16, i;

	memset(g, 0, sizeof *g);
	if (width < GRAPH_W + 2 * margin || height < GRAPH_H + bar_h + 2 * margin) {
		return -1;
	}
	g->stride = width;
	g->x0 = (corner == GRAPH_TL || corner == GRAPH_BL) ? margin : width - GRAPH_W - margin;
	g->y0 = (corner == GRAPH_TL || corner == GRAPH_TR) ? margin : height - bar_h - GRAPH_H - margin;
	g->x0 &= ~1u;
	g->y0 &= ~1u;
	/* the picture under the panel keeps a third of its light */
	for (i = 0; i < 256; i++) {
		g->dark[i] = 16 + (i * 5) / 16;
	}
	memset(g->uv, 128, sizeof g->uv);
	for (i = 0; i < GRAPH_BUFS; i++) {
		memset(g->bg_luma[i], 16, sizeof g->bg_luma[i]);
		memset(g->bg_uv[i], 128, sizeof g->bg_uv[i]);
	}
	return 0;
}

int graph_init_beside(struct graph *g, const struct graph *other, unsigned height, unsigned bar_h)
{
	unsigned gap = 8, margin = 16, y0;

	if (other->y0 + 2 * GRAPH_H + gap + margin + bar_h <= height) {
		y0 = other->y0 + GRAPH_H + gap;
	} else if (other->y0 >= GRAPH_H + gap + margin) {
		y0 = other->y0 - GRAPH_H - gap;
	} else {
		return -1;
	}
	memcpy(g, other, sizeof *g);        /* stride, darkening table, cleared planes */
	g->x0 = other->x0;
	g->y0 = y0 & ~1u;
	return 0;
}

/* ------------------------------------------------------------------ */
/* drawing into the panel                                              */

static void put(struct graph *g, int x, int y, const struct color *c)
{
	unsigned i;
	if (x < 0 || y < 0 || x >= GRAPH_W || y >= GRAPH_H) {
		return;
	}
	i = (unsigned)y * GRAPH_W + (unsigned)x;
	g->luma[i] = c->y;
	g->mask[i] = 1;
	i = (unsigned)(y / 2) * GRAPH_W + (unsigned)(x / 2) * 2;
	g->uv[i] = c->u;
	g->uv[i + 1] = c->v;
	g->uvmask[(unsigned)(y / 2) * (GRAPH_W / 2) + (unsigned)(x / 2)] = 1;
}

static void fill_rect(struct graph *g, int x, int y, int w, int h, const struct color *c)
{
	int i, j;
	for (j = y; j < y + h; j++) {
		for (i = x; i < x + w; i++) {
			put(g, i, j, c);
		}
	}
}

/* Vertical span x, y_from..y_to (any order), thickened by `thick` rows. */
static void vspan(struct graph *g, int x, int y_from, int y_to, int thick, const struct color *c)
{
	int lo = y_from < y_to ? y_from : y_to;
	int hi = y_from < y_to ? y_to : y_from;
	int half = thick / 2;
	fill_rect(g, x, lo - half, 1, hi - lo + 1 + 2 * half, c);
}

/* Text in a colour: the glyphs go through a scratch buffer, then into the
 * panel pixel by pixel so that the chroma gets the colour too. */
static void text_color(struct graph *g, int large, int x, int y, const char *s, const struct color *c)
{
	static uint8_t scratch_y[GRAPH_W * 32], scratch_m[GRAPH_W * 32];
	unsigned h = large ? 32 : 24, r, col;
	memset(scratch_m, 0, sizeof scratch_m);
	overlay_text(large, scratch_y, scratch_m, GRAPH_W, GRAPH_W, 0, 0, s);
	for (r = 0; r < h; r++) {
		for (col = 0; col < GRAPH_W; col++) {
			if (scratch_m[r * GRAPH_W + col]) {
				put(g, x + (int)col, y + (int)r, c);
			}
		}
	}
}

/* Temperature in tenths to a panel row. */
static int t_to_y(int t, int t_max)
{
	int y = PLOT_Y + PLOT_H - 1 - (int)((long)t * (PLOT_H - 1) / t_max);
	if (y < PLOT_Y) y = PLOT_Y;
	if (y > PLOT_Y + PLOT_H - 1) y = PLOT_Y + PLOT_H - 1;
	return y;
}

/* One series over the plot width: column c covers the samples of
 * c * HISTORY_N / PLOT_W .. on a fixed 20 minute axis, newest at the right;
 * a history shorter than that leaves the left empty. dashed: 6 columns on,
 * 4 off (for targets); zero and gaps break the line. */
static void plot_series(struct graph *g, const struct temp_history *h, const int16_t *s,
                        int t_max, int thick, int dashed, const struct color *c)
{
	int prev_y = -1, x;
	unsigned missing = HISTORY_N - h->n;

	for (x = 0; x < PLOT_W; x++) {
		unsigned from = (unsigned)x * HISTORY_N / PLOT_W;
		unsigned to = (unsigned)(x + 1) * HISTORY_N / PLOT_W;
		unsigned i, cnt = 0;
		long sum = 0;
		int y;

		if (to <= from) {
			to = from + 1;
		}
		for (i = from; i < to; i++) {
			if (i >= missing && s[i - missing] != TEMP_NONE) {
				sum += s[i - missing];
				cnt++;
			}
		}
		if (cnt == 0 || (dashed && sum <= 0)) {
			prev_y = -1;
			continue;
		}
		y = t_to_y((int)(sum / (long)cnt), t_max);
		if (!dashed || (x / 6) % 2 == 0) {
			vspan(g, PLOT_X + x, prev_y >= 0 ? prev_y : y, y, thick, c);
		}
		prev_y = y;
	}
}

static int series_max(const struct temp_history *h, const int16_t *s)
{
	unsigned i;
	int m = 0;
	for (i = 0; i < h->n; i++) {
		if (s[i] != TEMP_NONE && s[i] > m) {
			m = s[i];
		}
	}
	return m;
}

void graph_render(struct graph *g, const struct printer_state *st, const struct temp_history *h)
{
	char text[32];
	int t_max = T_MIN_MAX, m, fill_w;
	int printing, done;

	memset(g->luma, 0, sizeof g->luma);
	memset(g->mask, 0, sizeof g->mask);
	memset(g->uv, 128, sizeof g->uv);
	memset(g->uvmask, 0, sizeof g->uvmask);

	/* --- temperatures: 0 .. max(260, highest value + 10), in steps of 20 --- */
	m = series_max(h, h->nozzle);
	if (series_max(h, h->nozzle_target) > m) m = series_max(h, h->nozzle_target);
	if (series_max(h, h->bed) > m) m = series_max(h, h->bed);
	if (series_max(h, h->bed_target) > m) m = series_max(h, h->bed_target);
	m = ((m + 100 + 199) / 200) * 200;
	if (m > t_max) {
		t_max = m;
	}
	/* grid: dotted lines every 100 degrees, ticks every 5 minutes */
	for (m = 1000; m < t_max; m += 1000) {
		int y = t_to_y(m, t_max), x;
		for (x = PLOT_X; x < PLOT_X + PLOT_W; x += 4) {
			fill_rect(g, x, y, 2, 1, &DIM);
		}
	}
	for (m = 1; m < 4; m++) {
		fill_rect(g, PLOT_X + PLOT_W * m / 4 - 1, PLOT_Y + PLOT_H - 4, 2, 4, &GRAY);
	}
	plot_series(g, h, h->bed_target, t_max, 2, 1, &BLUE);
	plot_series(g, h, h->nozzle_target, t_max, 2, 1, &RED);
	plot_series(g, h, h->bed, t_max, 3, 0, &BLUE);
	plot_series(g, h, h->nozzle, t_max, 3, 0, &RED);

	/* legend: current values in the series colours, the scale's top at the right */
	if (st->valid) {
		snprintf(text, sizeof text, "Nozzle %.0f\xC2\xB0", st->nozzle);
	} else {
		snprintf(text, sizeof text, "Nozzle --");
	}
	text_color(g, 0, PLOT_X + 2, LEGEND_Y, text, &RED_T);
	m = PLOT_X + 2 + (int)overlay_text_width(0, text) + 16;
	if (st->valid) {
		snprintf(text, sizeof text, "Bed %.0f\xC2\xB0", st->bed);
	} else {
		snprintf(text, sizeof text, "Bed --");
	}
	text_color(g, 0, m, LEGEND_Y, text, &BLUE_T);
	snprintf(text, sizeof text, "%d\xC2\xB0", t_max / 10);
	text_color(g, 0, PLOT_X + PLOT_W - 2 - (int)overlay_text_width(0, text), LEGEND_Y, text, &LABEL);

	/* --- progress bar --- */
	fill_rect(g, BAR_X, BAR_Y, BAR_W, 2, &GRAY);
	fill_rect(g, BAR_X, BAR_Y + BAR_H - 2, BAR_W, 2, &GRAY);
	fill_rect(g, BAR_X, BAR_Y, 2, BAR_H, &GRAY);
	fill_rect(g, BAR_X + BAR_W - 2, BAR_Y, 2, BAR_H, &GRAY);
	if (!st->valid) {
		overlay_text(1, g->luma, g->mask, GRAPH_W, GRAPH_W, BAR_X + 6, TEXT_Y, "No Moonraker");
		return;
	}
	printing = !strcmp(st->state, "printing") || !strcmp(st->state, "paused");
	done = !strcmp(st->state, "complete");
	fill_w = (int)(st->progress * (BAR_W - 4) + 0.5);
	if (fill_w > BAR_W - 4) fill_w = BAR_W - 4;
	if (fill_w > 0 && (printing || done)) {
		fill_rect(g, BAR_X + 2, BAR_Y + 2, fill_w, BAR_H - 4, &GREEN);
	}
	/* left: the percentage while it means something, else the state */
	if (printing || done) {
		snprintf(text, sizeof text, "%3.0f%%", st->progress * 100.0);
	} else if (!strcmp(st->state, "cancelled")) {
		snprintf(text, sizeof text, "Cancelled");
	} else if (!strcmp(st->state, "error")) {
		snprintf(text, sizeof text, "Error");
	} else {
		snprintf(text, sizeof text, "Idle");
	}
	overlay_text(1, g->luma, g->mask, GRAPH_W, GRAPH_W, BAR_X + 6, TEXT_Y, text);
	/* right: remaining time, Paused or Done */
	text[0] = 0;
	if (!strcmp(st->state, "paused")) {
		snprintf(text, sizeof text, "Paused");
	} else if (printing && st->progress > 0.01 && st->print_duration > 60) {
		long left = (long)(st->print_duration * (1.0 - st->progress) / st->progress);
		if (left >= 3600) {
			snprintf(text, sizeof text, "%ldh%02ldm left", left / 3600, (left / 60) % 60);
		} else {
			snprintf(text, sizeof text, "%ldm left", left / 60);
		}
	} else if (done) {
		snprintf(text, sizeof text, "Done");
	}
	if (text[0]) {
		unsigned w = overlay_text_width(1, text);
		overlay_text(1, g->luma, g->mask, GRAPH_W, GRAPH_W, BAR_X + BAR_W - 6 - w, TEXT_Y, text);
	}
}

/* ------------------------------------------------------------------ */
/* statistics panel                                                    */

/* Five rows of 12x24 text in two columns: a grey label and its value in
 * white, or in orange when it is worth a look (board from 70 degrees, CPU
 * from 90 %, memory from 85 %, Wi-Fi from -80 dBm down). The longest pair,
 * "Speed 800mm/s", ends 14 px before the second column. */
#define STAT_ROWS 5
#define STAT_Y0 4
#define STAT_COL0 2
#define STAT_COL1 (GRAPH_W / 2 + 8)
#define STAT_GAP 8           /* between a label and its value */

static void stat(struct graph *g, int row, int col, const char *label, const char *value,
                 const struct color *c)
{
	int x = col ? STAT_COL1 : STAT_COL0, y = STAT_Y0 + row * 24;
	text_color(g, 0, x, y, label, &LABEL);
	text_color(g, 0, x + (int)overlay_text_width(0, label) + STAT_GAP, y, value, c);
}

void stats_render(struct graph *g, const struct printer_state *st, const struct sys_stats *sys,
                  double kbit)
{
	char v[32];
	int ok = st->valid;

	memset(g->luma, 0, sizeof g->luma);
	memset(g->mask, 0, sizeof g->mask);
	memset(g->uv, 128, sizeof g->uv);
	memset(g->uvmask, 0, sizeof g->uvmask);

	/* row 0: the temperatures the graph does not show */
	if (ok && st->have_chamber) snprintf(v, sizeof v, "%.0f\xC2\xB0", st->chamber); else snprintf(v, sizeof v, "--");
	stat(g, 0, 0, "Chamber", v, &WHITE);
	if (ok && st->have_mcu_temp) snprintf(v, sizeof v, "%.0f\xC2\xB0", st->mcu_temp); else snprintf(v, sizeof v, "--");
	stat(g, 0, 1, "Board", v, ok && st->have_mcu_temp && st->mcu_temp >= 70 ? &WARN : &WHITE);

	/* row 1: how fast the head moves and how much plastic it lays down */
	if (ok && st->have_motion) snprintf(v, sizeof v, "%.0fmm/s", st->speed); else snprintf(v, sizeof v, "--");
	stat(g, 1, 0, "Speed", v, &WHITE);
	if (ok && st->have_motion) snprintf(v, sizeof v, "%.0fmm3/s", st->flow); else snprintf(v, sizeof v, "--");
	stat(g, 1, 1, "Flow", v, &WHITE);

	/* row 2: height and part cooling */
	if (ok && st->have_motion) snprintf(v, sizeof v, "%.2fmm", st->z); else snprintf(v, sizeof v, "--");
	stat(g, 2, 0, "Z", v, &WHITE);
	if (ok && st->have_fan) snprintf(v, sizeof v, "%.0f%%", st->fan * 100.0); else snprintf(v, sizeof v, "--");
	stat(g, 2, 1, "Fan", v, &WHITE);

	/* row 3: the printer's computer */
	if (sys->cpu_pct >= 0) snprintf(v, sizeof v, "%d%%", sys->cpu_pct); else snprintf(v, sizeof v, "--");
	stat(g, 3, 0, "CPU", v, sys->cpu_pct >= 90 ? &WARN : &WHITE);
	if (sys->mem_total_mb) snprintf(v, sizeof v, "%d/%dM", sys->mem_used_mb, sys->mem_total_mb); else snprintf(v, sizeof v, "--");
	stat(g, 3, 1, "RAM", v, sys->mem_total_mb && sys->mem_used_mb * 100 >= sys->mem_total_mb * 85 ? &WARN : &WHITE);

	/* row 4: the link the stream leaves through */
	if (sys->wifi_dbm) snprintf(v, sizeof v, "%ddBm", sys->wifi_dbm); else snprintf(v, sizeof v, "--");
	stat(g, 4, 0, "Wi-Fi", v, sys->wifi_dbm && sys->wifi_dbm <= -80 ? &WARN : &WHITE);
	if (kbit > 0) snprintf(v, sizeof v, "%.1fMbit", kbit / 1000.0); else snprintf(v, sizeof v, "--");
	stat(g, 4, 1, "Out", v, &WHITE);
}

/* ------------------------------------------------------------------ */
/* into the frame                                                      */

void graph_blit(struct graph *g, unsigned buf, int fresh, uint8_t *y, uint8_t *uv)
{
	uint8_t *bgl, *bgc;
	unsigned r, c;

	if (buf >= GRAPH_BUFS) {
		buf = 0;
	}
	bgl = g->bg_luma[buf];
	bgc = g->bg_uv[buf];
	/* The frame is uncached DMA memory: whole rows are read into the cached
	 * background copy once per decoded picture, and written back whole. */
	for (r = 0; r < GRAPH_H; r++) {
		uint8_t *frame = y + (size_t)(g->y0 + r) * g->stride + g->x0;
		uint8_t *bg = bgl + r * GRAPH_W;
		const uint8_t *pl = g->luma + r * GRAPH_W;
		const uint8_t *pm = g->mask + r * GRAPH_W;
		uint8_t row[GRAPH_W];
		if (fresh) {
			memcpy(row, frame, GRAPH_W);
			for (c = 0; c < GRAPH_W; c++) {
				bg[c] = g->dark[row[c]];
			}
		}
		for (c = 0; c < GRAPH_W; c++) {
			row[c] = pm[c] ? pl[c] : bg[c];
		}
		memcpy(frame, row, GRAPH_W);
	}
	for (r = 0; r < GRAPH_H / 2; r++) {
		uint8_t *frame = uv + (size_t)(g->y0 / 2 + r) * g->stride + g->x0;
		uint8_t *bg = bgc + r * GRAPH_W;
		const uint8_t *pc = g->uv + r * GRAPH_W;
		const uint8_t *pm = g->uvmask + r * (GRAPH_W / 2);
		uint8_t row[GRAPH_W];
		if (fresh) {
			memcpy(row, frame, GRAPH_W);
			for (c = 0; c < GRAPH_W; c++) {
				bg[c] = (uint8_t)(128 + (((int)row[c] - 128) * 5) / 16);
			}
		}
		for (c = 0; c < GRAPH_W / 2; c++) {
			if (pm[c]) {
				row[2 * c] = pc[2 * c];
				row[2 * c + 1] = pc[2 * c + 1];
			} else {
				row[2 * c] = bg[2 * c];
				row[2 * c + 1] = bg[2 * c + 1];
			}
		}
		memcpy(frame, row, GRAPH_W);
	}
}
