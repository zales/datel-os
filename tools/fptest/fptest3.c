/* Which FPU registers change under a task, and to what?
 *
 *   fptest3 <partner registers> <seconds>
 *
 * The victim (CPU 0) loads a known value into each of the 32 FPU registers,
 * spins on integer work for a while, then reads all 32 back together with
 * the control register. Nothing it runs in between touches the FPU.
 * The partner (CPU 1) keeps writing its own recognisable values into the
 * registers named: "none", "low" ($f0-$f13), "high" ($f14-$f31), "all",
 * or one register number.
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define EACH(X) X(0) X(1) X(2) X(3) X(4) X(5) X(6) X(7) X(8) X(9) X(10) X(11) X(12) X(13) X(14) X(15) \
	X(16) X(17) X(18) X(19) X(20) X(21) X(22) X(23) X(24) X(25) X(26) X(27) X(28) X(29) X(30) X(31)

static volatile int stop;
static uint32_t partner_mask;

static void __attribute__((noinline)) load_all(const uint64_t *v)
{
#define LOAD(n) __asm__ __volatile__("ldc1 $f" #n ", %0" : : "m"(v[n]));
	EACH(LOAD)
}

static void __attribute__((noinline)) store_all(uint64_t *v)
{
#define STORE(n) __asm__ __volatile__("sdc1 $f" #n ", %0" : "=m"(v[n]));
	EACH(STORE)
}

static inline uint32_t fcsr(void)
{
	uint32_t v;
	__asm__ __volatile__("cfc1 %0, $31" : "=r"(v));
	return v;
}

static void pin(int cpu)
{
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	sched_setaffinity(0, sizeof set, &set);
}

static void *partner(void *arg)
{
	uint64_t v[32];
	uint32_t round = 0;
	(void)arg;
	pin(1);
	while (!stop) {
		int i;
		round++;
		for (i = 0; i < 32; i++) {
			/* 0xBAD0 in the top, the register number, a counter below */
			v[i] = 0xBAD0000000000000ULL | ((uint64_t)i << 40) | round;
		}
#define PLOAD(n) if (partner_mask & (1u << n)) __asm__ __volatile__("ldc1 $f" #n ", %0" : : "m"(v[n]));
		EACH(PLOAD)
	}
	return NULL;
}

int main(int argc, char **argv)
{
	const char *which = argc > 1 ? argv[1] : "all";
	int secs = argc > 2 ? atoi(argv[2]) : 10, i;
	uint64_t want[32], got[32];
	unsigned long long rounds = 0, bad_rounds = 0, changed[32] = { 0 }, fcsr_changed = 0, partner_values = 0;
	uint32_t fcsr0;
	pthread_t t;
	time_t end;
	int shown = 0;

	partner_mask = !strcmp(which, "none") ? 0 : !strcmp(which, "low") ? 0x00003fff
	               : !strcmp(which, "high") ? 0xffffc000 : !strcmp(which, "all") ? 0xffffffff
	               : 1u << atoi(which);
	for (i = 0; i < 32; i++) {
		want[i] = 0x1111000000000000ULL | ((uint64_t)i << 40) | 0x1234;
	}
	pin(0);
	if (partner_mask) {
		pthread_create(&t, NULL, partner, NULL);
	}
	usleep(100000);
	fcsr0 = fcsr();
	end = time(NULL) + secs;
	while (time(NULL) < end) {
		volatile unsigned long n = 1;
		unsigned long k;
		int bad = 0;
		uint32_t f;
		load_all(want);
		for (k = 0; k < 200000; k++) {
			n = n * 1103515245 + 12345;     /* integers only */
		}
		f = fcsr();
		store_all(got);
		rounds++;
		for (i = 0; i < 32; i++) {
			if (got[i] != want[i]) {
				changed[i]++;
				bad = 1;
				if ((got[i] >> 48) == 0xBAD0) {
					partner_values++;
				}
				if (shown < 6) {
					printf("  round %llu: $f%d = %016llx, was %016llx\n", rounds, i,
					       (unsigned long long)got[i], (unsigned long long)want[i]);
					shown++;
				}
			}
		}
		if (f != fcsr0) {
			fcsr_changed++;
		}
		bad_rounds += bad;
	}
	stop = 1;
	printf("partner writes %-5s: %llu rounds, %llu with a changed register, %llu values were the partner's, FCSR changed %llu times\n",
	       which, rounds, bad_rounds, partner_values, fcsr_changed);
	if (bad_rounds) {
		printf("  changes per register:");
		for (i = 0; i < 32; i++) {
			if (changed[i]) {
				printf(" $f%d:%llu", i, changed[i]);
			}
		}
		printf("\n");
	}
	return 0;
}
