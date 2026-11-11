/* k1os-stream: Helix V4L2 M2M plumbing. MIT License, part of Datel OS. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <linux/videodev2.h>

#include "helix.h"

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;
	do {
		r = ioctl(fd, req, arg);
	} while (r < 0 && errno == EINTR);
	return r;
}

static void fourcc_str(uint32_t f, char s[5])
{
	s[0] = f & 0xff; s[1] = (f >> 8) & 0xff; s[2] = (f >> 16) & 0xff; s[3] = (f >> 24) & 0xff; s[4] = 0;
}

static int set_fmt(struct helix_m2m *m, enum v4l2_buf_type type, uint32_t fourcc)
{
	struct v4l2_format f;
	char fs[5];
	memset(&f, 0, sizeof f);
	f.type = type;
	f.fmt.pix_mp.width = m->width;
	f.fmt.pix_mp.height = m->height;
	f.fmt.pix_mp.pixelformat = fourcc;
	f.fmt.pix_mp.field = V4L2_FIELD_NONE;
	f.fmt.pix_mp.colorspace = V4L2_COLORSPACE_REC709;
	/* num_planes and sizeimage: the driver fills them in (NV12: 2 planes,
	 * compressed: 1 plane of width*height*3/4). */
	if (fourcc == V4L2_PIX_FMT_NV12) {
		f.fmt.pix_mp.num_planes = 2;
	} else {
		f.fmt.pix_mp.num_planes = 1;
	}
	if (xioctl(m->fd, VIDIOC_S_FMT, &f) < 0) {
		fourcc_str(fourcc, fs);
		fprintf(stderr, "%s: S_FMT %s %s: %s\n", m->name,
		        V4L2_TYPE_IS_OUTPUT(type) ? "output" : "capture", fs, strerror(errno));
		return -1;
	}
	if (f.fmt.pix_mp.pixelformat != fourcc) {
		fourcc_str(f.fmt.pix_mp.pixelformat, fs);
		fprintf(stderr, "%s: driver changed the format to %s\n", m->name, fs);
		return -1;
	}
	return 0;
}

static int setup_queue(struct helix_m2m *m, enum v4l2_buf_type type, struct helix_buf *bufs,
                       unsigned *nbufs, unsigned want, int dmabuf_import, int export)
{
	struct v4l2_requestbuffers rb;
	unsigned i, p;

	memset(&rb, 0, sizeof rb);
	rb.type = type;
	rb.memory = dmabuf_import ? V4L2_MEMORY_DMABUF : V4L2_MEMORY_MMAP;
	rb.count = want;
	if (xioctl(m->fd, VIDIOC_REQBUFS, &rb) < 0) {
		fprintf(stderr, "%s: REQBUFS: %s\n", m->name, strerror(errno));
		return -1;
	}
	if (rb.count == 0) {
		fprintf(stderr, "%s: REQBUFS gave no buffers\n", m->name);
		return -1;
	}
	*nbufs = rb.count > HELIX_MAX_BUFS ? HELIX_MAX_BUFS : rb.count;

	for (i = 0; i < *nbufs; i++) {
		struct v4l2_buffer b;
		struct v4l2_plane planes[HELIX_MAX_PLANES];
		memset(&b, 0, sizeof b);
		memset(planes, 0, sizeof planes);
		b.type = type;
		b.memory = rb.memory;
		b.index = i;
		b.m.planes = planes;
		b.length = HELIX_MAX_PLANES;
		if (xioctl(m->fd, VIDIOC_QUERYBUF, &b) < 0) {
			fprintf(stderr, "%s: QUERYBUF %u: %s\n", m->name, i, strerror(errno));
			return -1;
		}
		bufs[i].nplanes = b.length;
		bufs[i].queued = 0;
		for (p = 0; p < b.length; p++) {
			bufs[i].len[p] = planes[p].length;
			bufs[i].dmabuf[p] = -1;
			bufs[i].map[p] = NULL;
			if (dmabuf_import) {
				continue;
			}
			bufs[i].map[p] = mmap(NULL, planes[p].length, PROT_READ | PROT_WRITE, MAP_SHARED,
			                      m->fd, planes[p].m.mem_offset);
			if (bufs[i].map[p] == MAP_FAILED) {
				bufs[i].map[p] = NULL;
				fprintf(stderr, "%s: mmap buffer %u plane %u: %s\n", m->name, i, p, strerror(errno));
				return -1;
			}
			if (export) {
				struct v4l2_exportbuffer eb;
				memset(&eb, 0, sizeof eb);
				eb.type = type;
				eb.index = i;
				eb.plane = p;
				eb.flags = O_RDWR;
				if (xioctl(m->fd, VIDIOC_EXPBUF, &eb) < 0) {
					fprintf(stderr, "%s: EXPBUF %u/%u: %s\n", m->name, i, p, strerror(errno));
					return -1;
				}
				bufs[i].dmabuf[p] = eb.fd;
			}
		}
	}
	return 0;
}

