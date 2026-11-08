/*
 * k1os-helix-enc: JPEG frames to H.264 through the Ingenic X2000 Helix codec.
 *
 * The Helix block sits behind one V4L2 memory-to-memory node (driver
 * helix-venc, /dev/video1 on the K1). It encodes NV12 to H.264 and can also
 * decode baseline JPEG to NV12, one job at a time. This tool turns every
 * input JPEG (the camera's MJPEG snapshots) into NV12, pushes the frame
 * through the encoder and appends the Annex B access unit to the output file.
 *
 * The JPEG decode runs in software by default (libjpeg-turbo, about 35 ms a
 * 720p frame on the K1; the CPU is idle anyway while a timelapse renders).
 * -H uses the Helix JPEG decoder instead: on the first attempt (8 November
 * 2026) its first job stopped the whole SoC until a power cycle, so it is
 * kept as an experiment behind a flag.
 *
 * Driver quirks this code works around (helix_ops.c, h264e_rc.c):
 *  - S_FMT on the capture queue with H264 resets every encoder parameter to
 *    the driver's defaults (baseline, level 1.0, QP 30, GOP 50), so the
 *    controls are written after it. The control framework skips a write
 *    whose value equals the cached one, so each control is written twice.
 *  - The JPEG decoder parses the header in the kernel and reports the
 *    picture size in buf.reserved (width << 16 | height) of the dequeued
 *    capture buffer; the NV12 capture format must already have that size.
 *  - With CONFIG_INGENIC_HELIX_H264E_RC_NONE every frame uses the fixed QP
 *    of the I/P frame QP controls; SPS and PPS are inserted before every
 *    IDR frame by the driver (module parameter add_sps_pps_iframe=1).
 *  - The encoder's bitstream buffer is at most width*height*3/4 bytes and
 *    the driver aborts if a frame grows past it, so very low QPs are refused.
 *
 * Usage: k1os-helix-enc [-d /dev/video1] [-q qp] [-g gop] [-a] [-H] [-D] -o out.h264 frame.jpg...
 *        a single "-" as the file list reads the names from stdin;
 *        -H decodes the JPEGs on the Helix instead of in software;
 *        -D decodes only and writes the raw NV12 frames (decoder check).
 *
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <unistd.h>
#include <linux/videodev2.h>
#include <setjmp.h>
#include <jpeglib.h>

#define MAX_PLANES 3
#define JOB_TIMEOUT_MS 10000

struct plane {
	void *map;
	size_t len;
};

struct ctx {
	const char *name;
	int fd;
	struct plane out[MAX_PLANES];
	unsigned out_n;
	struct plane cap[MAX_PLANES];
	unsigned cap_n;
};

static int verbose;
static int decode_only;
static int sw_decode = 1;
static const char *device = "/dev/video1";

static void msg(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fputs("k1os-helix-enc: ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	fflush(stderr);
	fsync(fileno(stderr));
}

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;
	do {
		r = ioctl(fd, req, arg);
	} while (r < 0 && errno == EINTR);
	return r;
}

static double now_ms(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

/* Picture size from the SOF marker. 0 baseline, 1 progressive, -1 no SOF. */
static int jpeg_size(const uint8_t *d, size_t n, unsigned *w, unsigned *h)
{
	size_t i = 2;

	if (n < 4 || d[0] != 0xFF || d[1] != 0xD8)
		return -1;
	while (i + 4 <= n) {
		uint8_t m;
		size_t len;

		if (d[i] != 0xFF) {
			i++;
			continue;
		}
		m = d[i + 1];
		if (m == 0xFF) {
			i++;
			continue;
		}
		if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) {
			i += 2;
			continue;
		}
		len = ((size_t)d[i + 2] << 8) | d[i + 3];
		if (m == 0xC0 || m == 0xC1 || m == 0xC2) {
			if (i + 9 > n)
				return -1;
			*h = (d[i + 5] << 8) | d[i + 6];
			*w = (d[i + 7] << 8) | d[i + 8];
			return m == 0xC2 ? 1 : 0;
		}
		if (m == 0xDA || m == 0xD9)
			return -1;
		i += 2 + len;
	}
	return -1;
}

