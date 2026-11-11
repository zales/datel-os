/* Shows or changes the X2000's CPU clock divider at run time (a test tool).
 *
 *   cpuclk            print CPCCR and the dividers
 *   cpuclk <n>        CPU clock = PLL / n, L2 cache clock = PLL / 2n
 *   cpuclk <n> mpll   the same, from the MPLL (1.5 GHz) instead of the APLL
 *   cpuclk <n> apll   back to the APLL (1.2 GHz)
 *   cpuclk apll <MHz> reprogram the APLL (a multiple of 24 MHz, 600 to 1200)
 *                     and run the CPU from it undivided; while the PLL
 *                     relocks the CPU runs from MPLL / 2
 *
 * CPCCR (CPM base 0x10000000, offset 0): bits 3:0 CPU divider - 1,
 * bits 7:4 L2 cache divider - 1, bit 22 "change enable" for the two,
 * bits 29:28 the source (1 APLL, 2 MPLL);
 * CPAPCR (offset 0x10): bits 28:20 feedback divider - 1, 19:14 reference
 * divider - 1, 13:11 output divider code, bit 3 "locked", bit 0 enable.
 * With reference divider 1 and output code 1 the PLL gives 24 MHz times the
 * feedback divider.
 * CPCSR (offset 0xd4) bit 0 is set while the change is in progress.
 * The kernel is not told: its delay loops become longer than needed, the
 * timers do not depend on this clock.
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	volatile uint32_t *cpm;
	uint32_t v;
	int n, i;
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}
	cpm = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0x10000000);
	if (cpm == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	v = cpm[0];
	printf("CPCCR %08x: CPU = PLL / %u, L2 cache = PLL / %u\n", v, (v & 15) + 1, ((v >> 4) & 15) + 1);
	if (argc < 2) {
		return 0;
	}
	if (argv[1][0] == 'a') {
		uint32_t pll = cpm[0x10 / 4], mhz = argc > 2 ? (uint32_t)atoi(argv[2]) : 0;
		printf("CPAPCR %08x: %u MHz\n", pll, 24 * (((pll >> 20) & 0x1ff) + 1));
		if (!mhz) {
			return 0;
		}
		if (mhz % 24 || mhz < 600 || mhz > 1200 || ((pll >> 14) & 0x3f) != 0 || ((pll >> 11) & 7) != 1) {
			fprintf(stderr, "a multiple of 24 from 600 to 1200, and only from the boot loader's PLL setup\n");
			return 2;
		}
		/* the CPU to MPLL / 2: dividers first, then the source */
		v = (v & ~0xffu) | 1u | 3u << 4 | 1u << 22;
		cpm[0] = v;
		for (i = 0; i < 1000000 && (cpm[0xd4 / 4] & 1); i++) {
		}
		v &= ~(1u << 22);
		cpm[0] = v;
		v = (v & ~(3u << 28)) | 2u << 28;
		cpm[0] = v;
		/* the PLL: off, the new feedback divider, wait for the lock */
		pll = (pll & ~(0x1ffu << 20)) | (mhz / 24 - 1) << 20 | 1u;
		cpm[0x10 / 4] = 0;
		cpm[0x10 / 4] = pll;
		for (i = 0; i < 10000000 && !(cpm[0x10 / 4] & 8); i++) {
		}
		if (!(cpm[0x10 / 4] & 8)) {
			fprintf(stderr, "the APLL did not lock; the CPU stays on MPLL / 2\n");
			return 1;
		}
		/* back: the source first (slower than MPLL / 2 * 2), then the dividers */
		v = (v & ~(3u << 28)) | 1u << 28;
		cpm[0] = v;
		v = (v & ~0xffu) | 0u | 1u << 4 | 1u << 22;
		cpm[0] = v;
		for (i = 0; i < 1000000 && (cpm[0xd4 / 4] & 1); i++) {
		}
		cpm[0] = v & ~(1u << 22);
		pll = cpm[0x10 / 4];
		v = cpm[0];
		printf("CPAPCR %08x: %u MHz; CPCCR %08x: CPU = APLL / %u\n", pll, 24 * (((pll >> 20) & 0x1ff) + 1), v, (v & 15) + 1);
		return 0;
	}
	n = atoi(argv[1]);
	if (n < 1 || n > 8) {
		fprintf(stderr, "divider 1 to 8\n");
		return 2;
	}
	if (argc > 2 && argv[2][0] == 'a' && ((v >> 28) & 3) != 1) {
		/* to the slower source first, then the dividers */
		v = (v & ~(3u << 28)) | 1u << 28;
		cpm[0] = v;
	}
	v = (v & ~0xffu) | (uint32_t)(n - 1) | (uint32_t)(2 * n - 1) << 4 | 1u << 22;
	cpm[0] = v;
	for (i = 0; i < 1000000 && (cpm[0xd4 / 4] & 1); i++) {
	}
	v &= ~(1u << 22);
	cpm[0] = v;
	if (argc > 2 && argv[2][0] == 'm' && ((v >> 28) & 3) != 2) {
		/* the dividers are in place, now the faster source */
		v = (v & ~(3u << 28)) | 2u << 28;
		cpm[0] = v;
	}
	v = cpm[0];
	printf("CPCCR %08x: CPU = %s / %u, L2 cache = PLL / %u\n", v, ((v >> 28) & 3) == 2 ? "MPLL" : "APLL",
	       (v & 15) + 1, ((v >> 4) & 15) + 1);
	return 0;
}