int helix_open(struct helix_m2m *m, const char *dev, const char *name,
               uint32_t out_fourcc, uint32_t cap_fourcc,
               unsigned width, unsigned height, unsigned nbufs, int out_dmabuf)
{
	struct v4l2_capability cap;

	unsigned i, p;

	memset(m, 0, sizeof *m);
	for (i = 0; i < HELIX_MAX_BUFS; i++) {
		for (p = 0; p < HELIX_MAX_PLANES; p++) {
			m->out[i].dmabuf[p] = m->cap[i].dmabuf[p] = -1;
		}
	}
	m->name = name;
	m->width = width;
	m->height = height;
	m->out_fourcc = out_fourcc;
	m->cap_fourcc = cap_fourcc;
	m->out_dmabuf = out_dmabuf;
	m->fd = open(dev, O_RDWR | O_CLOEXEC);
	if (m->fd < 0) {
		fprintf(stderr, "%s: open %s: %s\n", name, dev, strerror(errno));
		return -1;
	}
	if (xioctl(m->fd, VIDIOC_QUERYCAP, &cap) < 0 ||
	    !(cap.device_caps & V4L2_CAP_VIDEO_M2M_MPLANE)) {
		fprintf(stderr, "%s: %s is not a multi-planar M2M device\n", name, dev);
		goto fail;
	}
	/* The driver picks its codec from the formats: JPEG on OUTPUT = decoder,
	 * H264 on CAPTURE = encoder. OUTPUT first, so that a JPEG decoder's
	 * capture format is set after jpeg_decoder_init(). */
	if (set_fmt(m, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, out_fourcc) < 0) {
		goto fail;
	}
	if (set_fmt(m, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, cap_fourcc) < 0) {
		goto fail;
	}
	if (setup_queue(m, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, m->out, &m->out_nbufs, nbufs, out_dmabuf, 0) < 0) {
		if (!out_dmabuf) {
			goto fail;
		}
		fprintf(stderr, "%s: no DMABUF import, frames will be copied\n", name);
		m->out_dmabuf = 0;
		if (setup_queue(m, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, m->out, &m->out_nbufs, nbufs, 0, 0) < 0) {
			goto fail;
		}
	}
	if (setup_queue(m, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, m->cap, &m->cap_nbufs, nbufs, 0,
	                cap_fourcc == V4L2_PIX_FMT_NV12) < 0) {
		goto fail;
	}
	return 0;
fail:
	/* nothing stays open after a failure */
	helix_close(m);
	return -1;
}

static int free_queue(struct helix_m2m *m, enum v4l2_buf_type type)
{
	struct v4l2_requestbuffers rb;
	memset(&rb, 0, sizeof rb);
	rb.type = type;
	rb.memory = m->out_dmabuf ? V4L2_MEMORY_DMABUF : V4L2_MEMORY_MMAP;
	rb.count = 0;
	return xioctl(m->fd, VIDIOC_REQBUFS, &rb);
}

int helix_probe_dmabuf(struct helix_m2m *m, const struct helix_m2m *src)
{
	unsigned nbufs = m->out_nbufs;
	int ok;

	if (!m->out_dmabuf) {
		return 0;
	}
	/* vb2 attaches and maps the DMABUF at QBUF, so a queued-before-streaming
	 * buffer tells whether the import works. The queue is then recreated
	 * so that nothing stays queued. */
	ok = helix_queue_output_dmabuf(m, 0, src, 0, 0) == 0;
	free_queue(m, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE);
	if (!ok) {
		fprintf(stderr, "%s: DMABUF import refused, frames will be copied\n", m->name);
		m->out_dmabuf = 0;
	}
	if (setup_queue(m, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, m->out, &m->out_nbufs, nbufs, m->out_dmabuf, 0) < 0) {
		return -1;
	}
	return 0;
}

