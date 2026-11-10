/* k1os-stream: the printer's own load. MIT License, part of Datel OS. */
#include <stdio.h>
#include <string.h>

#include "sysstat.h"

void sysstat_sample(struct sys_stats *s)
{
	static unsigned long long prev_busy, prev_total;
	static int have_prev;
	char line[256];
	FILE *f;

	s->cpu_pct = -1;
	s->mem_used_mb = s->mem_total_mb = 0;
	s->wifi_dbm = 0;

	/* "cpu user nice system idle iowait irq softirq steal": idle + iowait is not busy */
	f = fopen("/proc/stat", "r");
	if (f) {
		unsigned long long v[8] = { 0 };
		if (fgets(line, sizeof line, f) &&
		    sscanf(line, "cpu %llu %llu %llu %llu %llu %llu %llu %llu",
		           &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) >= 4) {
			unsigned long long total = 0, busy;
			int i;
			for (i = 0; i < 8; i++) {
				total += v[i];
			}
			busy = total - v[3] - v[4];
			if (have_prev && total > prev_total) {
				s->cpu_pct = (int)((busy - prev_busy) * 100 / (total - prev_total));
			}
			prev_busy = busy;
			prev_total = total;
			have_prev = 1;
		}
		fclose(f);
	}

	f = fopen("/proc/meminfo", "r");
	if (f) {
		unsigned long total = 0, avail = 0, kb;
		while (fgets(line, sizeof line, f)) {
			if (sscanf(line, "MemTotal: %lu", &kb) == 1) {
				total = kb;
			} else if (sscanf(line, "MemAvailable: %lu", &kb) == 1) {
				avail = kb;
				break;
			}
		}
		fclose(f);
		if (total && avail <= total) {
			s->mem_total_mb = (int)(total / 1024);
			s->mem_used_mb = (int)((total - avail) / 1024);
		}
	}

	/* " wlan0: 0000   43.  -67.  -256 ...": the fourth field is the level in dBm */
	f = fopen("/proc/net/wireless", "r");
	if (f) {
		while (fgets(line, sizeof line, f)) {
			char *colon = strchr(line, ':');
			float link, level;
			unsigned status;
			if (colon && sscanf(colon + 1, "%x %f %f", &status, &link, &level) == 3 && level < 0) {
				s->wifi_dbm = (int)level;
				break;
			}
		}
		fclose(f);
	}
}
