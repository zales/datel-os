/* k1os-trace: a flight recorder for the question "what was the printer doing
 * when Klipper stopped?".
 *
 * Once a second it notes who had the CPUs and who waited for one, how far
 * ahead of the nozzle Klipper had planned, and what the network carried. The
 * last fifteen minutes stay in memory. When Klipper shuts down, they are
 * written to /usr/data/k1os/trace/<date-time>/ together with the end of
 * klippy.log and of the journal, so the minutes before a failure can be read
 * afterwards. SIGUSR1 writes the same on request.
 *
 * It also measures directly what Klipper cares about: every 10 ms it asks to
 * be woken and notes how late the wake-up came. A second in which that was
 * more than LATE_MS, or in which Klipper waited long for a CPU, gets a line in
 * the journal, which reaches the log server even if the printer does not
 * survive.
 *
 * Columns of samples.txt are named in its first line. Times are milliseconds
 * within the second sampled unless the name says otherwise.
 *
 * MIT License, part of Datel OS. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define RING 900                /* seconds kept */
#define LINE 400
#define LATE_MS 50              /* a wake-up this late is worth a journal line */
#define WAIT_MS 200             /* so is Klipper waiting this long in one second */
#define KLIPPY_LOG "/usr/data/k1os/printer_data/logs/klippy.log"
#define TRACE_DIR "/usr/data/k1os/trace"
#define KEEP 5                  /* recordings kept */

struct proc {
	const char *name;       /* column prefix */
	const char *match;      /* substring of the command line */
	int pid;
	uint64_t cpu_ticks, wait_ns;
	int have;
};

static struct proc procs[] = {
	{ "klippy", "klippy.py", 0, 0, 0, 0 },
	{ "mcu", "klipper_mcu", 0, 0, 0, 0 },
	{ "moonraker", "moonraker.py", 0, 0, 0, 0 },
	{ "camera", "k1os-camera", 0, 0, 0, 0 },
	{ "nginx", "nginx: worker", 0, 0, 0, 0 },
};
#define NPROCS (sizeof procs / sizeof procs[0])

static char ring[RING][LINE];
static unsigned ring_next, ring_count;
static volatile sig_atomic_t dump_wanted;

static void on_usr1(int sig)
{
	(void)sig;
	dump_wanted = 1;
}

static int64_t now_ns(clockid_t clock)
{
	struct timespec ts;
	clock_gettime(clock, &ts);
	return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int read_file(const char *path, char *buf, size_t size)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	ssize_t n;
	if (fd < 0) {
		return -1;
	}
	n = read(fd, buf, size - 1);
	close(fd);
	if (n < 0) {
		return -1;
	}
	buf[n] = 0;
	return (int)n;
}

/* ------------------------------------------------------------------ */
/* Processes                                                           */

static void find_procs(void)
{
	DIR *d = opendir("/proc");
	struct dirent *e;
	unsigned i;
	if (!d) {
		return;
	}
	for (i = 0; i < NPROCS; i++) {
		char path[64], cmd[256];
		snprintf(path, sizeof path, "/proc/%d/cmdline", procs[i].pid);
		if (procs[i].pid && read_file(path, cmd, sizeof cmd) > 0) {
			continue;       /* still there */
		}
		procs[i].pid = 0;
		procs[i].have = 0;
	}
	while ((e = readdir(d))) {
		char path[64], cmd[256];
		int n, j, pid = atoi(e->d_name);
		if (pid <= 0) {
			continue;
		}
		snprintf(path, sizeof path, "/proc/%d/cmdline", pid);
		n = read_file(path, cmd, sizeof cmd);
		if (n <= 0) {
			continue;
		}
		for (j = 0; j < n - 1; j++) {   /* arguments are separated by NULs */
			if (!cmd[j]) {
				cmd[j] = ' ';
			}
		}
		for (i = 0; i < NPROCS; i++) {
			if (!procs[i].pid && strstr(cmd, procs[i].match)) {
				procs[i].pid = pid;
			}
		}
	}
	closedir(d);
}