static int set_fmt(struct ctx *c, enum v4l2_buf_type type, uint32_t fourcc,
		   unsigned w, unsigned h, uint32_t sizeimage0)
{
	struct v4l2_format f;

	memset(&f, 0, sizeof(f));
	f.type = type;
	f.fmt.pix_mp.width = w;
	f.fmt.pix_mp.height = h;
	f.fmt.pix_mp.pixelformat = fourcc;
	f.fmt.pix_mp.field = V4L2_FIELD_NONE;
	f.fmt.pix_mp.num_planes = 1;
	f.fmt.pix_mp.plane_fmt[0].sizeimage = sizeimage0;
	if (xioctl(c->fd, VIDIOC_S_FMT, &f) < 0) {
		msg("%s: S_FMT %c%c%c%c: %s", c->name, fourcc & 0xff, (fourcc >> 8) & 0xff,
		    (fourcc >> 16) & 0xff, fourcc >> 24, strerror(errno));
		return -1;
	}
	if (f.fmt.pix_mp.pixelformat != fourcc || f.fmt.pix_mp.width != w ||
	    f.fmt.pix_mp.height != h) {
		msg("%s: driver changed the format to %c%c%c%c %ux%u", c->name,
		    f.fmt.pix_mp.pixelformat & 0xff, (f.fmt.pix_mp.pixelformat >> 8) & 0xff,
		    (f.fmt.pix_mp.pixelformat >> 16) & 0xff, f.fmt.pix_mp.pixelformat >> 24,
		    f.fmt.pix_mp.width, f.fmt.pix_mp.height);
		return -1;
	}
	if (verbose) {
		unsigned i;
		for (i = 0; i < f.fmt.pix_mp.num_planes; i++)
			msg("%s: %s plane %u: %u bytes, stride %u", c->name,
			    V4L2_TYPE_IS_OUTPUT(type) ? "out" : "cap", i,
			    f.fmt.pix_mp.plane_fmt[i].sizeimage,
			    f.fmt.pix_mp.plane_fmt[i].bytesperline);
	}
	return 0;
}

static int setup_bufs(struct ctx *c, enum v4l2_buf_type type, struct plane *pl, unsigned *np)
{
	struct v4l2_requestbuffers rb;
	struct v4l2_plane planes[MAX_PLANES];
	struct v4l2_buffer b;
	unsigned i;

	memset(&rb, 0, sizeof(rb));
	rb.count = 1;
	rb.type = type;
	rb.memory = V4L2_MEMORY_MMAP;
	if (xioctl(c->fd, VIDIOC_REQBUFS, &rb) < 0 || rb.count < 1) {
		msg("%s: REQBUFS: %s", c->name, strerror(errno));
		return -1;
	}
	memset(planes, 0, sizeof(planes));
	memset(&b, 0, sizeof(b));
	b.type = type;
	b.memory = V4L2_MEMORY_MMAP;
	b.index = 0;
	b.m.planes = planes;
	b.length = MAX_PLANES;
	if (xioctl(c->fd, VIDIOC_QUERYBUF, &b) < 0) {
		msg("%s: QUERYBUF: %s", c->name, strerror(errno));
		return -1;
	}
	*np = b.length;
	for (i = 0; i < b.length; i++) {
		pl[i].len = planes[i].length;
		pl[i].map = mmap(NULL, planes[i].length, PROT_READ | PROT_WRITE, MAP_SHARED,
				 c->fd, planes[i].m.mem_offset);
		if (pl[i].map == MAP_FAILED) {
			msg("%s: mmap plane %u: %s", c->name, i, strerror(errno));
			return -1;
		}
	}
	return 0;
}

static int streamon(struct ctx *c, enum v4l2_buf_type type)
{
	if (xioctl(c->fd, VIDIOC_STREAMON, &type) < 0) {
		msg("%s: STREAMON %d: %s", c->name, type, strerror(errno));
		return -1;
	}
	return 0;
}

static int qbuf(struct ctx *c, enum v4l2_buf_type type, unsigned n, const uint32_t *used,
		uint32_t flags)
{
	struct v4l2_plane planes[MAX_PLANES];
	struct v4l2_buffer b;
	unsigned i;

	memset(planes, 0, sizeof(planes));
	memset(&b, 0, sizeof(b));
	b.type = type;
	b.memory = V4L2_MEMORY_MMAP;
	b.index = 0;
	b.m.planes = planes;
	b.length = n;
	b.flags = flags;
	for (i = 0; i < n && used; i++)
		planes[i].bytesused = used[i];
	if (xioctl(c->fd, VIDIOC_QBUF, &b) < 0) {
		msg("%s: QBUF %s: %s", c->name, V4L2_TYPE_IS_OUTPUT(type) ? "out" : "cap",
		    strerror(errno));
		return -1;
	}
	return 0;
}

