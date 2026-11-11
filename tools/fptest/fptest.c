/* Do floating point results survive being interrupted?
 *
 * Several threads each repeat the same calculation over and over: a few
 * thousand steps of double arithmetic that keeps many values in FPU registers
 * at once. Every repetition must give bit for bit the result of the first.
 * On the K1 a different result turned out to depend on the CPU clock (wrong
 * ones at 1200 and 1008 MHz, none at 912 and below; cpuclk.c changes the
 * clock), not on how the kernel saves the FPU state. Run it for 25 minutes
 * on a warm printer: short runs on a cold one give zero and mislead.
 *
 *   fptest <threads> <seconds> [mode]
 *
 * mode: "threads" (default); "procs": separate processes instead of threads;
 * "onecpu": threads, all kept on CPU 0; "owncpu": thread n kept on CPU n % 2.
 */
#define _GNU_SOURCE
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <sys/wait.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static volatile int stop;
static uint64_t reference[8];
static unsigned long long rounds[64], errors[64];

/* Twelve running values, so that most of the FPU registers stay in use across
 * the loop. The seed makes each thread's work the same but the registers'
 * contents distinctive. */
static void __attribute__((noinline)) work(double seed, uint64_t out[8])
{
	double a = seed, b = 1.0 / 3, c = 2.5, d = -0.75, e = 1e-3, f = 7.0, g = 0.1, h = 9.75;
	double p = 1.0, q = 2.0, r = 3.0, s = 4.0;
	int i;
	for (i = 1; i <= 4000; i++) {
		double x = (double)i;
		a = a * 1.0000001 + b / x;
		b = sqrt(b * b + e) - d * 1e-9;
		c = c + a * 1e-7 - f / (x + 3.0);
		d = d * 0.9999999 + g * 1e-6;
		e = e + 1.0 / (x * x + h);
		f = f - c * 1e-8 + p * 1e-12;
		g = g * 1.0000003 - q * 1e-13;
		h = h + sqrt(x) * 1e-6 - r * 1e-14;
		p = p + a * b * 1e-9;
		q = q - c * d * 1e-9;
		r = r + e * f * 1e-9;
		s = s + g * h * 1e-9;
	}
	memcpy(&out[0], &a, 8); memcpy(&out[1], &b, 8); memcpy(&out[2], &c, 8); memcpy(&out[3], &d, 8);
	a = e + f + g + h;
	b = p + q + r + s;
	memcpy(&out[4], &a, 8); memcpy(&out[5], &b, 8); memcpy(&out[6], &p, 8); memcpy(&out[7], &s, 8);
}

static int pin_mode;     /* 0 none, 1 all on CPU 0, 2 thread n on CPU n % 2 */

static void *thread(void *arg)
{
	int id = (int)(intptr_t)arg;
	uint64_t got[8];
	if (pin_mode) {
		cpu_set_t set;
		CPU_ZERO(&set);
		CPU_SET(pin_mode == 1 ? 0 : id % 2, &set);
		sched_setaffinity(0, sizeof set, &set);
	}
	while (!stop) {
		work(1.25, got);
		rounds[id]++;
		if (memcmp(got, reference, sizeof got)) {
			int i;
			errors[id]++;
			if (errors[id] <= 3) {
				fprintf(stderr, "thread %d round %llu: WRONG RESULT\n", id, rounds[id]);
				for (i = 0; i < 8; i++) {
					if (got[i] != reference[i]) {
						double x, y;
						memcpy(&x, &got[i], 8);
						memcpy(&y, &reference[i], 8);
						fprintf(stderr, "  value %d: %016llx (%.17g), expected %016llx (%.17g)\n", i,
						        (unsigned long long)got[i], x, (unsigned long long)reference[i], y);
					}
				}
			}
		}
		/* odd threads give up the CPU now and then, for more switches */
		if ((id & 1) && rounds[id] % 64 == 0) {
			usleep(100);
		}
	}
	return NULL;
}

int main(int argc, char **argv)
{
	int n = argc > 1 ? atoi(argv[1]) : 4, secs = argc > 2 ? atoi(argv[2]) : 60, i;
	pthread_t t[64];
	unsigned long long total = 0, bad = 0;
	if (n < 1 || n > 64) {
		return 2;
	}
	const char *mode = argc > 3 ? argv[3] : "threads";
	work(1.25, reference);
	pin_mode = !strcmp(mode, "onecpu") ? 1 : !strcmp(mode, "owncpu") ? 2 : 0;
	if (!strcmp(mode, "procs")) {
		/* each child is a process of its own, with one thread */
		int status, failed = 0;
		for (i = 0; i < n; i++) {
			if (fork() == 0) {
				char *child[] = { argv[0], "1", argv[2], NULL };
				execv("/proc/self/exe", child);
				_exit(127);
			}
		}
		for (i = 0; i < n; i++) {
			wait(&status);
			failed += status != 0;
		}
		printf("%d processes: %d reported wrong results\n", n, failed);
		return failed ? 1 : 0;
	}
	for (i = 0; i < n; i++) {
		pthread_create(&t[i], NULL, thread, (void *)(intptr_t)i);
	}
	sleep(secs);
	stop = 1;
	for (i = 0; i < n; i++) {
		pthread_join(t[i], NULL);
		total += rounds[i];
		bad += errors[i];
	}
	printf("%d threads, %d s: %llu rounds, %llu with a wrong result\n", n, secs, total, bad);
	return bad ? 1 : 0;
}