/* CPU time used and time spent runnable but waiting for a CPU, summed over
 * the threads of a process. The wait needs the kernel's scheduler statistics
 * (/proc/<pid>/task/<tid>/schedstat); without them *wait_ns is left alone and
 * 0 is returned for it. */
static int proc_times(int pid, uint64_t *cpu_ticks, uint64_t *wait_ns)
{
	char path[96], buf[512];
	DIR *d;
	struct dirent *e;
	uint64_t ticks = 0, wait = 0;
	int have_wait = 0, threads = 0;

	snprintf(path, sizeof path, "/proc/%d/task", pid);
	d = opendir(path);
	if (!d) {
		return -1;
	}
	while ((e = readdir(d))) {
		unsigned long long ut, st, run, w;
		char *p;
		if (e->d_name[0] == '.') {
			continue;
		}
		snprintf(path, sizeof path, "/proc/%d/task/%s/stat", pid, e->d_name);
		if (read_file(path, buf, sizeof buf) <= 0) {
			continue;
		}
		p = strrchr(buf, ')');  /* the name may hold spaces */
		if (p && sscanf(p + 2, "%*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %llu %llu", &ut, &st) == 2) {
			ticks += ut + st;
			threads++;
		}
		snprintf(path, sizeof path, "/proc/%d/task/%s/schedstat", pid, e->d_name);
		if (read_file(path, buf, sizeof buf) > 0 && sscanf(buf, "%llu %llu", &run, &w) == 2) {
			wait += w;
			have_wait = 1;
		}
	}
	closedir(d);
	if (!threads) {
		return -1;
	}
	*cpu_ticks = ticks;
	if (have_wait) {
		*wait_ns = wait;
	}
	return have_wait;
}

/* ------------------------------------------------------------------ */
/* Klipper, through Moonraker                                          */

static double json_number(const char *json, const char *key)
{
	char pat[64];
	const char *p;
	snprintf(pat, sizeof pat, "\"%s\":", key);
	p = strstr(json, pat);
	return p ? atof(p + strlen(pat)) : -1;
}

/* How far Klipper has planned ahead of real time, its count of stalls (it
 * ran out of planned moves while printing), and the print's state.
 * Returns 0, or -1 when Moonraker or Klipper did not answer in 300 ms. */
static int klipper_state(double *buffer_s, int *stalls, char *state, size_t state_size)
{
	static const char req[] =
		"GET /printer/objects/query?toolhead=print_time,estimated_print_time,stalls&print_stats=state HTTP/1.0\r\n\r\n";
	static char buf[2048];
	struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons(7125) };
	struct pollfd p;
	size_t len = 0;
	const char *s;
	int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
	int64_t deadline = now_ns(CLOCK_MONOTONIC) + 300000000LL;

	if (fd < 0) {
		return -1;
	}
	sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	connect(fd, (struct sockaddr *)&sa, sizeof sa);
	p.fd = fd;
	p.events = POLLOUT;
	if (poll(&p, 1, 300) <= 0 || write(fd, req, sizeof req - 1) != (ssize_t)(sizeof req - 1)) {
		close(fd);
		return -1;
	}
	p.events = POLLIN;
	while (len < sizeof buf - 1) {
		int left = (int)((deadline - now_ns(CLOCK_MONOTONIC)) / 1000000);
		ssize_t n;
		if (left <= 0 || poll(&p, 1, left) <= 0) {
			break;
		}
		n = read(fd, buf + len, sizeof buf - 1 - len);
		if (n <= 0) {
			break;
		}
		len += n;
	}
	close(fd);
	buf[len] = 0;
	if (!strstr(buf, "\"print_time\"")) {
		return -1;
	}
	*buffer_s = json_number(buf, "print_time") - json_number(buf, "estimated_print_time");
	*stalls = (int)json_number(buf, "stalls");
	s = strstr(buf, "\"state\":\"");
	snprintf(state, state_size, "%.*s", s ? (int)strcspn(s + 9, "\"") : 1, s ? s + 9 : "?");
	return 0;
}

