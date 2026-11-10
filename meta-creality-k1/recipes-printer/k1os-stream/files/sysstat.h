/* k1os-stream: the printer's own load for the statistics panel.
 * MIT License, part of Datel OS. */
#ifndef K1OS_SYSSTAT_H
#define K1OS_SYSSTAT_H

struct sys_stats {
	int cpu_pct;                /* all cores, since the previous sample; -1 = unknown */
	int mem_used_mb, mem_total_mb;  /* total - available; 0 total = unknown */
	int wifi_dbm;               /* 0 = no wireless link */
};

/* Read /proc/stat, /proc/meminfo and /proc/net/wireless. Call it once a
 * second: the CPU share is the busy time since the previous call. */
void sysstat_sample(struct sys_stats *s);

#endif