int helix_stream_on(struct helix_m2m *m)
{
	enum v4l2_buf_type t;
	t = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	if (xioctl(m->fd, VIDIOC_STREAMON, &t) < 0) {
		fprintf(stderr, "%s: STREAMON output: %s\n", m->name, strerror(errno));
		return -1;
	}
	t = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	if (xioctl(m->fd, VIDIOC_STREAMON, &t) < 0) {
		fprintf(stderr, "%s: STREAMON capture: %s\n", m->name, strerror(errno));
		return -1;
	}
	m->streaming = 1;
	return 0;
}

void helix_close(struct helix_m2m *m)
{
	unsigned i, p;
	if (m->fd < 0) {
		return;
	}
	if (m->streaming) {
		enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
		xioctl(m->fd, VIDIOC_STREAMOFF, &t);
		t = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		xioctl(m->fd, VIDIOC_STREAMOFF, &t);
	}
	for (i = 0; i < HELIX_MAX_BUFS; i++) {
		for (p = 0; p < HELIX_MAX_PLANES; p++) {
			if (m->out[i].map[p]) {
				munmap(m->out[i].map[p], m->out[i].len[p]);
			}
			if (m->cap[i].map[p]) {
				munmap(m->cap[i].map[p], m->cap[i].len[p]);
			}
			if (m->cap[i].dmabuf[p] >= 0) {
				close(m->cap[i].dmabuf[p]);
			}
		}
	}
	close(m->fd);
	m->fd = -1;
}

int helix_set_ctrl(struct helix_m2m *m, uint32_t id, int32_t value)
{
	struct v4l2_control c;
	/* The control framework only calls the driver when the value differs
	 * from its cache, and the driver's own defaults are not what the cache
	 * says after S_FMT; a write of a neighbouring value first makes the
	 * real one reach the driver. */
	c.id = id;
	c.value = value ^ 1;
	xioctl(m->fd, VIDIOC_S_CTRL, &c);
	c.id = id;
	c.value = value;
	if (xioctl(m->fd, VIDIOC_S_CTRL, &c) < 0) {
		fprintf(stderr, "%s: S_CTRL 0x%08x = %d: %s\n", m->name, id, value, strerror(errno));
		return -1;
	}
	return 0;
}

static int qbuf(struct helix_m2m *m, enum v4l2_buf_type type, struct helix_buf *bufs,
                unsigned idx, const size_t *used, const int *fds, uint32_t flags)
{
	struct v4l2_buffer b;
	struct v4l2_plane planes[HELIX_MAX_PLANES];
	unsigned p;

	memset(&b, 0, sizeof b);
	memset(planes, 0, sizeof planes);
	b.type = type;
	b.index = idx;
	b.memory = fds ? V4L2_MEMORY_DMABUF : V4L2_MEMORY_MMAP;
	b.m.planes = planes;
	b.length = bufs[idx].nplanes;
	b.flags = flags;
	b.field = V4L2_FIELD_NONE;
	for (p = 0; p < bufs[idx].nplanes; p++) {
		if (fds) {
			planes[p].m.fd = fds[p];
			planes[p].length = bufs[idx].len[p];
		}
		if (used) {
			planes[p].bytesused = used[p];
		}
	}
	if (xioctl(m->fd, VIDIOC_QBUF, &b) < 0) {
		fprintf(stderr, "%s: QBUF %s %u: %s\n", m->name,
		        V4L2_TYPE_IS_OUTPUT(type) ? "output" : "capture", idx, strerror(errno));
		return -1;
	}
	bufs[idx].queued = 1;
	return 0;
}

int helix_queue_output(struct helix_m2m *m, unsigned idx, size_t used, uint32_t flags)
{
	size_t u[HELIX_MAX_PLANES] = { used, m->out[idx].len[1], m->out[idx].len[2] };
	return qbuf(m, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, m->out, idx, u, NULL, flags);
}

