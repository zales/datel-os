/* k1os-stream: Moonraker poller. MIT License, part of Datel OS.
 * One HTTP GET per second on a thread, with a small JSON scanner that only
 * looks up the handful of fields the overlay shows. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "moonraker.h"

#define QUERY "/printer/objects/query?print_stats&display_status&extruder&heater_bed" \
              "&motion_report=live_velocity,live_extruder_velocity,live_position" \
              "&temperature_sensor%20chamber_temp=temperature&temperature_sensor%20mcu_temp=temperature" \
              "&output_pin%20fan0=value&fan=speed"
/* cross-section of 1.75 mm filament, mm2 */
#define FILAMENT_AREA 2.405
#define STORE "/server/temperature_store?include_monitors=false"

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct printer_state current;
static char mr_host[64];
static int mr_port;

/* history ring: hist_i is the slot the next sample goes to */
static int keep_history;
static struct temp_history hist;    /* ring order, not chronological */
static unsigned hist_i;

static int http_get(const char *path, char *buf, size_t size)
{
	struct sockaddr_in sa;
	struct timeval tv = { 2, 0 };
	int fd, one = 1;
	size_t got = 0;
	char req[1024];
	ssize_t n;

	fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0) {
		return -1;
	}
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
	memset(&sa, 0, sizeof sa);
	sa.sin_family = AF_INET;
	sa.sin_port = htons(mr_port);
	if (inet_pton(AF_INET, mr_host, &sa.sin_addr) != 1) {
		close(fd);
		return -1;
	}
	if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
		close(fd);
		return -1;
	}
	n = snprintf(req, sizeof req, "GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n", path, mr_host);
	if (n < 0 || (size_t)n >= sizeof req || write(fd, req, n) != n) {
		close(fd);
		return -1;
	}
	while (got + 1 < size) {
		n = read(fd, buf + got, size - 1 - got);
		if (n <= 0) {
			break;
		}
		got += n;
	}
	close(fd);
	buf[got] = 0;
	return got > 0 ? 0 : -1;
}

/* Find "key": inside obj (a '{' ... '}' span at the same nesting level) and
 * return a pointer to the value. */
static const char *json_value(const char *obj, const char *key)
{
	char pat[64];
	const char *p = obj;
	int depth = 0;
	size_t kl;

	snprintf(pat, sizeof pat, "\"%s\"", key);
	kl = strlen(pat);
	if (*p == '{') {
		p++;
		depth = 1;
	}
	while (*p) {
		if (*p == '"') {
			const char *s = p;
			/* skip a string, honouring escapes */
			p++;
			while (*p && *p != '"') {
				if (*p == '\\' && p[1]) {
					p++;
				}
				p++;
			}
			if (depth == 1 && (size_t)(p - s + 1) == kl && strncmp(s, pat, kl) == 0) {
				p++;
				while (*p == ' ' || *p == ':') {
					p++;
				}
				return p;
			}
		} else if (*p == '{' || *p == '[') {
			depth++;
		} else if (*p == '}' || *p == ']') {
			depth--;
			if (depth <= 0) {
				return NULL;
			}
		}
		if (*p) {
			p++;
		}
	}
	return NULL;
}

static void json_string(const char *v, char *out, size_t size)
{
	size_t i = 0;
	out[0] = 0;
	if (!v || *v != '"') {
		return;
	}
	v++;
	while (*v && *v != '"' && i + 1 < size) {
		if (*v == '\\' && v[1]) {
			v++;
		}
		out[i++] = *v++;
	}
	out[i] = 0;
}

static double json_number(const char *v, double dflt)
{
	char *end;
	double d;
	if (!v || *v == 'n') {
		return dflt;
	}
	d = strtod(v, &end);
	return end == v ? dflt : d;
}