/* Wait for the job, then dequeue. Fills b and planes[]. */
static int dqbuf(struct ctx *c, enum v4l2_buf_type type, unsigned n, struct v4l2_buffer *b,
		 struct v4l2_plane *planes)
{
	struct pollfd pfd;
	int r;

	pfd.fd = c->fd;
	pfd.events = V4L2_TYPE_IS_OUTPUT(type) ? POLLOUT : POLLIN;
	r = poll(&pfd, 1, JOB_TIMEOUT_MS);
	if (r == 0) {
		msg("%s: the codec did not finish within %d ms", c->name, JOB_TIMEOUT_MS);
		return -1;
	}
	if (r < 0) {
		msg("%s: poll: %s", c->name, strerror(errno));
		return -1;
	}
	memset(planes, 0, sizeof(*planes) * MAX_PLANES);
	memset(b, 0, sizeof(*b));
	b->type = type;
	b->memory = V4L2_MEMORY_MMAP;
	b->m.planes = planes;
	b->length = n;
	if (xioctl(c->fd, VIDIOC_DQBUF, b) < 0) {
		msg("%s: DQBUF %s: %s", c->name, V4L2_TYPE_IS_OUTPUT(type) ? "out" : "cap",
		    strerror(errno));
		return -1;
	}
	return 0;
}

static int set_ctrl(struct ctx *c, uint32_t id, int32_t val, const char *what)
{
	struct v4l2_control ctl;

	/* The control framework only calls the driver when the value changes;
	 * the encoder parameters were reset behind its back by S_FMT. */
	ctl.id = id;
	ctl.value = val ^ 1;
	xioctl(c->fd, VIDIOC_S_CTRL, &ctl);
	ctl.id = id;
	ctl.value = val;
	if (xioctl(c->fd, VIDIOC_S_CTRL, &ctl) < 0) {
		msg("%s: set %s = %d: %s", c->name, what, val, strerror(errno));
		return -1;
	}
	return 0;
}

static int open_ctx(struct ctx *c, const char *name)
{
	struct v4l2_capability cap;

	c->name = name;
	c->fd = open(device, O_RDWR);
	if (c->fd < 0) {
		msg("%s: %s", device, strerror(errno));
		return -1;
	}
	memset(&cap, 0, sizeof(cap));
	if (xioctl(c->fd, VIDIOC_QUERYCAP, &cap) < 0) {
		msg("%s: QUERYCAP: %s", device, strerror(errno));
		return -1;
	}
	if (strcmp((char *)cap.driver, "helix-venc") != 0 ||
	    !(cap.device_caps & V4L2_CAP_VIDEO_M2M_MPLANE)) {
		msg("%s is '%s', not the helix-venc M2M codec", device, cap.driver);
		return -1;
	}
	return 0;
}

static void close_ctx(struct ctx *c)
{
	enum v4l2_buf_type t;
	unsigned i;

	if (c->fd < 0)
		return;
	t = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	xioctl(c->fd, VIDIOC_STREAMOFF, &t);
	t = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	xioctl(c->fd, VIDIOC_STREAMOFF, &t);
	for (i = 0; i < c->out_n; i++)
		if (c->out[i].map)
			munmap(c->out[i].map, c->out[i].len);
	for (i = 0; i < c->cap_n; i++)
		if (c->cap[i].map)
			munmap(c->cap[i].map, c->cap[i].len);
	close(c->fd);
	c->fd = -1;
}

/* Decoder: JPEG in, NV12 out. */
static int setup_decoder(struct ctx *c, unsigned w, unsigned h)
{
	if (open_ctx(c, "jpeg decoder") < 0)
		return -1;
	/* The capture format first: it only stores the size. S_FMT with JPEG on
	 * the output queue then selects the decoder. */
	if (set_fmt(c, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, V4L2_PIX_FMT_NV12, w, h, 0) < 0 ||
	    set_fmt(c, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, V4L2_PIX_FMT_JPEG, w, h, w * h * 3 / 4) < 0)
		return -1;
	if (setup_bufs(c, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, c->out, &c->out_n) < 0 ||
	    setup_bufs(c, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, c->cap, &c->cap_n) < 0)
		return -1;
	if (c->out_n != 1 || c->cap_n != 2) {
		msg("decoder: unexpected plane count out %u cap %u", c->out_n, c->cap_n);
		return -1;
	}
	if (streamon(c, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE) < 0 ||
	    streamon(c, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE) < 0)
		return -1;
	return 0;
}