int helix_queue_output_dmabuf(struct helix_m2m *m, unsigned idx,
                              const struct helix_m2m *src, unsigned src_idx, uint32_t flags)
{
	size_t u[HELIX_MAX_PLANES];
	int fds[HELIX_MAX_PLANES];
	unsigned p;
	for (p = 0; p < HELIX_MAX_PLANES; p++) {
		u[p] = src->cap[src_idx].len[p];
		fds[p] = src->cap[src_idx].dmabuf[p];
		/* the importing queue has its own plane sizes from S_FMT; keep them */
		if (p < m->out[idx].nplanes && m->out[idx].len[p] && m->out[idx].len[p] < u[p]) {
			u[p] = m->out[idx].len[p];
		}
	}
	return qbuf(m, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, m->out, idx, u, fds, flags);
}

int helix_queue_capture(struct helix_m2m *m, unsigned idx)
{
	return qbuf(m, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, m->cap, idx, NULL, NULL, 0);
}

static int dqbuf(struct helix_m2m *m, enum v4l2_buf_type type, struct helix_buf *bufs,
                 unsigned *idx, size_t *used, uint32_t *flags)
{
	struct v4l2_buffer b;
	struct v4l2_plane planes[HELIX_MAX_PLANES];

	memset(&b, 0, sizeof b);
	memset(planes, 0, sizeof planes);
	b.type = type;
	b.memory = (V4L2_TYPE_IS_OUTPUT(type) && m->out_dmabuf) ? V4L2_MEMORY_DMABUF : V4L2_MEMORY_MMAP;
	b.m.planes = planes;
	b.length = HELIX_MAX_PLANES;
	if (xioctl(m->fd, VIDIOC_DQBUF, &b) < 0) {
		if (errno == EAGAIN) {
			return 0;
		}
		fprintf(stderr, "%s: DQBUF %s: %s\n", m->name,
		        V4L2_TYPE_IS_OUTPUT(type) ? "output" : "capture", strerror(errno));
		return -1;
	}
	bufs[b.index].queued = 0;
	*idx = b.index;
	if (used) {
		*used = planes[0].bytesused;
	}
	if (flags) {
		*flags = b.flags;
		/* the JPEG decoder reports the picture size it found as
		 * width << 16 | height in reserved; a mismatch is an error */
		if (m->cap_fourcc == V4L2_PIX_FMT_NV12 && b.reserved &&
		    ((b.reserved >> 16) != m->width || (b.reserved & 0xffff) != m->height)) {
			fprintf(stderr, "%s: decoded picture is %ux%u, expected %ux%u\n", m->name,
			        b.reserved >> 16, b.reserved & 0xffff, m->width, m->height);
			*flags |= V4L2_BUF_FLAG_ERROR;
		}
	}
	return 1;
}

int helix_dequeue(struct helix_m2m *m, unsigned *out_idx, unsigned *cap_idx,
                  size_t *cap_used, uint32_t *cap_flags, int timeout_ms)
{
	int have_out = 0, have_cap = 0;
	struct pollfd pfd;

	while (!have_out || !have_cap) {
		int r;
		pfd.fd = m->fd;
		pfd.events = (have_out ? 0 : POLLOUT) | (have_cap ? 0 : POLLIN);
		pfd.revents = 0;
		r = poll(&pfd, 1, timeout_ms);
		if (r < 0) {
			if (errno == EINTR) {
				continue;
			}
			fprintf(stderr, "%s: poll: %s\n", m->name, strerror(errno));
			return -1;
		}
		if (r == 0) {
			fprintf(stderr, "%s: the codec did not finish within %d ms\n", m->name, timeout_ms);
			return -1;
		}
		if (pfd.revents & POLLERR) {
			fprintf(stderr, "%s: poll reports an error on the device\n", m->name);
			return -1;
		}
		if (!have_out && (pfd.revents & POLLOUT)) {
			r = dqbuf(m, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, m->out, out_idx, NULL, NULL);
			if (r < 0) {
				return -1;
			}
			have_out = r;
		}
		if (!have_cap && (pfd.revents & POLLIN)) {
			r = dqbuf(m, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, m->cap, cap_idx, cap_used, cap_flags);
			if (r < 0) {
				return -1;
			}
			have_cap = r;
		}
	}
	return 0;
}