static void parse(const char *doc, struct printer_state *st)
{
	const char *status, *ps, *ds, *ex, *hb, *o, *v;
	const char *body = strstr(doc, "\r\n\r\n");

	memset(st, 0, sizeof *st);
	if (!body) {
		return;
	}
	body = strchr(body, '{');
	if (!body) {
		return;
	}
	status = json_value(body, "result");
	status = status ? json_value(status, "status") : NULL;
	if (!status) {
		return;
	}
	ps = json_value(status, "print_stats");
	ds = json_value(status, "display_status");
	ex = json_value(status, "extruder");
	hb = json_value(status, "heater_bed");
	if (ps) {
		json_string(json_value(ps, "state"), st->state, sizeof st->state);
		json_string(json_value(ps, "filename"), st->filename, sizeof st->filename);
		st->print_duration = json_number(json_value(ps, "print_duration"), 0);
	}
	if (ds) {
		st->progress = json_number(json_value(ds, "progress"), 0);
	}
	if (ex) {
		st->nozzle = json_number(json_value(ex, "temperature"), 0);
		st->nozzle_target = json_number(json_value(ex, "target"), 0);
	}
	if (hb) {
		st->bed = json_number(json_value(hb, "temperature"), 0);
		st->bed_target = json_number(json_value(hb, "target"), 0);
	}
	o = json_value(status, "temperature_sensor chamber_temp");
	if (o && (v = json_value(o, "temperature"))) {
		st->chamber = json_number(v, 0);
		st->have_chamber = 1;
	}
	o = json_value(status, "temperature_sensor mcu_temp");
	if (o && (v = json_value(o, "temperature"))) {
		st->mcu_temp = json_number(v, 0);
		st->have_mcu_temp = 1;
	}
	o = json_value(status, "motion_report");
	if (o && (v = json_value(o, "live_velocity"))) {
		double e = json_number(json_value(o, "live_extruder_velocity"), 0);
		st->speed = json_number(v, 0);
		st->flow = e > 0 ? e * FILAMENT_AREA : 0;   /* a retraction is not flow */
		/* live_position is [x, y, z, e]: the third number */
		v = json_value(o, "live_position");
		if (v && *v == '[') {
			const char *c1 = strchr(v, ','), *c2 = c1 ? strchr(c1 + 1, ',') : NULL;
			if (c2) {
				st->z = json_number(c2 + 1, 0);
			}
		}
		st->have_motion = 1;
	}
	/* the K1 drives its part fan as output_pin fan0; a plain [fan] elsewhere */
	o = json_value(status, "output_pin fan0");
	v = o ? json_value(o, "value") : NULL;
	if (!v && (o = json_value(status, "fan"))) {
		v = json_value(o, "speed");
	}
	if (v) {
		st->fan = json_number(v, 0);
		st->have_fan = 1;
	}
	st->valid = 1;
}

static int16_t tenths(double d)
{
	if (d < -3000) d = -3000;
	if (d > 3000) d = 3000;
	return (int16_t)(d * 10 + (d < 0 ? -0.5 : 0.5));
}

/* Read a JSON array of numbers into the ring slots ending at hist_i - 1:
 * the array holds the newest value last, like the ring. Values beyond
 * HISTORY_N (older ones) are dropped. Returns the count stored. */
static unsigned json_array_into_ring(const char *v, int16_t *ring)
{
	static int16_t tmp[HISTORY_N];
	unsigned count = 0, i, wi = 0;

	if (!v || *v != '[') {
		return 0;
	}
	v++;
	for (;;) {
		char *end;
		double d;
		while (*v == ' ' || *v == ',') {
			v++;
		}
		if (*v == ']' || !*v) {
			break;
		}
		if (*v == 'n') {        /* null */
			d = 0;
			end = (char *)v + 4;
		} else {
			d = strtod(v, &end);
			if (end == v) {
				break;
			}
		}
		v = end;
		tmp[wi] = tenths(d);
		wi = (wi + 1) % HISTORY_N;
		if (count < HISTORY_N) {
			count++;
		}
	}
	/* tmp holds the last `count` values ending at wi - 1; the ring's
	 * newest slot is hist_i - 1 */
	for (i = 0; i < count; i++) {
		unsigned src = (wi + HISTORY_N - count + i) % HISTORY_N;
		unsigned dst = (hist_i + HISTORY_N - count + i) % HISTORY_N;
		ring[dst] = tmp[src];
	}
	return count;
}

/* Fill the ring from Moonraker's temperature store (one sample a second,
 * the last 20 minutes by default), so the graph is not empty at start. */