/* ------------------------------------------------------------------ */
/* klippy.log: the shutdown line                                       */

static off_t log_pos = -1;

/* Reads what was appended since the last call, all of it: a shutdown is
 * followed at once by several hundred kilobytes of dumps, and the line that
 * announces it is at their start. Returns 1 and the line when Klipper
 * announced a shutdown. */
static int klippy_shut_down(char *reason, size_t size)
{
	static const char mark[] = "Transition to shutdown state: ";
	static char buf[65536];
	struct stat st;
	int fd, found = 0;

	if (stat(KLIPPY_LOG, &st) < 0) {
		return 0;
	}
	if (log_pos < 0 || st.st_size < log_pos) {
		log_pos = log_pos < 0 ? st.st_size : 0;     /* first call: from now on; rotated: from its start */
	}
	if (st.st_size == log_pos) {
		return 0;
	}
	fd = open(KLIPPY_LOG, O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		return 0;
	}
	while (log_pos < st.st_size) {
		ssize_t n = pread(fd, buf, sizeof buf - 1, log_pos);
		char *p;
		if (n <= 0) {
			break;
		}
		buf[n] = 0;
		p = strstr(buf, mark);
		if (p && !found) {
			snprintf(reason, size, "%.*s", (int)strcspn(p, "\n"), p);
			found = 1;
		}
		/* step back a little, so that a mark across two reads is not missed */
		log_pos += (n == (ssize_t)sizeof buf - 1) ? n - (ssize_t)sizeof mark : n;
	}
	close(fd);
	return found;
}

/* ------------------------------------------------------------------ */
/* Writing a recording                                                 */

static const char header[] =
	"time late_max late_n cpu_user cpu_sys cpu_irq cpu_idle cpu_iowait load1 mem_avail_mb psi_cpu "
	"klippy_cpu klippy_wait mcu_cpu mcu_wait moonraker_cpu moonraker_wait camera_cpu camera_wait nginx_cpu nginx_wait "
	"buffer_s stalls print api_ms wifi_tx_kbit wifi_rx_kbit\n"
	"# late_max: latest of this program's 10 ms wake-ups, ms; late_n: how many came more than 20 ms late\n"
	"# *_cpu: percent of one CPU; *_wait: ms spent ready to run but waiting for a CPU (-1: the kernel does not say)\n"
	"# buffer_s: seconds of movement Klipper has planned ahead; stalls: times it ran out while printing\n"
	"# api_ms: how long Klipper took to answer a status query through Moonraker (-1: no answer in 300 ms)\n";