/* Encoder: NV12 in, H.264 out. */
static int setup_encoder(struct ctx *c, unsigned w, unsigned h, int qp, int gop)
{
	int level = (w * h > 1280 * 720) ? V4L2_MPEG_VIDEO_H264_LEVEL_4_0
					  : V4L2_MPEG_VIDEO_H264_LEVEL_3_1;

	if (open_ctx(c, "h264 encoder") < 0)
		return -1;
	if (set_fmt(c, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, V4L2_PIX_FMT_NV12, w, h, 0) < 0 ||
	    set_fmt(c, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, V4L2_PIX_FMT_H264, w, h, w * h * 3 / 4) < 0)
		return -1;
	/* After the capture S_FMT, which reset them. */
	if (set_ctrl(c, V4L2_CID_MPEG_VIDEO_H264_PROFILE, V4L2_MPEG_VIDEO_H264_PROFILE_MAIN, "profile") < 0 ||
	    set_ctrl(c, V4L2_CID_MPEG_VIDEO_H264_LEVEL, level, "level") < 0 ||
	    set_ctrl(c, V4L2_CID_MPEG_VIDEO_H264_I_FRAME_QP, qp, "I frame QP") < 0 ||
	    set_ctrl(c, V4L2_CID_MPEG_VIDEO_H264_P_FRAME_QP, qp, "P frame QP") < 0 ||
	    set_ctrl(c, V4L2_CID_MPEG_VIDEO_GOP_SIZE, gop, "GOP size") < 0 ||
	    set_ctrl(c, V4L2_CID_MPEG_VIDEO_FRAME_RC_ENABLE, 0, "frame rate control") < 0 ||
	    set_ctrl(c, V4L2_CID_MPEG_VIDEO_MB_RC_ENABLE, 0, "macroblock rate control") < 0)
		return -1;
	if (setup_bufs(c, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, c->out, &c->out_n) < 0 ||
	    setup_bufs(c, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, c->cap, &c->cap_n) < 0)
		return -1;
	if (c->out_n != 2 || c->cap_n != 1) {
		msg("encoder: unexpected plane count out %u cap %u", c->out_n, c->cap_n);
		return -1;
	}
	if (streamon(c, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE) < 0 ||
	    streamon(c, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE) < 0)
		return -1;
	return 0;
}

/* One JPEG through the decoder; the NV12 frame is left in dec->cap. */
static int decode(struct ctx *dec, const uint8_t *jpg, size_t len, unsigned w, unsigned h)
{
	struct v4l2_buffer b;
	struct v4l2_plane planes[MAX_PLANES];
	uint32_t used[1] = { (uint32_t)len };
	unsigned rw, rh;

	if (len > dec->out[0].len) {
		msg("JPEG of %zu bytes does not fit the %zu byte bitstream buffer", len, dec->out[0].len);
		return -1;
	}
	memcpy(dec->out[0].map, jpg, len);
	if (qbuf(dec, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, 1, used, 0) < 0 ||
	    qbuf(dec, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, 2, NULL, 0) < 0)
		return -1;
	if (dqbuf(dec, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, 2, &b, planes) < 0)
		return -1;
	rw = b.reserved >> 16;
	rh = b.reserved & 0xffff;
	if (dqbuf(dec, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, 1, &b, planes) < 0)
		return -1;
	if ((b.flags & V4L2_BUF_FLAG_ERROR) || rw != w || rh != h) {
		msg("decoder returned %ux%u for a %ux%u frame%s", rw, rh, w, h,
		    (b.flags & V4L2_BUF_FLAG_ERROR) ? " with an error" : "");
		return -1;
	}
	return 0;
}

