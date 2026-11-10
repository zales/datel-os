/* k1os-stream: MJPEG camera frames -> Helix JPEG decoder -> status overlay
 * -> Helix H.264 encoder -> raw Annex B H.264 on stdout, at a steady frame
 * rate and with a userspace rate controller on the encoder's QP controls.
 *
 * Frames come either from a JPEG stream on stdin (ustreamer-dump reading
 * uStreamer's memory sink, so the camera stays shared with Mainsail) or
 * straight from a V4L2 MJPEG capture device.
 *
 * MIT License, part of Datel OS. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>
#include <linux/videodev2.h>

#include "graph.h"
#include "helix.h"
#include "jpeg_dht.h"
#include "moonraker.h"
#include "overlay.h"
#include "sysstat.h"

#define NBUFS 2
#define CAM_BUFS 3
#define CODEC_TIMEOUT_MS 3000

static volatile sig_atomic_t stop_now;

static void on_signal(int sig)
{
	(void)sig;
	stop_now = 1;
}

static int64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* ------------------------------------------------------------------ */
/* JPEG helpers                                                        */

/* Width and height from the SOF marker; 0 if not found. */
static int jpeg_size(const uint8_t *d, size_t len, unsigned *w, unsigned *h)
{
	size_t i = 2;
	if (len < 4 || d[0] != 0xFF || d[1] != 0xD8) {
		return -1;
	}
	while (i + 4 <= len) {
		unsigned m, l;
		if (d[i] != 0xFF) {
			return -1;
		}
		m = d[i + 1];
		if (m == 0xFF) {
			i++;
			continue;
		}
		if (m == 0xD8 || (m >= 0xD0 && m <= 0xD7)) {
			i += 2;
			continue;
		}
		if (m == 0xDA || m == 0xD9) {
			return -1;
		}
		l = (d[i + 2] << 8) | d[i + 3];
		if ((m == 0xC0 || m == 0xC1 || m == 0xC2) && i + 9 <= len) {
			*h = (d[i + 5] << 8) | d[i + 6];
			*w = (d[i + 7] << 8) | d[i + 8];
			return 0;
		}
		i += 2 + l;
	}
	return -1;
}

/* 1 if the frame carries a DHT segment before the scan. */
static int jpeg_has_dht(const uint8_t *d, size_t len)
{
	size_t i = 2;
	while (i + 4 <= len && d[i] == 0xFF) {
		unsigned m = d[i + 1];
		if (m == 0xFF) {
			i++;
			continue;
		}
		if (m == 0xC4) {
			return 1;
		}
		if (m == 0xDA) {
			return 0;
		}
		i += 2 + ((d[i + 2] << 8) | d[i + 3]);
	}
	return 0;
}

/* ------------------------------------------------------------------ */
/* JPEG sources                                                        */

struct cam_buf {
	void *map;
	size_t len;
};

struct jpeg_src {
	int is_v4l2;
	int fd;
	/* V4L2 capture */
	struct cam_buf cam[CAM_BUFS];
	unsigned ncam;
	int held;                       /* index of the buffer handed out, -1 */
	int pending;                    /* newest dequeued buffer not yet handed out, -1 */
	size_t pending_len;
	/* stdin stream */
	uint8_t *buf;
	size_t len, cap;
	size_t frame_end;               /* end of the frame handed out */
	unsigned long received;
};

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;
	do {
		r = ioctl(fd, req, arg);
	} while (r < 0 && errno == EINTR);
	return r;
}

static int src_open_stdin(struct jpeg_src *s)
{
	memset(s, 0, sizeof *s);
	s->fd = STDIN_FILENO;
	s->held = -1;
	s->pending = -1;
	s->cap = 2 * 1024 * 1024;
	s->buf = malloc(s->cap);
	if (!s->buf) {
		return -1;
	}
	fcntl(s->fd, F_SETFL, fcntl(s->fd, F_GETFL) | O_NONBLOCK);
	return 0;
}

