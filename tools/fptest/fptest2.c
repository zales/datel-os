/* What exactly goes wrong with floating point on two CPUs?
 *
 *   fptest2 <victim> <partner> <seconds>
 *
 * The victim thread runs on CPU 0 and checks itself; the partner runs on
 * CPU 1 and only makes work.
 *
 * victim:   exact    sums and products of whole numbers: the result does not
 *                    depend on the rounding mode, so an error means a value
 *                    in a register or in memory changed
 *           inexact  divisions and square roots: also sensitive to the
 *                    rounding mode and the other control bits
 * partner:  none     no partner
 *           int      integer arithmetic only
 *           fp       the inexact work
 *           fpmove   loads and stores of doubles, no arithmetic
 *           sys      system calls in a loop (getppid)
 *
 * The victim also reads the FPU control register (FCSR) after every round
 * and reports when it is not what it was at the start.
 */
#define _GNU_SOURCE
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile int stop;

static inline uint32_t fcsr(void)
{
	uint32_t v;
	__asm__ __volatile__("cfc1 %0, $31" : "=r"(v));
	return v;
}

static void __attribute__((noinline)) exact(uint64_t out[4])
{
	double a = 0, b = 1, c = 3, d = 0;
	int i;
	for (i = 1; i <= 4000; i++) {
		double x = (double)i;
		a += x;                 /* whole numbers far below 2^53 */
		b = b * 2.0;
		if (b > 1e15) b = 1.0;
		c = c + x * 3.0 - 1.0;
		d = d + (a - c) * 0.5 * 2.0;
	}
	memcpy(&out[0], &a, 8); memcpy(&out[1], &b, 8); memcpy(&out[2], &c, 8); memcpy(&out[3], &d, 8);
}

static void __attribute__((noinline)) inexact(uint64_t out[4])
{
	double a = 1.25, b = 1.0 / 3, c = 2.5, d = -0.75;
	int i;
	for (i = 1; i <= 4000; i++) {
		double x = (double)i;
		a = a * 1.0000001 + b / x;
		b = sqrt(b * b + 1e-3) - d * 1e-9;
		c = c + a * 1e-7 - 7.0 / (x + 3.0);
		d = d * 0.9999999 + 1e-7;
	}
	memcpy(&out[0], &a, 8); memcpy(&out[1], &b, 8); memcpy(&out[2], &c, 8); memcpy(&out[3], &d, 8);
}

/* twelve running values: most of the FPU registers stay in use */
static void __attribute__((noinline)) wide(uint64_t out[4])
{
	double a = 1.25, b = 1.0 / 3, c = 2.5, d = -0.75, e = 1e-3, f = 7.0, g = 0.1, h = 9.75;
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
	a = a + e + p; b = b + f + q; c = c + g + r; d = d + h + s;
	memcpy(&out[0], &a, 8); memcpy(&out[1], &b, 8); memcpy(&out[2], &c, 8); memcpy(&out[3], &d, 8);
}

/* the same twelve values with whole numbers only: no rounding anywhere */
static void __attribute__((noinline)) wide_exact(uint64_t out[4])
{
	double a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, p = 9, q = 10, r = 11, s = 12;
	int i;
	for (i = 1; i <= 4000; i++) {
		double x = (double)i;
		a += x; b += a - x * 2.0; c += b + 1.0; d += x * 3.0 - c * 0.0;
		e += d - a; f += e * 0.5 * 2.0; g += x; h += g - f * 0.0;
		p += h - g; q += p + x; r += q - p; s += r - q + x;
		if (a > 1e12) { a = 1; b = 2; c = 3; d = 4; e = 5; f = 6; g = 7; h = 8; p = 9; q = 10; r = 11; s = 12; }
	}
	a = a + e + p; b = b + f + q; c = c + g + r; d = d + h + s;
	memcpy(&out[0], &a, 8); memcpy(&out[1], &b, 8); memcpy(&out[2], &c, 8); memcpy(&out[3], &d, 8);
}

static void pin(int cpu)
{
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	sched_setaffinity(0, sizeof set, &set);
}

static const char *partner_kind;

static void *partner(void *arg)
{
	uint64_t out[4];
	volatile double store[8] = { 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5 };
	volatile unsigned long n = 0;
	(void)arg;
	pin(1);
	while (!stop) {
		if (!strcmp(partner_kind, "fp")) {
			inexact(out);
		} else if (!strcmp(partner_kind, "wide")) {
			wide(out);
		} else if (!strcmp(partner_kind, "widex")) {
			wide_exact(out);
		} else if (!strcmp(partner_kind, "fpmove")) {
			int i;
			for (i = 0; i < 4000; i++) {
				store[i & 7] = store[(i + 3) & 7];
			}
		} else if (!strcmp(partner_kind, "sys")) {
			int i;
			for (i = 0; i < 200; i++) {
				getppid();
			}
		} else {
			unsigned long i;
			for (i = 0; i < 20000; i++) {
				n = n * 1103515245 + 12345;
			}
		}
	}
	return NULL;
}

int main(int argc, char **argv)
{
	const char *victim = argc > 1 ? argv[1] : "inexact";
	int secs = argc > 3 ? atoi(argv[3]) : 20;
	void (*work)(uint64_t *) = !strcmp(victim, "exact") ? exact : !strcmp(victim, "wide") ? wide
	                           : !strcmp(victim, "widex") ? wide_exact : inexact;
	uint64_t ref[4], got[4];
	unsigned long long rounds = 0, wrong = 0, fcsr_changed = 0;
	uint32_t fcsr0, seen = 0;
	pthread_t t;
	time_t end;

	partner_kind = argc > 2 ? argv[2] : "fp";
	pin(0);
	work(ref);
	fcsr0 = fcsr();
	if (strcmp(partner_kind, "none")) {
		pthread_create(&t, NULL, partner, NULL);
	}
	end = time(NULL) + secs;
	while (time(NULL) < end) {
		uint32_t now;
		work(got);
		rounds++;
		if (memcmp(got, ref, sizeof got)) {
			wrong++;
		}
		now = fcsr();
		if (now != fcsr0) {
			fcsr_changed++;
			seen = now;
			/* put it back, so that every change is counted on its own */
			__asm__ __volatile__("ctc1 %0, $31" : : "r"(fcsr0));
		}
	}
	stop = 1;
	printf("victim %-7s partner %-6s: %llu rounds, %llu wrong, FCSR changed %llu times (start %08x, last other value %08x)\n",
	       victim, partner_kind, rounds, wrong, fcsr_changed, fcsr0, seen);
	return 0;
}