/* The NV12 frame in enc->out through the encoder; returns the access unit size. */
static ssize_t encode(struct ctx *enc, unsigned w, unsigned h, int keyframe)
{
	struct v4l2_buffer b;
	struct v4l2_plane planes[MAX_PLANES];
	uint32_t used[2] = { w * h, w * h / 2 };
	ssize_t n;

	if (qbuf(enc, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, 2, used, keyframe ? V4L2_BUF_FLAG_KEYFRAME : 0) < 0 ||
	    qbuf(enc, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, 1, NULL, 0) < 0)
		return -1;
	if (dqbuf(enc, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, 1, &b, planes) < 0)
		return -1;
	n = planes[0].bytesused;
	if (dqbuf(enc, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, 2, &b, planes) < 0)
		return -1;
	if (n <= 0 || (size_t)n > enc->cap[0].len) {
		msg("encoder returned %zd bytes", n);
		return -1;
	}
	return n;
}


/* libjpeg-turbo: baseline JPEG to NV12 on the CPU (about 40 ms at 720p). */
struct jerr {
	struct jpeg_error_mgr pub;
	jmp_buf jb;
	char text[JMSG_LENGTH_MAX];
};

static void jerr_exit(j_common_ptr ci)
{
	struct jerr *e = (struct jerr *)ci->err;
	e->pub.format_message(ci, e->text);
	longjmp(e->jb, 1);
}

static int decode_sw(const uint8_t *jpg, size_t len, unsigned w, unsigned h, uint8_t *y, uint8_t *uv)
{
	struct jpeg_decompress_struct ci;
	struct jerr err;
	JSAMPROW yrows[16], crows[8], brows[8];
	JSAMPARRAY planes[3] = { yrows, brows, crows };
	uint8_t *cb = NULL, *cr = NULL;
	unsigned row = 0;
	int ok = 0;

	ci.err = jpeg_std_error(&err.pub);
	err.pub.error_exit = jerr_exit;
	if (setjmp(err.jb)) {
		msg("libjpeg: %s", err.text);
		goto done;
	}
	jpeg_create_decompress(&ci);
	jpeg_mem_src(&ci, jpg, len);
	jpeg_read_header(&ci, TRUE);
	if (ci.image_width != w || ci.image_height != h || ci.num_components != 3 ||
	    ci.comp_info[0].h_samp_factor != 2 || ci.comp_info[0].v_samp_factor != 2 ||
	    ci.comp_info[1].h_samp_factor != 1 || ci.comp_info[1].v_samp_factor != 1 ||
	    ci.comp_info[2].h_samp_factor != 1 || ci.comp_info[2].v_samp_factor != 1) {
		msg("software decode handles only 4:2:0 YCbCr JPEGs of the stream size");
		goto done;
	}
	ci.out_color_space = JCS_YCbCr;
	ci.raw_data_out = TRUE;
	ci.dct_method = JDCT_IFAST;
	ci.do_fancy_upsampling = FALSE;
	jpeg_start_decompress(&ci);
	cb = malloc((size_t)w / 2 * 8);
	cr = malloc((size_t)w / 2 * 8);
	if (!cb || !cr)
		goto done;
	while (row < h) {
		unsigned i, n;
		for (i = 0; i < 16; i++)
			yrows[i] = y + (size_t)(row + i) * w;
		for (i = 0; i < 8; i++) {
			brows[i] = cb + (size_t)i * (w / 2);
			crows[i] = cr + (size_t)i * (w / 2);
		}
		n = jpeg_read_raw_data(&ci, planes, 16);
		if (n == 0)
			break;
		for (i = 0; i < 8; i++) {
			uint8_t *d = uv + (size_t)(row / 2 + i) * w;
			const uint8_t *b = brows[i], *r = crows[i];
			unsigned x;
			for (x = 0; x < w / 2; x++) {
				d[2 * x] = b[x];
				d[2 * x + 1] = r[x];
			}
		}
		row += n;
	}
	jpeg_finish_decompress(&ci);
	ok = row >= h;
done:
	jpeg_destroy_decompress(&ci);
	free(cb);
	free(cr);
	return ok ? 0 : -1;
}

/* Progress bar for a timelapse: frame `done` of `total`, drawn along the
 * bottom of the NV12 picture (whole rows written, nothing read: the Helix
 * decoder's buffer is uncached memory). Green fill on a dark bar. */