static int src_open_v4l2(struct jpeg_src *s, const char *dev, unsigned w, unsigned h, unsigned fps)
{
	struct v4l2_format f;
	struct v4l2_streamparm parm;
	struct v4l2_requestbuffers rb;
	enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	unsigned i;

	memset(s, 0, sizeof *s);
	s->is_v4l2 = 1;
	s->held = -1;
	s->pending = -1;
	s->fd = open(dev, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (s->fd < 0) {
		fprintf(stderr, "camera: open %s: %s\n", dev, strerror(errno));
		return -1;
	}
	memset(&f, 0, sizeof f);
	f.type = t;
	f.fmt.pix.width = w;
	f.fmt.pix.height = h;
	f.fmt.pix.pixelformat = V4L2_PIX_FMT_MJPEG;
	f.fmt.pix.field = V4L2_FIELD_NONE;
	if (xioctl(s->fd, VIDIOC_S_FMT, &f) < 0) {
		fprintf(stderr, "camera: S_FMT MJPEG %ux%u: %s\n", w, h, strerror(errno));
		return -1;
	}
	if (f.fmt.pix.pixelformat != V4L2_PIX_FMT_MJPEG) {
		fprintf(stderr, "camera: %s does not offer MJPEG\n", dev);
		return -1;
	}
	memset(&parm, 0, sizeof parm);
	parm.type = t;
	parm.parm.capture.timeperframe.numerator = 1;
	parm.parm.capture.timeperframe.denominator = fps;
	if (xioctl(s->fd, VIDIOC_S_PARM, &parm) < 0) {
		fprintf(stderr, "camera: S_PARM %u fps: %s (going on)\n", fps, strerror(errno));
	}
	memset(&rb, 0, sizeof rb);
	rb.type = t;
	rb.memory = V4L2_MEMORY_MMAP;
	rb.count = CAM_BUFS;
	if (xioctl(s->fd, VIDIOC_REQBUFS, &rb) < 0 || rb.count == 0) {
		fprintf(stderr, "camera: REQBUFS: %s\n", strerror(errno));
		return -1;
	}
	s->ncam = rb.count > CAM_BUFS ? CAM_BUFS : rb.count;
	for (i = 0; i < s->ncam; i++) {
		struct v4l2_buffer b;
		memset(&b, 0, sizeof b);
		b.type = t;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		if (xioctl(s->fd, VIDIOC_QUERYBUF, &b) < 0) {
			fprintf(stderr, "camera: QUERYBUF: %s\n", strerror(errno));
			return -1;
		}
		s->cam[i].len = b.length;
		s->cam[i].map = mmap(NULL, b.length, PROT_READ, MAP_SHARED, s->fd, b.m.offset);
		if (s->cam[i].map == MAP_FAILED) {
			fprintf(stderr, "camera: mmap: %s\n", strerror(errno));
			return -1;
		}
		if (xioctl(s->fd, VIDIOC_QBUF, &b) < 0) {
			fprintf(stderr, "camera: QBUF: %s\n", strerror(errno));
			return -1;
		}
	}
	if (xioctl(s->fd, VIDIOC_STREAMON, &t) < 0) {
		fprintf(stderr, "camera: STREAMON: %s\n", strerror(errno));
		return -1;
	}
	return 0;
}

/* Give a previously taken frame back. */
static void src_release(struct jpeg_src *s)
{
	if (s->is_v4l2) {
		if (s->held >= 0) {
			struct v4l2_buffer b;
			memset(&b, 0, sizeof b);
			b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
			b.memory = V4L2_MEMORY_MMAP;
			b.index = s->held;
			xioctl(s->fd, VIDIOC_QBUF, &b);
			s->held = -1;
		}
	} else if (s->frame_end) {
		if (s->frame_end > s->len) {
			s->frame_end = s->len;
		}
		memmove(s->buf, s->buf + s->frame_end, s->len - s->frame_end);
		s->len -= s->frame_end;
		s->frame_end = 0;
	}
}

static void cam_requeue(struct jpeg_src *s, int idx)
{
	struct v4l2_buffer q;
	memset(&q, 0, sizeof q);
	q.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	q.memory = V4L2_MEMORY_MMAP;
	q.index = idx;
	xioctl(s->fd, VIDIOC_QBUF, &q);
}

/* Consume what the source has ready, so that poll() does not spin: camera
 * buffers are dequeued (only the newest is kept), stdin is read into the
 * buffer. Returns -1 at the end of the stream or on an error. */
static int src_fill(struct jpeg_src *s)
{
	if (s->is_v4l2) {
		for (;;) {
			struct v4l2_buffer b;
			memset(&b, 0, sizeof b);
			b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
			b.memory = V4L2_MEMORY_MMAP;
			if (xioctl(s->fd, VIDIOC_DQBUF, &b) < 0) {
				if (errno == EAGAIN) {
					return 0;
				}
				fprintf(stderr, "camera: DQBUF: %s\n", strerror(errno));
				return -1;
			}
			s->received++;
			if (s->pending >= 0) {
				cam_requeue(s, s->pending);
			}
			s->pending = b.index;
			s->pending_len = (b.flags & V4L2_BUF_FLAG_ERROR) ? 0 : b.bytesused;
		}
	} else {
		for (;;) {
			ssize_t n;
			if (s->len == s->cap) {
				/* no frame boundary in 2 MiB: not a JPEG stream, resync */
				s->len = 0;
			}
			n = read(s->fd, s->buf + s->len, s->cap - s->len);
			if (n < 0) {
				if (errno == EAGAIN || errno == EINTR) {
					return 0;
				}
				fprintf(stderr, "stdin: read: %s\n", strerror(errno));
				return -1;
			}
			if (n == 0) {
				fprintf(stderr, "stdin: end of the JPEG stream\n");
				return -1;
			}
			s->len += n;
		}
	}
}

/* Take the newest complete frame, dropping older ones. Returns 1 with
 * data and len set (valid until src_release), 0 if none. */
static int src_take(struct jpeg_src *s, const uint8_t **data, size_t *len)
{
	if (s->is_v4l2) {
		if (s->pending < 0) {
			return 0;
		}
		if (s->pending_len < 4) {
			cam_requeue(s, s->pending);
			s->pending = -1;
			return 0;
		}
		s->held = s->pending;
		s->pending = -1;
		*data = s->cam[s->held].map;
		*len = s->pending_len;
		return 1;
	} else {
		size_t best_s = 0, best_e = 0, pos = 0;
		int found = 0;
		/* the last complete SOI..EOI in the buffer */
		while (pos + 4 <= s->len) {
			uint8_t *soi = memmem(s->buf + pos, s->len - pos, "\xFF\xD8\xFF", 3);
			uint8_t *eoi;
			if (!soi) {
				break;
			}
			eoi = memmem(soi + 3, s->len - (soi + 3 - s->buf), "\xFF\xD9", 2);
			if (!eoi) {
				/* A partial frame at the end. With no complete frame before
				 * it, drop what precedes it now; otherwise src_release()
				 * drops everything up to the frame handed out. */
				if (!found && soi != s->buf) {
					memmove(s->buf, soi, s->len - (soi - s->buf));
					s->len -= soi - s->buf;
				}
				break;
			}
			best_s = soi - s->buf;
			best_e = eoi + 2 - s->buf;
			found = 1;
			s->received++;
			pos = best_e;
		}
		if (!found) {
			return 0;
		}
		*data = s->buf + best_s;
		*len = best_e - best_s;
		s->frame_end = best_e;
		return 1;
	}
}

/* ------------------------------------------------------------------ */
/* Output                                                              */

static int write_all(int fd, const struct iovec *iov_in, int n)
{
	struct iovec iov[4];
	int i;
	memcpy(iov, iov_in, n * sizeof *iov);
	while (n > 0) {
		ssize_t w = writev(fd, iov, n);
		if (w < 0) {
			if (errno == EINTR) {
				continue;
			}
			if (errno == EAGAIN) {
				struct pollfd p = { fd, POLLOUT, 0 };
				poll(&p, 1, 1000);
				continue;
			}
			return -1;
		}
		for (i = 0; i < n && w > 0; ) {
			if ((size_t)w >= iov[i].iov_len) {
				w -= iov[i].iov_len;
				i++;
			} else {
				iov[i].iov_base = (char *)iov[i].iov_base + w;
				iov[i].iov_len -= w;
				w = 0;
			}
		}
		if (i > 0) {
			memmove(iov, iov + i, (n - i) * sizeof *iov);
			n -= i;
		}
	}
	return 0;
}

/* The driver pads SPS/PPS in front of an IDR slice to 256 bytes with a
 * filler NAL (type 12); drop it, it is only noise for the muxer. */
static int split_out_filler(uint8_t *buf, size_t len, struct iovec *iov)
{
	size_t lim = len < 1024 ? len : 1024;
	size_t i, filler_start = 0, filler_end = 0;
	int in_filler = 0;

	for (i = 0; i + 3 < lim; i++) {
		if (buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1) {
			size_t start = (i > 0 && buf[i - 1] == 0) ? i - 1 : i;
			unsigned type = buf[i + 3] & 0x1f;
			if (in_filler) {
				filler_end = start;
				break;
			}
			if (type == 12) {
				in_filler = 1;
				filler_start = start;
			} else if (type == 1 || type == 5) {
				break;
			}
			i += 3;
		}
	}
	if (in_filler && filler_end > filler_start) {
		iov[0].iov_base = buf;
		iov[0].iov_len = filler_start;
		iov[1].iov_base = buf + filler_end;
		iov[1].iov_len = len - filler_end;
		return 2;
	}
	iov[0].iov_base = buf;
	iov[0].iov_len = len;
	return 1;
}

/* ------------------------------------------------------------------ */

static int find_helix(char *path, size_t size)
{
	unsigned i;
	for (i = 0; i < 16; i++) {
		char p[64], name[64];
		FILE *f;
		snprintf(p, sizeof p, "/sys/class/video4linux/video%u/name", i);
		f = fopen(p, "r");
		if (!f) {
			continue;
		}
		if (fgets(name, sizeof name, f) && strncmp(name, "helix-venc", 10) == 0) {
			fclose(f);
			snprintf(path, size, "/dev/video%u", i);
			return 0;
		}
		fclose(f);
	}
	return -1;
}

static const char *state_word(const char *s)
{
	if (!strcmp(s, "printing")) return "Printing";
	if (!strcmp(s, "paused")) return "Paused";
	if (!strcmp(s, "complete")) return "Done";
	if (!strcmp(s, "error")) return "Error";
	if (!strcmp(s, "cancelled")) return "Cancelled";
	if (!strcmp(s, "standby")) return "Idle";
	return s[0] ? s : "Idle";
}

static void overlay_lines(struct overlay *o, const struct printer_state *st)
{
	unsigned maxc = (o->width - 2 * o->pad) / o->font_w;
	char name[128];
	size_t nl;

	if (maxc >= sizeof o->lines[0]) {
		maxc = sizeof o->lines[0] - 1;
	}
	o->nlines = 2;
	if (!st->valid) {
		snprintf(o->lines[0], sizeof o->lines[0], "Datel OS");
		snprintf(o->lines[1], sizeof o->lines[1], "Moonraker not reachable");
		return;
	}
	snprintf(name, sizeof name, "%s", st->filename);
	nl = strlen(name);
	if (nl > 6 && !strcasecmp(name + nl - 6, ".gcode")) {
		name[nl - 6] = 0;
	}
	if (name[0] && (!strcmp(st->state, "printing") || !strcmp(st->state, "paused") ||
	                !strcmp(st->state, "complete"))) {
		char tail[32];
		unsigned room;
		int secs = (int)st->print_duration;
		snprintf(tail, sizeof tail, "  %3.0f%%  %d:%02d:%02d", st->progress * 100.0,
		         secs / 3600, (secs / 60) % 60, secs % 60);
		room = maxc - strlen(state_word(st->state)) - 2 - strlen(tail);
		if (strlen(name) > room && room > 2) {
			name[room - 2] = '.';
			name[room - 1] = '.';
			name[room] = 0;
		}
		snprintf(o->lines[0], sizeof o->lines[0], "%s  %s%s", state_word(st->state), name, tail);
	} else {
		snprintf(o->lines[0], sizeof o->lines[0], "%s", state_word(st->state));
	}
	snprintf(o->lines[1], sizeof o->lines[1], "Nozzle %3.0f/%.0f\xC2\xB0" "C   Bed %3.0f/%.0f\xC2\xB0" "C",
	         st->nozzle, st->nozzle_target, st->bed, st->bed_target);
	o->lines[0][maxc] = 0;
	o->lines[1][maxc] = 0;
}

/* Statistics as a small JSON file (written whole, then renamed), read by
 * Moonraker's k1os_stream component for the "Twitch: live 2.4 Mbit/s" line. */
static void write_status(const char *path, time_t started, unsigned width, unsigned height,
                         double fps_out, double kbit, int qp, unsigned long frames,
                         unsigned long cam_frames, unsigned long repeats,
                         double dec_ms, double enc_ms, int moonraker_ok)
{
	char tmp[256];
	FILE *f;
	if (!path || snprintf(tmp, sizeof tmp, "%s.tmp", path) >= (int)sizeof tmp) {
		return;
	}
	f = fopen(tmp, "w");
	if (!f) {
		return;
	}
	fprintf(f, "{\"started\": %lld, \"width\": %u, \"height\": %u, \"fps\": %.1f, \"kbit\": %.0f, "
	        "\"qp\": %d, \"frames\": %lu, \"camera_frames\": %lu, \"repeats\": %lu, "
	        "\"decode_ms\": %.1f, \"encode_ms\": %.1f, \"moonraker\": %s}\n",
	        (long long)started, width, height, fps_out, kbit, qp, frames, cam_frames, repeats,
	        dec_ms, enc_ms, moonraker_ok ? "true" : "false");
	fclose(f);
	rename(tmp, path);
}

static void usage(void)
{
	fprintf(stderr,
	        "k1os-stream [options] > out.h264\n"
	        "  --camera -            JPEG frames from stdin (default; e.g. ustreamer-dump --output -)\n"
	        "  --camera /dev/videoN  MJPEG capture straight from the camera\n"
	        "  --size WxH            capture size for --camera /dev/videoN (1280x720)\n"
	        "  --fps N               output frame rate (10); frames repeat when the camera is slower\n"
	        "  --bitrate KBIT        target bitrate in kbit/s (2500)\n"
	        "  --qp N                initial QP (28), --qp-min N (18), --qp-max N (45)\n"
	        "  --gop SECONDS         keyframe interval (2)\n"
	        "  --font small|large    overlay font 12x24 or 16x32 (large)\n"
	        "  --no-overlay          leave the picture alone\n"
	        "  --graph tl|tr|bl|br   add the graph panel (temperatures, progress) in that corner\n"
	        "                        and the statistics panel (chamber, board, speed, flow, Z,\n"
	        "                        fan, CPU, RAM, Wi-Fi, bitrate) next to it\n"
	        "  --moonraker HOST:PORT (127.0.0.1:7125)\n"
	        "  --device /dev/videoN  the Helix codec (found by its name helix-venc)\n"
	        "  --stats SECONDS       print statistics on stderr every N s (5, 0 = off)\n"
	        "  --status-file PATH    also write the statistics there as JSON (for Moonraker)\n"
	        "  --frames N            stop after N frames\n");
}

int main(int argc, char **argv)
{
	static const struct option opts[] = {
		{"camera", 1, 0, 'c'}, {"size", 1, 0, 's'}, {"fps", 1, 0, 'f'}, {"bitrate", 1, 0, 'b'},
		{"qp", 1, 0, 'q'}, {"qp-min", 1, 0, 'Q'}, {"qp-max", 1, 0, 'X'}, {"gop", 1, 0, 'g'},
		{"font", 1, 0, 'F'}, {"no-overlay", 0, 0, 'n'}, {"graph", 1, 0, 'G'}, {"moonraker", 1, 0, 'm'},
		{"device", 1, 0, 'd'}, {"stats", 1, 0, 'S'}, {"status-file", 1, 0, 'T'},
		{"frames", 1, 0, 'N'}, {"help", 0, 0, 'h'}, {0, 0, 0, 0}
	};
	const char *camera = "-", *status_file = NULL;
	time_t started = time(NULL);
	char device[32] = "";
	char mr_host[64] = "127.0.0.1";
	int mr_port = 7125;
	unsigned cam_w = 1280, cam_h = 720, width = 0, height = 0;
	unsigned fps = 10, gop_s = 2, gop_frames;
	unsigned bitrate_kbit = 2500;
	int qp = 28, qp_min = 18, qp_max = 45;   /* below 18 a frame can outgrow the codec's bitstream buffer */
	int font_large = 1, overlay_on = 1, graph_on = 0, stats_s = 5;
	enum graph_corner corner = GRAPH_TR;
	unsigned long max_frames = 0;
	struct jpeg_src src;
	struct helix_m2m dec, enc;
	struct overlay ov;
	struct graph *gr = NULL, *sp = NULL;   /* graph panel, statistics panel */
	struct sys_stats sys;
	double last_kbit = 0;
	static struct temp_history hist;
	struct printer_state pstate;
	int64_t period, next_tick, last_lines = 0, last_stats;
	unsigned last_nv12 = 0, have_frame = 0, dec_out = 0, enc_out = 0, enc_cap = 0;
	unsigned long frames = 0, repeats = 0, decoded = 0;
	uint64_t dec_ns = 0, enc_ns = 0;
	uint64_t *ring;
	uint64_t ring_sum = 0, bits_total = 0, bits_stats = 0;
	unsigned ring_n, ring_i = 0, ring_fill = 0;
	unsigned long frames_stats = 0;
	int c, no_dht_warned = 0, eof = 0;

	while ((c = getopt_long(argc, argv, "h", opts, NULL)) != -1) {
		switch (c) {
		case 'c': camera = optarg; break;
		case 's': if (sscanf(optarg, "%ux%u", &cam_w, &cam_h) != 2) { usage(); return 2; } break;
		case 'f': fps = atoi(optarg); break;
		case 'b': bitrate_kbit = atoi(optarg); break;
		case 'q': qp = atoi(optarg); break;
		case 'Q': qp_min = atoi(optarg); break;
		case 'X': qp_max = atoi(optarg); break;
		case 'g': gop_s = atoi(optarg); break;
		case 'F': font_large = strcmp(optarg, "small") != 0; break;
		case 'n': overlay_on = 0; break;
		case 'G':
			graph_on = 1;
			if (!strcmp(optarg, "tl")) corner = GRAPH_TL;
			else if (!strcmp(optarg, "tr")) corner = GRAPH_TR;
			else if (!strcmp(optarg, "bl")) corner = GRAPH_BL;
			else if (!strcmp(optarg, "br")) corner = GRAPH_BR;
			else if (!strcmp(optarg, "off")) graph_on = 0;
			else { usage(); return 2; }
			break;
		case 'm': {
			char *colon;
			snprintf(mr_host, sizeof mr_host, "%s", optarg);
			colon = strchr(mr_host, ':');
			if (colon) {
				*colon = 0;
				mr_port = atoi(colon + 1);
			}
			break;
		}
		case 'd': snprintf(device, sizeof device, "%s", optarg); break;
		case 'S': stats_s = atoi(optarg); break;
		case 'T': status_file = optarg; break;
		case 'N': max_frames = strtoul(optarg, NULL, 10); break;
		default: usage(); return c == 'h' ? 0 : 2;
		}
	}
	if (fps < 1 || fps > 60 || gop_s < 1 || qp_min < 0 || qp_max > 51 || qp_min > qp_max) {
		usage();
		return 2;
	}
	if (qp < qp_min) qp = qp_min;
	if (qp > qp_max) qp = qp_max;
	gop_frames = fps * gop_s;
	if (gop_frames > 120) {
		gop_frames = 120;
	}
	if (!device[0] && find_helix(device, sizeof device) < 0) {
		fprintf(stderr, "no helix-venc device; is the Helix codec in the kernel?\n");
		return 1;
	}

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGPIPE, SIG_IGN);

	if (!strcmp(camera, "-")) {
		if (src_open_stdin(&src) < 0) {
			return 1;
		}
	} else if (src_open_v4l2(&src, camera, cam_w, cam_h, fps) < 0) {
		return 1;
	}

	if (!overlay_on) {
		graph_on = 0;
	}
	if (overlay_on && moonraker_start(mr_host, mr_port, graph_on) < 0) {
		overlay_on = 0;
		graph_on = 0;
	}

	/* The first frame tells the size. */
	{
		const uint8_t *d;
		size_t l;
		while (!stop_now) {
			struct pollfd p = { src.fd, POLLIN, 0 };
			int r;
			if (src_fill(&src) < 0) {
				return 1;
			}
			r = src_take(&src, &d, &l);
			if (r > 0) {
				if (jpeg_size(d, l, &width, &height) < 0) {
					fprintf(stderr, "a camera frame is not a baseline JPEG\n");
					src_release(&src);
					continue;
				}
				src_release(&src);
				break;
			}
			poll(&p, 1, 1000);
		}
		if (stop_now) {
			return 0;
		}
	}
	if (width < 160 || height < 120 || (width & 15) || (height & 15)) {
		fprintf(stderr, "camera frames are %ux%u; the Helix needs multiples of 16\n", width, height);
		return 1;
	}
	fprintf(stderr, "k1os-stream: %ux%u, %u fps, %u kbit/s, GOP %u frames, codec %s\n",
	        width, height, fps, bitrate_kbit, gop_frames, device);

	if (helix_open(&dec, device, "jpeg-decoder", V4L2_PIX_FMT_JPEG, V4L2_PIX_FMT_NV12,
	               width, height, NBUFS, 0) < 0) {
		return 1;
	}
	if (helix_open(&enc, device, "h264-encoder", V4L2_PIX_FMT_NV12, V4L2_PIX_FMT_H264,
	               width, height, NBUFS, 1) < 0) {
		return 1;
	}
	helix_set_ctrl(&enc, V4L2_CID_MPEG_VIDEO_H264_PROFILE, V4L2_MPEG_VIDEO_H264_PROFILE_MAIN);
	helix_set_ctrl(&enc, V4L2_CID_MPEG_VIDEO_H264_LEVEL,
	               fps > 30 ? V4L2_MPEG_VIDEO_H264_LEVEL_4_0 : V4L2_MPEG_VIDEO_H264_LEVEL_3_1);
	helix_set_ctrl(&enc, V4L2_CID_MPEG_VIDEO_HEADER_MODE, V4L2_MPEG_VIDEO_HEADER_MODE_JOINED_WITH_1ST_FRAME);
	helix_set_ctrl(&enc, V4L2_CID_MPEG_VIDEO_GOP_SIZE, gop_frames);
	helix_set_ctrl(&enc, V4L2_CID_MPEG_VIDEO_BITRATE, bitrate_kbit * 1000 > 4000000 ? 4000000 : (int)(bitrate_kbit * 1000));
	helix_set_ctrl(&enc, V4L2_CID_MPEG_VIDEO_H264_MIN_QP, qp_min);
	helix_set_ctrl(&enc, V4L2_CID_MPEG_VIDEO_H264_MAX_QP, qp_max);
	helix_set_ctrl(&enc, V4L2_CID_MPEG_VIDEO_H264_I_FRAME_QP, qp > qp_min + 2 ? qp - 2 : qp_min);
	helix_set_ctrl(&enc, V4L2_CID_MPEG_VIDEO_H264_P_FRAME_QP, qp);
	if (helix_probe_dmabuf(&enc, &dec) < 0) {
		return 1;
	}
	if (helix_stream_on(&dec) < 0 || helix_stream_on(&enc) < 0) {
		return 1;
	}
	fprintf(stderr, "k1os-stream: frames pass from the decoder to the encoder %s\n",
	        enc.out_dmabuf ? "as DMABUFs" : "by copy");

	overlay_init(&ov, width, height, font_large);
	memset(&pstate, 0, sizeof pstate);
	if (graph_on) {
		overlay_lines(&ov, &pstate);    /* sets the line count, for the bar height */
		gr = calloc(1, sizeof *gr);
		if (!gr || graph_init(gr, width, height, overlay_bar_height(&ov), corner) < 0) {
			fprintf(stderr, "k1os-stream: no room for the graph panel in %ux%u, left out\n", width, height);
			free(gr);
			gr = NULL;
			graph_on = 0;
		}
		if (gr) {
			sp = calloc(1, sizeof *sp);
			if (!sp || graph_init_beside(sp, gr, height, overlay_bar_height(&ov)) < 0) {
				fprintf(stderr, "k1os-stream: no room for the statistics panel in %ux%u, left out\n", width, height);
				free(sp);
				sp = NULL;
			}
		}
	}
	memset(&sys, 0, sizeof sys);
	sys.cpu_pct = -1;
	write_status(status_file, started, width, height, 0, 0, qp, 0, 0, 0, 0, 0, 1);

	ring_n = gop_frames;
	ring = calloc(ring_n, sizeof *ring);
	if (!ring) {
		return 1;
	}

	period = 1000000000LL / fps;
	next_tick = now_ns();
	last_stats = next_tick;

	while (!stop_now && (max_frames == 0 || frames < max_frames)) {
		const uint8_t *jpeg;
		size_t jlen;
		int64_t t0, t1, t2;
		int r, fresh = 0;
		unsigned out_i, cap_i;
		size_t used;
		uint32_t cflags, flags;

		/* wait for the tick, picking up camera frames meanwhile */
		for (;;) {
			int64_t now = now_ns();
			struct pollfd p = { src.fd, POLLIN, 0 };
			if (now >= next_tick) {
				break;
			}
			poll(&p, 1, (int)((next_tick - now) / 1000000 + 1));
			if (p.revents & (POLLIN | POLLERR | POLLHUP)) {
				if (src_fill(&src) < 0) {
					eof = 1;
					break;
				}
			}
		}
		if (eof) {
			break;
		}

		t0 = now_ns();
		if (src_fill(&src) < 0) {
			break;
		}
		r = src_take(&src, &jpeg, &jlen);
		if (r > 0) {
			uint8_t *dst = dec.out[dec_out].map[0];
			size_t cap = dec.out[dec_out].len[0];
			size_t n = 0;
			unsigned w2 = 0, h2 = 0;
			if (jpeg_size(jpeg, jlen, &w2, &h2) == 0 && (w2 != width || h2 != height)) {
				fprintf(stderr, "camera frame size changed to %ux%u, restarting\n", w2, h2);
				break;
			}
			if (!jpeg_has_dht(jpeg, jlen)) {
				if (!no_dht_warned) {
					fprintf(stderr, "camera frames carry no Huffman tables; inserting the standard ones\n");
					no_dht_warned = 1;
				}
				if (jlen + sizeof jpeg_std_dht <= cap) {
					memcpy(dst, jpeg, 2);
					memcpy(dst + 2, jpeg_std_dht, sizeof jpeg_std_dht);
					memcpy(dst + 2 + sizeof jpeg_std_dht, jpeg + 2, jlen - 2);
					n = jlen + sizeof jpeg_std_dht;
				}
			} else if (jlen <= cap) {
				memcpy(dst, jpeg, jlen);
				n = jlen;
			}
			src_release(&src);
			if (n == 0) {
				fprintf(stderr, "camera frame of %zu bytes does not fit the %zu byte decoder buffer\n", jlen, cap);
			} else {
				unsigned target = have_frame ? (last_nv12 ^ 1) : 0;
				if (helix_queue_output(&dec, dec_out, n, 0) < 0 ||
				    helix_queue_capture(&dec, target) < 0 ||
				    helix_dequeue(&dec, &out_i, &cap_i, &used, &cflags, CODEC_TIMEOUT_MS) < 0) {
					break;
				}
				dec_out ^= 1;
				if (cflags & V4L2_BUF_FLAG_ERROR) {
					fprintf(stderr, "JPEG decode error, frame skipped\n");
				} else {
					last_nv12 = cap_i;
					have_frame = 1;
					fresh = 1;
					decoded++;
				}
			}
		}
		t1 = now_ns();
		dec_ns += t1 - t0;

		if (!have_frame) {
			next_tick += period;
			continue;
		}
		if (r <= 0) {
			repeats++;
		}

		if (overlay_on) {
			if (t1 - last_lines >= 1000000000LL) {
				moonraker_get(&pstate);
				overlay_lines(&ov, &pstate);
				if (gr) {
					moonraker_history_get(&hist);
					graph_render(gr, &pstate, &hist);
				}
				if (sp) {
					sysstat_sample(&sys);
					stats_render(sp, &pstate, &sys, last_kbit);
				}
				last_lines = t1;
			}
			overlay_draw(&ov, dec.cap[last_nv12].map[0], dec.cap[last_nv12].map[1]);
			if (gr) {
				graph_blit(gr, last_nv12, fresh, dec.cap[last_nv12].map[0], dec.cap[last_nv12].map[1]);
			}
			if (sp) {
				graph_blit(sp, last_nv12, fresh, dec.cap[last_nv12].map[0], dec.cap[last_nv12].map[1]);
			}
		}

		flags = (frames % gop_frames == 0) ? V4L2_BUF_FLAG_KEYFRAME : 0;
		if (enc.out_dmabuf) {
			r = helix_queue_output_dmabuf(&enc, enc_out, &dec, last_nv12, flags);
		} else {
			memcpy(enc.out[enc_out].map[0], dec.cap[last_nv12].map[0], enc.out[enc_out].len[0]);
			memcpy(enc.out[enc_out].map[1], dec.cap[last_nv12].map[1], enc.out[enc_out].len[1]);
			r = helix_queue_output(&enc, enc_out, enc.out[enc_out].len[0], flags);
		}
		if (r < 0 ||
		    helix_queue_capture(&enc, enc_cap) < 0 ||
		    helix_dequeue(&enc, &out_i, &cap_i, &used, &cflags, CODEC_TIMEOUT_MS) < 0) {
			break;
		}
		enc_out ^= 1;
		enc_cap ^= 1;
		t2 = now_ns();
		enc_ns += t2 - t1;

		if (used > 0) {
			struct iovec iov[2];
			int n = split_out_filler(enc.cap[cap_i].map[0], used, iov);
			if (write_all(STDOUT_FILENO, iov, n) < 0) {
				fprintf(stderr, "stdout: %s\n", strerror(errno));
				break;
			}
		}
		frames++;
		frames_stats++;

		/* rate control: the average over the last GOP against the target,
		 * one QP step per frame */
		{
			uint64_t bits = (uint64_t)used * 8;
			double window_s, rate;
			int new_qp = qp;
			ring_sum -= ring[ring_i];
			ring[ring_i] = bits;
			ring_sum += bits;
			ring_i = (ring_i + 1) % ring_n;
			if (ring_fill < ring_n) {
				ring_fill++;
			}
			bits_total += bits;
			bits_stats += bits;
			window_s = (double)ring_fill / fps;
			rate = ring_sum / window_s;
			/* one step at a time, and only every quarter second: the window
			 * average lags, a step every frame overshoots in both directions */
			if (frames % (fps / 4 ? fps / 4 : 1) == 0) {
				if (rate > bitrate_kbit * 1000.0 * 1.05) {
					new_qp = qp + 1;
				} else if (rate < bitrate_kbit * 1000.0 * 0.95) {
					new_qp = qp - 1;
				}
			}
			if (new_qp < qp_min) new_qp = qp_min;
			if (new_qp > qp_max) new_qp = qp_max;
			if (new_qp != qp) {
				qp = new_qp;
				helix_set_ctrl(&enc, V4L2_CID_MPEG_VIDEO_H264_P_FRAME_QP, qp);
				helix_set_ctrl(&enc, V4L2_CID_MPEG_VIDEO_H264_I_FRAME_QP, qp > qp_min + 2 ? qp - 2 : qp_min);
			}
		}

		if (stats_s > 0 && t2 - last_stats >= (int64_t)stats_s * 1000000000LL) {
			double secs = (t2 - last_stats) / 1e9;
			last_kbit = bits_stats / secs / 1000.0;
			fprintf(stderr, "k1os-stream: %.1f fps out, %.0f kbit/s, qp %d, camera %lu frames, "
			        "%lu repeats, decode %.1f ms, encode %.1f ms%s\n",
			        frames_stats / secs, bits_stats / secs / 1000.0, qp, src.received, repeats,
			        decoded ? dec_ns / 1e6 / decoded : 0.0, frames ? enc_ns / 1e6 / frames : 0.0,
			        overlay_on && !pstate.valid ? ", Moonraker not reachable" : "");
			write_status(status_file, started, width, height, frames_stats / secs,
			             bits_stats / secs / 1000.0, qp, frames, src.received, repeats,
			             decoded ? dec_ns / 1e6 / decoded : 0.0, frames ? enc_ns / 1e6 / frames : 0.0,
			             !overlay_on || pstate.valid);
			last_stats = t2;
			frames_stats = 0;
			bits_stats = 0;
		}

		next_tick += period;
		if (now_ns() > next_tick + period) {
			/* too slow: do not try to catch up, keep the real-time pace */
			next_tick = now_ns();
		}
	}

	fprintf(stderr, "k1os-stream: %lu frames, %.1f MB\n", frames, bits_total / 8e6);
	if (status_file) {
		unlink(status_file);
	}
	helix_close(&enc);
	helix_close(&dec);
	return (stop_now || (max_frames && frames >= max_frames)) ? 0 : 1;
}
