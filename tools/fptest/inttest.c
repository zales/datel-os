/* The same idea as fptest with integers only: two threads, one per CPU, each
 * repeating a fixed calculation (multiplications, shifts, memory traffic)
 * and comparing with its first result.   inttest <seconds> */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static volatile int stop;
static unsigned long long rounds[2], wrong[2];
static uint64_t __attribute__((noinline)) work(uint32_t *buf, int n)
{
	uint64_t h = 1469598103934665603ULL;
	uint32_t x = 12345;
	int i;
	for (i = 0; i < n; i++) {
		x = x * 1664525u + 1013904223u;
		buf[i] = x ^ (x >> 13);
	}
	for (i = 0; i < n; i++) {
		h = (h ^ buf[i]) * 1099511628211ULL;
		h += (uint64_t)buf[(i * 7) % n] * buf[(i * 13) % n];
	}
	return h;
}
static void *thread(void *arg)
{
	int id = (int)(intptr_t)arg;
	static uint32_t bufs[2][8192];
	cpu_set_t set;
	uint64_t ref;
	CPU_ZERO(&set); CPU_SET(id, &set);
	sched_setaffinity(0, sizeof set, &set);
	ref = work(bufs[id], 8192);
	while (!stop) {
		rounds[id]++;
		if (work(bufs[id], 8192) != ref) wrong[id]++;
	}
	return NULL;
}
int main(int argc, char **argv)
{
	pthread_t t[2];
	int i;
	for (i = 0; i < 2; i++) pthread_create(&t[i], NULL, thread, (void *)(intptr_t)i);
	sleep(argc > 1 ? atoi(argv[1]) : 20);
	stop = 1;
	for (i = 0; i < 2; i++) pthread_join(t[i], NULL);
	printf("integers on both CPUs: %llu rounds, %llu wrong\n", rounds[0] + rounds[1], wrong[0] + wrong[1]);
	return 0;
}