static void prefill_history(void)
{
	size_t size = 512 * 1024;
	char *buf = malloc(size);
	const char *body, *res, *obj;
	unsigned n = 0, m;

	if (!buf) {
		return;
	}
	if (http_get(STORE, buf, size) != 0 || !(body = strstr(buf, "\r\n\r\n")) ||
	    !(body = strchr(body, '{')) || !(res = json_value(body, "result"))) {
		free(buf);
		return;
	}
	pthread_mutex_lock(&lock);
	obj = json_value(res, "extruder");
	if (obj) {
		m = json_array_into_ring(json_value(obj, "temperatures"), hist.nozzle);
		if (m > n) n = m;
		m = json_array_into_ring(json_value(obj, "targets"), hist.nozzle_target);
		if (m > n) n = m;
	}
	obj = json_value(res, "heater_bed");
	if (obj) {
		m = json_array_into_ring(json_value(obj, "temperatures"), hist.bed);
		if (m > n) n = m;
		m = json_array_into_ring(json_value(obj, "targets"), hist.bed_target);
		if (m > n) n = m;
	}
	if (n > hist.n) {
		hist.n = n;
	}
	pthread_mutex_unlock(&lock);
	free(buf);
	fprintf(stderr, "moonraker: %u s of temperature history loaded\n", n);
}

static void history_push(const struct printer_state *st)
{
	int16_t none = TEMP_NONE;
	hist.nozzle[hist_i] = st->valid ? tenths(st->nozzle) : none;
	hist.nozzle_target[hist_i] = st->valid ? tenths(st->nozzle_target) : none;
	hist.bed[hist_i] = st->valid ? tenths(st->bed) : none;
	hist.bed_target[hist_i] = st->valid ? tenths(st->bed_target) : none;
	hist_i = (hist_i + 1) % HISTORY_N;
	if (hist.n < HISTORY_N) {
		hist.n++;
	}
}

static void *poller(void *arg)
{
	static char buf[16384];
	struct printer_state st;
	struct timespec next;
	(void)arg;

	if (keep_history) {
		prefill_history();
	}
	clock_gettime(CLOCK_MONOTONIC, &next);
	for (;;) {
		if (http_get(QUERY, buf, sizeof buf) == 0) {
			parse(buf, &st);
		} else {
			memset(&st, 0, sizeof st);
		}
		pthread_mutex_lock(&lock);
		current = st;
		if (keep_history) {
			history_push(&st);
		}
		pthread_mutex_unlock(&lock);
		/* one sample a second, whatever the request took */
		next.tv_sec += 1;
		while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL) == EINTR) {
		}
	}
	return NULL;
}

int moonraker_start(const char *host, int port, int history)
{
	pthread_t t;
	pthread_attr_t attr;
	unsigned i;
	snprintf(mr_host, sizeof mr_host, "%s", host);
	mr_port = port;
	keep_history = history;
	for (i = 0; i < HISTORY_N; i++) {
		hist.nozzle[i] = hist.nozzle_target[i] = hist.bed[i] = hist.bed_target[i] = TEMP_NONE;
	}
	pthread_attr_init(&attr);
	pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
	pthread_attr_setstacksize(&attr, 128 * 1024);
	if (pthread_create(&t, &attr, poller, NULL) != 0) {
		fprintf(stderr, "moonraker: cannot start the poller thread: %s\n", strerror(errno));
		return -1;
	}
	return 0;
}

void moonraker_get(struct printer_state *out)
{
	pthread_mutex_lock(&lock);
	*out = current;
	pthread_mutex_unlock(&lock);
}

void moonraker_history_get(struct temp_history *out)
{
	unsigned i, src;
	pthread_mutex_lock(&lock);
	out->n = hist.n;
	src = (hist_i + HISTORY_N - hist.n) % HISTORY_N;   /* oldest sample */
	for (i = 0; i < hist.n; i++) {
		out->nozzle[i] = hist.nozzle[src];
		out->nozzle_target[i] = hist.nozzle_target[src];
		out->bed[i] = hist.bed[src];
		out->bed_target[i] = hist.bed_target[src];
		src = (src + 1) % HISTORY_N;
	}
	pthread_mutex_unlock(&lock);
}
