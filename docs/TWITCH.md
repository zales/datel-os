# Twitch live stream

The printer streams its camera to Twitch with a status bar in the picture (file, progress, print time, nozzle and bed temperature) and, optionally, a graph panel with the last 20 minutes of temperatures and a progress bar with the remaining time. Decoding and encoding run on the X2000's Helix block; the whole chain costs about 13 % of the two CPU cores at 720p and 8 fps, and the stream title on the channel follows the print automatically.

## Setup

1. **Stream key.** Twitch dashboard, Settings, Stream, Primary Stream key. Put it on the printer and nowhere else:

```bash
ssh root@<ip> 'umask 077; echo TWITCH_KEY=live_xxxxxxxx > /usr/data/k1os/twitch.env'
```

The key is read only by the stream wrapper, is passed to ffmpeg outside the URL, and never appears in logs, G-code or the Mainsail dialog.

2. **Automatic title (optional).** Register an application at https://dev.twitch.tv/console/apps (any name, client type Public, any redirect URL such as `http://localhost`). The Client ID is not a secret; add it to `twitch.env`:

```
TWITCH_CLIENT_ID=<client id>
```

Then run `TWITCH_LOGIN` in Mainsail (console or the dialog's Login button). The console shows `https://www.twitch.tv/activate` and an eight-letter code; enter it there as the channel owner. The printer stores the tokens in `/usr/data/k1os/twitch-auth.json` (mode 600) and refreshes them itself.

3. **Start.** In Mainsail press the `TWITCH` macro button (also in OrcaSlicer's device tab).

## The dialog and the macros

`TWITCH` opens a dialog with Start, Stop, `720p / 2.5 Mbit`, `480p / 1 Mbit`, the overlay (`Overlay off`, `Text`, `Text + graph`), the ingest server (EU = Prague, US = Ashburn, auto), Status, Login and Close. It shows the current state and redraws after every choice. The same from the console:

| Macro | Effect |
|---|---|
| `TWITCH_START`, `TWITCH_STOP` | Start and stop the stream |
| `TWITCH_SET RESOLUTION=1280x720 BITRATE=2500 OVERLAY=0\|1\|2 INGEST=eu\|us\|auto` | Change settings; a running stream restarts when a video setting changes |
| `TWITCH_STATUS` | State, settings and the composed title in the console |
| `TWITCH_LOGIN` | Device code login for the title |

The service `k1os-twitch` also appears in Mainsail's host menu and can be started with `systemctl start k1os-twitch`. While the stream runs, the console shows `Twitch: live`, and the display line reads `Twitch: live 2.4 Mbit/s 00:12:31` (`TWITCH_M117=0` turns that off).

Note on `480p`: with uStreamer running, which is the normal case, the stream has the camera's resolution because the frames come from uStreamer's memory sink and the Helix has no scaler. The 480p button then lowers the bitrate to 1 Mbit/s.

## The picture

`TWITCH_OVERLAY=1` draws the status bar at the bottom. `TWITCH_OVERLAY=2` adds a 320×128 graph panel in a corner (`TWITCH_GRAPH_CORNER=tl|tr|bl|br`, default top right): nozzle (red) and bed (blue) temperature over the last 20 minutes with the targets dashed, a legend with the current values, and a green progress bar with the percentage and the remaining time (`25m left`, `Paused`, `100% Done`; `Idle`, `Cancelled` or `Error` while nothing prints). The history is filled from Moonraker's temperature store at start, so the graph is only empty right after a reboot.

Lines are thick and digits large on purpose: NV12 chroma has a quarter of the luma resolution and a 2.5 Mbit/s stream smears thin detail.

## The title

While the stream runs, the channel title is set from Klipper's state in this shape:

```
🖨️ bed_sheet_2layers_ABS | 🚀 99% done | ⏰ 2h47m elapsed | 🔥 Hotend 218.8/0°C (cooling) 🛏️ Bed 60.0/0°C (cooling) | ✅ printing
```

`(heating)` means the target is more than 1 °C above the current value, `(cooling)` a target of 0 with the part above 40 °C. States: standby 💤, printing ✅, paused ⏸️, complete 🏁, cancelled ❌, error ⚠️. The file name loses `.gcode` and is shortened first when the 140 characters Twitch allows would be exceeded. The title is sent at once when the state or file changes and otherwise at most once a minute, only when the text changed. When the stream starts, the category is set once to `Makers & Crafting`.

## All options

`/usr/data/k1os/twitch.env`; the full list with comments is in `/etc/k1os/twitch.env.example` on the printer.

| Variable | Default | Meaning |
|---|---|---|
| `TWITCH_KEY` | | Stream key (required) |
| `TWITCH_INGEST` | `rtmp://live.twitch.tv/app` | Ingest server; the dialog's EU is `live-prg`, US is `live-iad` |
| `TWITCH_BITRATE` | `2500` | Video bitrate in kbit/s |
| `TWITCH_RESOLUTION` | `1280x720` | Applies only when `k1os-stream` captures the camera itself |
| `TWITCH_OVERLAY` | `1` | 0 camera only, 1 status bar, 2 status bar and graph |
| `TWITCH_GRAPH_CORNER` | `tr` | Corner of the graph panel |
| `TWITCH_FPS` | camera's `CAMERA_FPS` | Stream frame rate |
| `TWITCH_AUTOSTART` | `0` | Start the stream at every boot |
| `TWITCH_CLIENT_ID` | | Client ID for the title API |
| `TWITCH_CHANNEL` | login from `TWITCH_LOGIN` | Channel name, shown in the dialog |
| `TWITCH_TITLE_TEMPLATE` | see above | Jinja template; placeholders `file`, `progress`, `elapsed`, `hotend`, `bed`, `hotend_temp`, `hotend_target`, `bed_temp`, `bed_target`, `state`, `state_emoji`, `layer`, `total_layers`, `channel`, `message` |
| `TWITCH_IDLE_TITLE` | unchanged | Title set when the stream stops |
| `TWITCH_CATEGORY` | `Makers & Crafting` | Category set at stream start; empty leaves it |
| `TWITCH_M117` | `1` | Status line on the printer display |

## Watching the stream

The dialog shows the address, `twitch.tv/<channel>`; open it in a browser. Mainsail's camera **K1 (WebRTC)** shows the same picture as the stream, overlay included, without the stream's delay; the camera **K1** shows it plain from uStreamer. There is deliberately no Twitch player inside Mainsail: Twitch embeds its player only into HTTPS pages served under a registered host name, and Mainsail on the printer is plain HTTP by IP address. A webcam `Twitch` left over from an earlier release is removed at the next Moonraker start.

## Requirements and limits

- Wi-Fi: the K1 has 2.4 GHz only. 720p at 2.5 Mbit/s fits next to Mainsail's MJPEG stream; 1080p does not.
- The stream and a timelapse render can run at the same time; the V4L2 driver serialises the codec jobs.
- Measured on the reference printer: 1280×720 at 8 fps, 2.0 to 2.6 Mbit/s around the 2500 kbit/s target, keyframes every 2 s, 0 skipped frames in the Twitch player, 6.8 s latency, codec H.264 Main 3.1.

## How it works

The encoder is shared with Mainsail's **K1 (WebRTC)** camera: go2rtc runs `ustreamer-dump --sink=k1os::jpeg | k1os-stream` (`/usr/libexec/k1os/h264-source`) while anyone watches, and `k1os-twitch.service` reads it as fragmented MP4 (`wget …/go2rtc/api/stream.mp4?src=k1 | ffmpeg … -f flv rtmp://…`); stopping the stream ends only the reader. Without go2rtc running, `k1os-twitch.service` runs the pipeline below itself: `ustreamer-dump --sink=k1os::jpeg | k1os-stream | ffmpeg … -f flv rtmp://…`. uStreamer, which serves Mainsail, publishes every frame into a shared-memory sink; `k1os-stream` decodes the JPEG on the Helix, draws the overlay into the NV12 picture, encodes H.264 on the Helix with a userspace rate controller (QP moved one step per frame toward the target bitrate, keyframe every 2 s) and writes a raw stream; ffmpeg stamps it with the wall clock, adds a silent AAC track and muxes to RTMP. The Moonraker component `k1os_stream` draws the dialog, writes `twitch.env`, controls the service and maintains the title through the Twitch Helix API with the `channel:manage:broadcast` scope. Source: `meta-creality-k1/recipes-printer/k1os-stream/`.
