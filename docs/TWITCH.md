# Twitch live stream

The printer streams its camera to Twitch with a status bar in the picture (file, progress, print time, nozzle and bed temperature) and, optionally, a graph panel with the last 20 minutes of temperatures and a progress bar with the remaining time. Decoding and encoding run on the X2000's Helix block; the whole chain costs about 13 % of the two CPU cores at 720p and 8 fps, and the stream title on the channel follows the print automatically.

## Setup

1. **Stream key.** Twitch dashboard, Settings, Stream, Primary Stream key. Put it on the printer and nowhere else:

```bash
ssh root@<ip> 'umask 077; echo TWITCH_KEY=live_xxxxxxxx > /usr/data/k1os/twitch.env'
```

The key is read only by the stream wrapper, which hands it to `k1os-camera` on the printer itself, and never appears in logs, G-code or the Mainsail dialog.

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

Note on `480p`: the stream has the camera's resolution (`CAMERA_RESOLUTION` in `camera.env`), because the Helix has no scaler. The 480p button lowers the bitrate to 1 Mbit/s.

## The picture

`TWITCH_OVERLAY=1` draws the status bar at the bottom. `TWITCH_OVERLAY=2` adds a 320×128 graph panel in a corner (`TWITCH_GRAPH_CORNER=tl|tr|bl|br`, default top right): nozzle (red) and bed (blue) temperature over the last 20 minutes with the targets dashed, a legend with the current values, and a green progress bar with the percentage and the remaining time (`25m left`, `Paused`, `100% Done`; `Idle`, `Cancelled` or `Error` while nothing prints). The history is filled from Moonraker's temperature store at start, so the graph is only empty right after a reboot.

Next to the graph (under it, or above it in a bottom corner) a second panel of the same size shows what the graph does not: chamber and mainboard temperature, the speed of the head and the volumetric flow (for 1.75 mm filament), the height and the part fan, the printer's CPU load and memory in use, the Wi-Fi signal and the bitrate the stream leaves with. A value turns orange when it is worth a look: the board from 70 °C, CPU from 90 %, memory from 85 %, Wi-Fi from -80 dBm down.

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

The encoder is shared with Mainsail's **K1 (WebRTC)** camera and lives in `k1os-camera`: it reads the camera, decodes the JPEG on the Helix, draws the overlay into the NV12 picture and encodes H.264 on the Helix with a userspace rate controller (QP moved one step at a time toward the target bitrate, keyframe every 2 s). `k1os-twitch.service` only asks it to publish (`POST /publish` on 127.0.0.1:8080, accepted from the printer itself alone) and to stop; the daemon speaks RTMP itself, stamps the pictures with its clock, adds a silent AAC track, reconnects after a lost connection and tells Twitch when the stream ends. A slow uplink does not hold up the local viewers: the pictures for Twitch wait in a queue of their own, which is emptied up to the next keyframe when it overflows. The Moonraker component `k1os_stream` draws the dialog, writes `twitch.env`, controls the service and maintains the title through the Twitch Helix API with the `channel:manage:broadcast` scope. Sources: `meta-creality-k1/recipes-printer/k1os-camera/` and `k1os-stream/`.
