/* k1os-stream: graph panel (temperature history, progress bar) drawn into an
 * NV12 frame. MIT License, part of Datel OS. */
#ifndef K1OS_GRAPH_H
#define K1OS_GRAPH_H

#include <stdint.h>

#include "moonraker.h"
#include "sysstat.h"

#define GRAPH_W 320
#define GRAPH_H 128
#define GRAPH_BUFS 2            /* decoder NV12 buffers the panel may land in */

enum graph_corner { GRAPH_TL, GRAPH_TR, GRAPH_BL, GRAPH_BR };

struct graph {
	unsigned x0, y0;            /* panel position in the frame, even */
	unsigned stride;            /* frame width */
	/* the panel, rendered once a second: opaque pixels have mask 1, the
	 * rest shows the darkened camera picture */
	uint8_t luma[GRAPH_W * GRAPH_H];
	uint8_t mask[GRAPH_W * GRAPH_H];
	uint8_t uv[GRAPH_W * GRAPH_H / 2];          /* interleaved U V, GRAPH_W bytes a row */
	uint8_t uvmask[GRAPH_W / 2 * GRAPH_H / 2];
	/* the darkened picture under the panel, kept per frame buffer so that
	 * a repeated frame is not darkened twice and never read again */
	uint8_t bg_luma[GRAPH_BUFS][GRAPH_W * GRAPH_H];
	uint8_t bg_uv[GRAPH_BUFS][GRAPH_W * GRAPH_H / 2];
	uint8_t dark[256];          /* darkening of the picture under the panel */
};

/* Place the panel in a corner of a width x height frame, above a bottom
 * bar of bar_h rows. Returns -1 when the frame is too small. */
int graph_init(struct graph *g, unsigned width, unsigned height, unsigned bar_h,
               enum graph_corner corner);
/* Place a second panel of the same size next to `other`: under it, or above
 * it when there is no room below (bottom corners). Returns -1 when neither fits. */
int graph_init_beside(struct graph *g, const struct graph *other, unsigned height, unsigned bar_h);
/* Render the statistics panel: temperatures the graph does not show, speed
 * and flow, Z and fan, the printer's CPU and memory, Wi-Fi and the stream's
 * bitrate (kbit <= 0: not known yet). Once a second. */
void stats_render(struct graph *g, const struct printer_state *st, const struct sys_stats *sys,
                  double kbit);
/* Render the panel from the latest state and history (once a second). */
void graph_render(struct graph *g, const struct printer_state *st, const struct temp_history *h);
/* Compose the panel into frame buffer `buf` (0..GRAPH_BUFS-1): y and uv are
 * its planes. fresh = 1 when the buffer holds a newly decoded picture (its
 * panel region is read and darkened), 0 when the frame repeats. */
void graph_blit(struct graph *g, unsigned buf, int fresh, uint8_t *y, uint8_t *uv);

#endif