static void tail_file(const char *from, const char *to, off_t bytes)
{
	static char buf[65536];
	struct stat st;
	int in = open(from, O_RDONLY | O_CLOEXEC), out;
	ssize_t n;
	if (in < 0) {
		return;
	}
	out = open(to, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (out >= 0 && fstat(in, &st) == 0) {
		lseek(in, st.st_size > bytes ? st.st_size - bytes : 0, SEEK_SET);
		while ((n = read(in, buf, sizeof buf)) > 0) {
			if (write(out, buf, n) != n) {
				break;
			}
		}
	}
	if (out >= 0) {
		close(out);
	}
	close(in);
}

static void write_recording(const char *why)
{
	char dir[128], path[192], cmd[512], stamp[32];
	time_t t = time(NULL);
	struct tm tm;
	FILE *f;
	unsigned i;

	localtime_r(&t, &tm);
	strftime(stamp, sizeof stamp, "%Y%m%d-%H%M%S", &tm);
	mkdir(TRACE_DIR, 0755);
	snprintf(dir, sizeof dir, TRACE_DIR "/%s", stamp);
	if (mkdir(dir, 0755) < 0 && errno != EEXIST) {
		fprintf(stderr, "k1os-trace: cannot create %s: %s\n", dir, strerror(errno));
		return;
	}
	snprintf(path, sizeof path, "%s/samples.txt", dir);
	f = fopen(path, "w");
	if (f) {
		fprintf(f, "# %s\n%s", why, header);
		for (i = 0; i < ring_count; i++) {
			fputs(ring[(ring_next + RING - ring_count + i) % RING], f);
		}
		fclose(f);
	}
	snprintf(path, sizeof path, "%s/klippy-tail.log", dir);
	tail_file(KLIPPY_LOG, path, 512 * 1024);
	/* the journal and a process list as they are now; then keep the newest */
	snprintf(cmd, sizeof cmd,
	         "journalctl --since -10min --no-pager > %s/journal.txt 2>&1; "
	         "top -b -n 1 > %s/top.txt 2>&1; "
	         "cd " TRACE_DIR " && ls -1t | tail -n +%d | xargs -r rm -rf; sync",
	         dir, dir, KEEP + 1);
	if (system(cmd) != 0) {
		fprintf(stderr, "k1os-trace: could not save the journal\n");
	}
	fprintf(stderr, "k1os-trace: %s; the last %u s are recorded in %s\n", why, ring_count, dir);
}

/* ------------------------------------------------------------------ */

static uint64_t net_bytes(const char *which)
{
	char path[96], buf[32];
	snprintf(path, sizeof path, "/sys/class/net/wlan0/statistics/%s", which);
	return read_file(path, buf, sizeof buf) > 0 ? strtoull(buf, NULL, 10) : 0;
}

int main(void)
{
	unsigned long long cpu_prev[8] = { 0 };
	uint64_t tx_prev = net_bytes("tx_bytes"), rx_prev = net_bytes("rx_bytes");
	long hz = sysconf(_SC_CLK_TCK);
	int64_t next = now_ns(CLOCK_MONOTONIC), last_note = 0;
	unsigned second = 0;
	char reason[160];

	signal(SIGUSR1, on_usr1);
	signal(SIGPIPE, SIG_IGN);
	klippy_shut_down(reason, sizeof reason);    /* start reading at the end */
	fprintf(stderr, "k1os-trace: recording the last %d s in memory\n", RING);

	for (;;) {
		char *line = ring[ring_next], buf[1024], state[24] = "?", stamp[16];
		unsigned long long cpu[8] = { 0 }, total = 0;
		double late_max = 0, load1 = 0, psi = -1, buffer_s = -1;
		double klippy_wait = -1, idle, api_ms;
		int64_t asked;
		long mem = 0;
		int late_n = 0, stalls = -1, i, len;
		unsigned j;
		uint64_t tx, rx;
		time_t t;
		struct tm tm;

		/* one second of 10 ms wake-ups: how late do they come? */
		for (i = 0; i < 100; i++) {
			struct timespec ts;
			double late;
			next += 10000000LL;
			ts.tv_sec = next / 1000000000LL;
			ts.tv_nsec = next % 1000000000LL;
			while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL) == EINTR) {
			}
			late = (now_ns(CLOCK_MONOTONIC) - next) / 1e6;
			if (late > late_max) {
				late_max = late;
			}
			if (late > 20) {
				late_n++;
			}
			if (late > 1000) {
				next = now_ns(CLOCK_MONOTONIC);     /* do not try to catch up */
			}
		}

		if (second++ % 10 == 0) {
			find_procs();
		}
		if (read_file("/proc/stat", buf, sizeof buf) > 0) {
			sscanf(buf, "cpu %llu %llu %llu %llu %llu %llu %llu %llu", &cpu[0], &cpu[1], &cpu[2],
			       &cpu[3], &cpu[4], &cpu[5], &cpu[6], &cpu[7]);
		}
		for (j = 0; j < 8; j++) {
			total += cpu[j] - cpu_prev[j];
		}
		if (!total) {
			total = 1;
		}
		if (read_file("/proc/loadavg", buf, sizeof buf) > 0) {
			load1 = atof(buf);
		}
		if (read_file("/proc/meminfo", buf, sizeof buf) > 0) {
			char *p = strstr(buf, "MemAvailable:");
			mem = p ? atol(p + 13) / 1024 : 0;
		}
		if (read_file("/proc/pressure/cpu", buf, sizeof buf) > 0) {
			char *p = strstr(buf, "avg10=");
			psi = p ? atof(p + 6) : -1;
		}
		/* how long Klipper takes to answer is a measurement of its own */
		asked = now_ns(CLOCK_MONOTONIC);
		api_ms = klipper_state(&buffer_s, &stalls, state, sizeof state) == 0
		         ? (now_ns(CLOCK_MONOTONIC) - asked) / 1e6 : -1;
		tx = net_bytes("tx_bytes");
		rx = net_bytes("rx_bytes");

		t = time(NULL);
		localtime_r(&t, &tm);
		strftime(stamp, sizeof stamp, "%H:%M:%S", &tm);
#define PCT(i) (100.0 * (cpu[i] - cpu_prev[i]) / total)
		idle = PCT(3);
		len = snprintf(line, LINE, "%s %.0f %d %.0f %.0f %.0f %.0f %.0f %.2f %ld %.1f", stamp, late_max,
		               late_n, PCT(0) + PCT(1), PCT(2), PCT(5) + PCT(6), idle, PCT(4), load1, mem, psi);
		for (j = 0; j < NPROCS; j++) {
			struct proc *p = &procs[j];
			uint64_t ticks = p->cpu_ticks, wait = p->wait_ns;
			double cpu_pct = -1, wait_ms = -1;
			int r = p->pid ? proc_times(p->pid, &ticks, &wait) : -1;
			if (r >= 0 && p->have) {
				cpu_pct = 100.0 * (ticks - p->cpu_ticks) / hz;
				if (r > 0) {
					wait_ms = (wait - p->wait_ns) / 1e6;
				}
			}
			p->have = r >= 0;
			p->cpu_ticks = ticks;
			p->wait_ns = wait;
			if (j == 0) {
				klippy_wait = wait_ms;
			}
			len += snprintf(line + len, LINE - len, " %.0f %.0f", cpu_pct, wait_ms);
		}
		snprintf(line + len, LINE - len, " %.2f %d %s %.0f %.0f %.0f\n", buffer_s, stalls, state, api_ms,
		         (tx - tx_prev) * 8 / 1000.0, (rx - rx_prev) * 8 / 1000.0);
		memcpy(cpu_prev, cpu, sizeof cpu);
		tx_prev = tx;
		rx_prev = rx;
		ring_next = (ring_next + 1) % RING;
		if (ring_count < RING) {
			ring_count++;
		}

		/* worth telling the journal about, at most every ten seconds */
		if ((late_max > LATE_MS || klippy_wait > WAIT_MS) && now_ns(CLOCK_MONOTONIC) - last_note > 10000000000LL) {
			fprintf(stderr, "k1os-trace: wake-ups up to %.0f ms late, Klipper waited %.0f ms for a CPU "
			        "(load %.2f, %.0f %% idle, buffer %.2f s, print %s)\n",
			        late_max, klippy_wait, load1, idle, buffer_s, state);
			last_note = now_ns(CLOCK_MONOTONIC);
		}
		if (klippy_shut_down(reason, sizeof reason)) {
			write_recording(reason);
		} else if (dump_wanted) {
			write_recording("asked for with SIGUSR1");
		}
		dump_wanted = 0;
		/* The sampling above took its time; the next second's wake-ups are
		 * measured from now, not from where this second should have ended. */
		next = now_ns(CLOCK_MONOTONIC);
	}
}
