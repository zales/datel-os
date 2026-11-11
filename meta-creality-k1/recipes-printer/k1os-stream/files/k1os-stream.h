/* k1os-stream as a part of another program: the same camera-to-H.264 pipeline
 * that the k1os-stream command runs, handing each picture to a function
 * instead of writing it to stdout.
 *
 * MIT License, part of Datel OS. */
#ifndef K1OS_STREAM_H
#define K1OS_STREAM_H

#include <stddef.h>
#include <stdint.h>
#include <sys/uio.h>

struct k1os_stream_hooks {
	/* where the JPEG frames of "--camera -" are read from */
	int jpeg_fd;
	/* Gets every encoded picture as raw Annex B H.264, in up to two pieces;
	 * a key picture starts with its parameter sets. A negative result ends
	 * the run. */
	int (*picture)(void *ctx, const struct iovec *iov, int n);
	void *ctx;
	/* Optional: the camera frames come from the caller, whatever --camera
	 * says. frame() returns 1 with the newest JPEG frame when there is one
	 * that it has not handed out yet, 0 when there is none, -1 when there
	 * will be no more; the frame stays valid until frame_done(). */
	int (*frame)(void *ctx, const uint8_t **data, size_t *len);
	void (*frame_done)(void *ctx);
};

/* Runs until k1os_stream_stop(), the end of the camera frames or an error;
 * argv holds the options of the k1os-stream command. Everything it opened
 * is released again, so it can be called any number of times, but only one
 * run at a time. Returns 0 after a stop, 1 after an error, 2 for bad options. */
int k1os_stream_run(int argc, char **argv, const struct k1os_stream_hooks *hooks);
/* Ends the current run soon; safe from a signal handler and other threads.
 * A stop that arrives before a run has started is lost: repeat it until the
 * run has returned. */
void k1os_stream_stop(void);
/* Makes the next picture a key picture, for a viewer who has just joined
 * or has lost one. */
void k1os_stream_key_picture(void);

/* The camera on its own: MJPEG frames from a V4L2 capture device, as
 * "--camera /dev/videoN" reads them. */
struct k1os_camera;
struct k1os_camera *k1os_camera_open(const char *dev, unsigned width, unsigned height, unsigned fps);
/* becomes readable when a frame is ready */
int k1os_camera_fd(const struct k1os_camera *cam);
/* The newest frame the camera has: 1 with data and len set (valid until the
 * next call), 0 when there is no new one, -1 after an error. */
int k1os_camera_frame(struct k1os_camera *cam, const uint8_t **data, size_t *len);
void k1os_camera_close(struct k1os_camera *cam);

#endif