static void draw_progress(uint8_t *y, uint8_t *uv, unsigned w, unsigned h, int done, int total)
{
	const unsigned bar_h = 12, margin = 8;      /* even, for whole chroma rows */
	unsigned x0 = margin, x1 = w - margin, y0 = h - margin - bar_h, r;
	unsigned fill = x0 + 2 + (unsigned)((unsigned long)(x1 - x0 - 4) * (done < total ? done : total) / (total > 0 ? total : 1));

	if (w < 4 * margin || h < 4 * margin) {
		return;
	}
	for (r = 0; r < bar_h; r++) {
		uint8_t *row = y + (size_t)(y0 + r) * w;
		memset(row + x0, 20, x1 - x0);
		if (r >= 2 && r < bar_h - 2 && fill > x0 + 2) {
			memset(row + x0 + 2, 140, fill - x0 - 2);
		}
	}
	for (r = 0; r < bar_h / 2; r++) {
		uint8_t *row = uv + (size_t)(y0 / 2 + r) * w;
		unsigned x;
		memset(row + x0, 128, x1 - x0);
		if (r >= 1 && r < bar_h / 2 - 1) {
			for (x = x0 + 2; x < fill; x += 2) {
				row[x] = 96;        /* U */
				row[x + 1] = 75;    /* V: green */
			}
		}
	}
}

static uint8_t *read_file(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	uint8_t *buf = NULL;
	size_t cap = 0, n = 0;

	if (!f) {
		msg("%s: %s", path, strerror(errno));
		return NULL;
	}
	for (;;) {
		size_t r;
		if (n == cap) {
			cap = cap ? cap * 2 : 262144;
			buf = realloc(buf, cap);
			if (!buf) {
				fclose(f);
				return NULL;
			}
		}
		r = fread(buf + n, 1, cap - n, f);
		n += r;
		if (r == 0)
			break;
	}
	fclose(f);
	*len = n;
	return buf;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: k1os-helix-enc [-d device] [-q qp] [-g gop] [-p total] [-a] [-H] [-D] [-v] -o out.h264 frame.jpg...\n"
		"  -d  V4L2 M2M node of the Helix codec (default /dev/video1)\n"
		"  -q  fixed quantiser 18..51, lower is better and larger (default 28)\n"
		"  -g  frames between IDR pictures (default 30)\n"
		"  -p  draw a progress bar at the bottom: this is frame N of `total` frames\n"
		"  -a  append to the output instead of truncating it\n"
		"  -D  decode only: write the NV12 frames instead of H.264\n"
		"  -H  decode the JPEGs on the Helix instead of in software (experimental)\n"
		"  -v  verbose\n"
		"  -   read the JPEG file names from stdin, one per line\n");
}

