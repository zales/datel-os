/* k1os-stream: printer state from Moonraker. MIT License, part of Datel OS. */
#ifndef MOONRAKER_H
#define MOONRAKER_H

#include <stdint.h>

struct printer_state {
	int valid;                  /* 0 while Moonraker has not answered */
	char state[32];             /* standby, printing, paused, complete, error, cancelled */
	char filename[128];
	double progress;            /* 0..1 */
	double print_duration;      /* s */
	double nozzle, nozzle_target, bed, bed_target;
	/* for the statistics panel; a have_ flag is 0 when the printer has no such object */
	int have_chamber, have_mcu_temp, have_motion, have_fan;
	double chamber, mcu_temp;   /* degrees */
	double speed;               /* toolhead, mm/s */
	double flow;                /* extruded filament, mm3/s (1.75 mm filament) */
	double z;                   /* mm */
	double fan;                 /* part cooling fan, 0..1 */
};

/* Temperature history, one sample a second, newest last; tenths of a degree,
 * TEMP_NONE where no sample exists (Moonraker unreachable). */
#define HISTORY_N 1200          /* 20 minutes */
#define TEMP_NONE INT16_MIN

struct temp_history {
	unsigned n;                 /* samples valid, in [0] .. [n-1] */
	int16_t nozzle[HISTORY_N], nozzle_target[HISTORY_N];
	int16_t bed[HISTORY_N], bed_target[HISTORY_N];
};

/* Start a thread that queries http://host:port once a second. With history,
 * it first loads /server/temperature_store so the graph starts full. */
int moonraker_start(const char *host, int port, int history);
/* End that thread and wait for it; start may be called again afterwards. */
void moonraker_stop(void);
/* Copy the latest state (thread safe). */
void moonraker_get(struct printer_state *out);
/* Copy the history in chronological order (thread safe). */
void moonraker_history_get(struct temp_history *out);

#endif
