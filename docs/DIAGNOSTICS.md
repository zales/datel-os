# Diagnostics and staying alive

What Datel OS does so that a printer in trouble recovers by itself and leaves a trace of what happened. The background is in [NOTES.md](NOTES.md), 10 November 2026.

## Hardware watchdog

systemd pings the X2000's watchdog (`RuntimeWatchdogSec=30s`). When the system stops, the SoC resets after 30 s and boots again. A print that was running is lost either way; what the watchdog saves is the trip to the power switch.

The watchdog watches systemd only. A system that is merely very slow keeps pinging; that case is what the memory settings below are for.

## The journal survives a reboot

The journal lives in RAM. `k1os-bootlog` writes this boot's journal to `/usr/data/k1os/log/journal-last.txt` 30 s and 5 min after boot (later lines go to the log server and to `k1os-trace`), and on its first run after a boot moves the previous file to `journal-prev.txt`:

```bash
ssh root@<ip> tail -n 50 /usr/data/k1os/log/journal-prev.txt
```

The last minute before a hang can be missing from it. For the last seconds, send the journal away.

## Sending the journal to another machine

`k1os-logstream` pipes the journal to a syslog server over TCP, one line per message. It starts when `/usr/data/k1os/logstream.env` exists:

```bash
ssh root@<ip> 'echo LOG_REMOTE=\"192.168.1.10 514\" > /usr/data/k1os/logstream.env && systemctl restart k1os-logstream'
```

On the receiving side anything that takes plain lines over TCP will do. With rsyslog (`/etc/rsyslog.d/10-remote.conf`):

```
module(load="imtcp")
template(name="RemotePerHostFile" type="string" string="/var/log/remote/%fromhost-ip%/%$year%-%$month%-%$day%.log")
template(name="RemoteLine" type="string" string="%timegenerated:::date-rfc3339% %rawmsg-after-pri%\n")
ruleset(name="remote") { action(type="omfile" dynaFile="RemotePerHostFile" template="RemoteLine") }
input(type="imtcp" port="514" ruleset="remote")
```

When the connection drops the service reconnects after 10 s and sends the last 2000 lines again, so the file can hold duplicates. `klippy.log` and `moonraker.log` are files in `/usr/data/k1os/printer_data/logs` and are not part of the stream; Moonraker's messages are, because it also writes to the journal.

## The health line

Once a minute `k1os-health` writes one line to the journal:

```
load=2.16 1.58 1.20 mem_avail=76M swap=0M mem_psi=0.00 tmpfs=17M top=python3:37M,python3:36M,go2rtc:30M,main:12M wifi=-78dBm print=printing mcu=40.15C chamber=29.25C bed=54.79C nozzle=230.31C tmc=ok retx=9/9/0
```

| Field | Meaning |
|---|---|
| `load` | load average over 1, 5 and 15 minutes (two cores) |
| `mem_avail`, `swap` | memory still available, swap in use |
| `mem_psi` | share of the last 10 s in which some process waited for memory |
| `tmpfs` | RAM held by tmpfs; the journal is in there |
| `top` | the four biggest processes by resident memory |
| `wifi` | signal of the link; below about -80 dBm the camera stream starts to suffer |
| `print` | Klipper's print state |
| `mcu`, `chamber`, `bed`, `nozzle` | temperatures from Klipper; `mcu` is the MCU on the mainboard, the nearest reading to the SoC, which has no sensor the kernel exposes |
| `tmc` | `ok`, or the stepper drivers that report a flag beyond the normal ones. `ola`/`olb` (open load) show up at standstill and low speed without anything being wrong; `otpw`, `ot` and `s2ga`/`s2gb` deserve attention |
| `retx` | serial retransmits to the three MCUs since Klipper started; a number that keeps growing points at interference or power |

To read only these lines: `journalctl -t k1os-health`, or `grep k1os-health` on the machine the journal is sent to.

## The flight recorder

`k1os-trace` answers "what was the system doing when the print died". Once a second it samples how late its own 10 ms wake-ups come, the CPU split, CPU time and run-queue wait of Klipper, the host MCU, Moonraker, the camera and nginx, Klipper's move buffer and stall count, and the Wi-Fi traffic. The last 900 s stay in memory. When `klippy.log` says "Transition to shutdown state", they are written to `/usr/data/k1os/trace/<time>/`:

| File | Contents |
|---|---|
| `samples.txt` | one line a second, the column names in the second line |
| `klippy-tail.log` | the end of `klippy.log` with Klipper's own dump |
| `journal.txt` | the last ten minutes of the journal |
| `top.txt` | the processes at that moment |

`kill -USR1 $(pidof k1os-trace)` writes a recording at any time. A second in which a wake-up came more than 50 ms late or Klipper waited more than 200 ms for a CPU is also noted in the journal (`journalctl -t k1os-trace`).

Two things to know when reading it. `klippy_wait` is the sum over all of Klipper's threads in that second, not one stall. And `buffer_s` is Klipper's planning buffer of moves, not the steps already at the MCU: those go out 3 s ahead ([KALICO.md](KALICO.md#known-behaviour)).

## CPU clock and floating point

The stock boot loader runs the X2000 at 1200 MHz. At that speed the reference printer computes wrong floating point results now and then. Kalico turns one into a step that lies before the previous one and shuts down in the middle of a print:

```
stepcompress o=3 i=-19732 c=1 a=0: Invalid sequence
Internal error in stepcompress
```

`tools/fptest/fptest.c` repeats a fixed double calculation in several threads and compares every result bit for bit with the first; `tools/fptest/cpuclk.c` changes the clock on a running system. Four threads on both CPUs with the bed at 60 °C, 11 November 2026:

| CPU clock | Wrong results |
|---|---|
| 1200 MHz | about 83 rounds a minute (1 in 1000) |
| 1008 MHz | 7 in 3 minutes |
| 912 MHz | none in 25 minutes (1.28 million rounds) |
| 750 MHz | none, and a print of 127 minutes without a step error |

The kernel therefore reprograms the PLL at boot (`CONFIG_CLK_X2000_CPU_MHZ=816`, one 96 MHz step below the highest clean frequency) and says so:

```bash
ssh root@<ip> 'dmesg | grep "CPU clock"'
```

What is known and what is not: integer tests pass at 1200 MHz; a kernel without MSA and a kernel that uses the FPU on one CPU only behave the same, so it is not the kernel's FPU context code; the errors are more frequent on a warm printer and right after a print. What exactly is marginal was not found, and neither was whether other K1s do the same: the stock firmware runs at 1200 MHz too and was not tested.

To test a printer, build the tools with any MIPS cross compiler (`mipsel`, `-mips32r2 -mfp64 -mnan=2008 -static`, link `-lm -lpthread`) and run them for at least 25 minutes on a warm printer; a short run on a cold one gives zero at any clock and misleads:

```bash
./fptest 4 1500
```

## Out of memory

The printer has 216 MB of RAM for Linux. Three things keep a shortage from freezing it:

- **Swap in zram**, half the size of the RAM (`k1os-zram-swap`). Data that is not in use is compressed in place instead of program code being dropped and read back from the xz-compressed root.
- **The kernel kills a process instead of thrashing.** The multi-gen LRU's `min_ttl_ms` is 1000: when what was used in the last second cannot be kept in memory, the OOM killer runs.
- **The print is the last to go.** `OOMScoreAdjust`: Twitch stream 700, a timelapse render 500, the camera daemon 300, Moonraker -300, Klipper and its host MCU -900.

Tested by a process that takes 8 MB a second: it was killed after 19 s, the printer answered every second in between and Klipper stayed ready.
