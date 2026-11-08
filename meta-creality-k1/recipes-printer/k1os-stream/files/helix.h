/* k1os-stream: the X2000 Helix video codec through its V4L2 M2M driver
 * (helix-venc, /dev/video1). Two instances are used: one JPEG decoder
 * (JPEG -> NV12) and one H.264 encoder (NV12 -> H.264). The decoder's
 * NV12 buffers are exported as DMABUFs and imported into the encoder, so
 * a frame is never copied; the overlay is drawn into the mapped buffer.
 *
 * MIT License, part of Datel OS. */
#ifndef HELIX_H
#define HELIX_H

#include <stddef.h>
#include <stdint.h>

#define HELIX_MAX_BUFS 3
#define HELIX_MAX_PLANES 3

struct helix_buf {
	void *map[HELIX_MAX_PLANES];
	size_t len[HELIX_MAX_PLANES];
	int dmabuf[HELIX_MAX_PLANES];   /* exported fd, -1 if not exported */
	unsigned nplanes;
	int queued;
};

struct helix_m2m {
	int fd;
	const char *name;
	unsigned width, height;
	uint32_t out_fourcc, cap_fourcc;
	unsigned out_nbufs, cap_nbufs;
	int out_dmabuf;                 /* OUTPUT queue imports DMABUFs */
	struct helix_buf out[HELIX_MAX_BUFS], cap[HELIX_MAX_BUFS];
	int streaming;
};

/* Open the device and configure the formats; buffers are mapped and the
 * capture planes exported. out_dmabuf: OUTPUT buffers are imported from
 * another instance later (helix_queue_output_dmabuf), not allocated. */
int helix_open(struct helix_m2m *m, const char *dev, const char *name,
               uint32_t out_fourcc, uint32_t cap_fourcc,
               unsigned width, unsigned height, unsigned nbufs, int out_dmabuf);
/* Before streaming: check that OUTPUT buffers can be imported from src's
 * capture buffers; falls back to mapped buffers (out_dmabuf = 0). */
int helix_probe_dmabuf(struct helix_m2m *m, const struct helix_m2m *src);
int helix_stream_on(struct helix_m2m *m);
void helix_close(struct helix_m2m *m);

int helix_set_ctrl(struct helix_m2m *m, uint32_t id, int32_t value);

/* Queue OUTPUT buffer idx with `used` bytes in plane 0 (data already in the
 * mapped buffer); flags are V4L2_BUF_FLAG_* (e.g. KEYFRAME). */
int helix_queue_output(struct helix_m2m *m, unsigned idx, size_t used, uint32_t flags);
/* Queue OUTPUT buffer idx backed by the planes of src->cap[src_idx]. */
int helix_queue_output_dmabuf(struct helix_m2m *m, unsigned idx,
                              const struct helix_m2m *src, unsigned src_idx, uint32_t flags);
int helix_queue_capture(struct helix_m2m *m, unsigned idx);
/* Wait for both queues to return a buffer; *cap_used is plane 0 bytesused of
 * the capture buffer, *cap_flags its flags. timeout in ms. */
int helix_dequeue(struct helix_m2m *m, unsigned *out_idx, unsigned *cap_idx,
                  size_t *cap_used, uint32_t *cap_flags, int timeout_ms);

#endif