int main(int argc, char **argv)
{
	struct ctx dec = { .fd = -1 }, enc = { .fd = -1 };
	const char *out_path = NULL;
	int qp = 28, gop = 30, append = 0, progress_total = 0, opt;
	unsigned w = 0, h = 0;
	FILE *out = NULL, *list = NULL;
	char line[4096];
	int done = 0, skipped = 0, failed = 0, rc = 1;
	long long out_bytes = 0;
	double t0, t_dec = 0, t_enc = 0;
	int argi;
	uint8_t *nv12 = NULL, *ysrc, *uvsrc;

	while ((opt = getopt(argc, argv, "d:o:q:g:p:aDHvh")) != -1) {
		switch (opt) {
		case 'd': device = optarg; break;
		case 'o': out_path = optarg; break;
		case 'q': qp = atoi(optarg); break;
		case 'g': gop = atoi(optarg); break;
		case 'p': progress_total = atoi(optarg); break;
		case 'a': append = 1; break;
		case 'D': decode_only = 1; break;
		case 'H': sw_decode = 0; break;
		case 'v': verbose = 1; break;
		default: usage(); return 2;
		}
	}
	if (!out_path || optind >= argc) {
		usage();
		return 2;
	}
	if (qp < 18 || qp > 51) {
		msg("QP %d out of range 18..51 (below 18 a frame can outgrow the codec's bitstream buffer)", qp);
		return 2;
	}
	if (gop < 1 || gop > 120) {
		msg("GOP %d out of range 1..120", gop);
		return 2;
	}
	if (strcmp(argv[optind], "-") == 0)
		list = stdin;
	argi = optind;

	out = fopen(out_path, append ? "ab" : "wb");
	if (!out) {
		msg("%s: %s", out_path, strerror(errno));
		return 1;
	}
	t0 = now_ms();

	for (;;) {
		const char *path;
		uint8_t *jpg;
		size_t len;
		unsigned jw, jh;
		int prog;
		double t;
		ssize_t n;

		if (list) {
			if (!fgets(line, sizeof(line), list))
				break;
			line[strcspn(line, "\r\n")] = 0;
			if (!line[0])
				continue;
			path = line;
		} else {
			if (argi >= argc)
				break;
			path = argv[argi++];
		}

		jpg = read_file(path, &len);
		if (!jpg) {
			failed++;
			continue;
		}
		prog = jpeg_size(jpg, len, &jw, &jh);
		if (prog != 0 || (jw & 15) || (jh & 15) || jw < 160 || jh < 120 || jw > 2560 || jh > 2048) {
			msg("%s: %s, skipped", path,
			    prog == 1 ? "progressive JPEG" :
			    prog < 0 ? "no baseline SOF marker" :
			    "the size must be a multiple of 16 between 160x120 and 2560x2048");
			free(jpg);
			skipped++;
			continue;
		}
		if (!w) {
			w = jw;
			h = jh;
			if (sw_decode) {
				nv12 = malloc((size_t)w * h * 3 / 2);
				if (!nv12) {
					free(jpg);
					goto out;
				}
			} else if (setup_decoder(&dec, w, h) < 0) {
				free(jpg);
				goto out;
			}
			if (!decode_only && setup_encoder(&enc, w, h, qp, gop) < 0) {
				free(jpg);
				goto out;
			}
			if (verbose)
				msg("%ux%u, QP %d, GOP %d, %s JPEG decoder", w, h, qp, gop,
				    sw_decode ? "software" : "Helix");
		} else if (jw != w || jh != h) {
			msg("%s: %ux%u, the stream is %ux%u, skipped", path, jw, jh, w, h);
			free(jpg);
			skipped++;
			continue;
		}

		t = now_ms();
		if (sw_decode) {
			ysrc = nv12;
			uvsrc = nv12 + (size_t)w * h;
			rc = decode_sw(jpg, len, w, h, ysrc, uvsrc);
		} else {
			ysrc = dec.cap[0].map;
			uvsrc = dec.cap[1].map;
			rc = decode(&dec, jpg, len, w, h);
		}
		if (rc < 0) {
			msg("%s: decode failed", path);
			free(jpg);
			failed++;
			if (failed > 3 && done == 0)
				goto out;
			continue;
		}
		free(jpg);
		t_dec += now_ms() - t;
		if (progress_total > 0) {
			draw_progress(ysrc, uvsrc, w, h, done + 1, progress_total);
		}

		if (decode_only) {
			if (fwrite(ysrc, 1, (size_t)w * h, out) != (size_t)w * h ||
			    fwrite(uvsrc, 1, (size_t)w * h / 2, out) != (size_t)w * h / 2) {
				msg("%s: write: %s", out_path, strerror(errno));
				goto out;
			}
			out_bytes += (long long)w * h * 3 / 2;
			done++;
			fprintf(stderr, "frame=%5d decoded\n", done);
			continue;
		}

		memcpy(enc.out[0].map, ysrc, (size_t)w * h);
		memcpy(enc.out[1].map, uvsrc, (size_t)w * h / 2);

		t = now_ms();
		n = encode(&enc, w, h, done == 0);
		if (n < 0) {
			msg("%s: encode failed", path);
			failed++;
			if (failed > 3 && done == 0)
				goto out;
			continue;
		}
		t_enc += now_ms() - t;
		if (fwrite(enc.cap[0].map, 1, n, out) != (size_t)n) {
			msg("%s: write: %s", out_path, strerror(errno));
			goto out;
		}
		out_bytes += n;
		done++;
		/* ffmpeg-style progress line; moonraker-timelapse reads "frame=N" from it. */
		fprintf(stderr, "frame=%5d fps=%5.1f q=%d.0 size=%8lldkB\n", done,
			done * 1000.0 / (now_ms() - t0 + 1), qp, out_bytes / 1024);
	}
	rc = (done > 0 && failed == 0) ? 0 : (done > 0 ? 3 : 1);
	goto finish;
out:
	rc = 1;
finish:
	free(nv12);
	if (out)
		fclose(out);
	close_ctx(&enc);
	close_ctx(&dec);
	if (done || failed || skipped)
		msg("%d frames encoded (%lld bytes), %d skipped, %d failed, %.0f ms total, "
		    "decode %.1f ms/frame, encode %.1f ms/frame",
		    done, out_bytes, skipped, failed, now_ms() - t0,
		    done ? t_dec / done : 0, done ? t_enc / done : 0);
	return rc;
}
