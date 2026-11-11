# Camera and timelapse

## Camera

The K1 camera is a USB UVC device (Sonix 0c45:6366) that produces MJPEG and H.264 in hardware. Datel OS serves it with one small daemon of its own, `k1os-camera` (`k1os-camera.service`, written in Zig): the MJPEG frames unchanged, snapshots, H.264 over WebRTC and the Twitch stream. nginx exposes it at `http://<ip>/webcam/?action=stream` and `?action=snapshot`. The camera node is found automatically (the USB node with index 0), and the camera is registered in Moonraker once on the first boot, so Mainsail shows it without setup. The camera is open only while something uses it, and for a minute after the last snapshot; the first snapshot after a pause takes almost two seconds, the following ones well under a tenth.

Defaults: 1280×720 at 8 fps, about 6 Mbit/s. 15 fps is about 12 Mbit/s and stutters on a weak 2.4 GHz link. Change it in `/usr/data/k1os/camera.env`:

```
CAMERA_RESOLUTION=1280x720
CAMERA_FPS=8
```

The setting applies the next time the camera is opened; `systemctl restart k1os-camera` applies it at once. Keep the frame rate in Mainsail's camera settings in step.

### Cameras in Mainsail

Moonraker gets three cameras, all from the same camera:

| Camera | Player | Bandwidth | Notes |
|---|---|---|---|
| **K1 (WebRTC)** | `webrtc-camerastreamer` | about 2.5 Mbit/s | H.264 from the Helix codec, the same picture and encoder as the Twitch stream (overlay included). Mainsail's camera on first boot |
| **K1** | `mjpegstreamer` | about 6 Mbit/s | The camera's own MJPEG frames, no re-encoding |
| **K1 (snapshots)** | `mjpegstreamer-adaptive` | depends on the link | Snapshot polling at up to 5 fps, for slow links |

Mainsail shows every camera at once until one is picked, and the pick is stored for all browsers; the first boot picks **K1 (WebRTC)**, an update from an older release does that once as well.

`k1os-camera` starts the encoder (k1os-stream's pipeline, built into it: JPEG decode, overlay and H.264 on the Helix) for the first viewer and stops it after the last one leaves, so the WebRTC camera costs nothing while nobody watches. A viewer who joins gets a key picture at once and sees the picture in under half a second. The picture follows the Twitch settings in `/usr/data/k1os/twitch.env` (bitrate, frame rate, overlay); changing them in the TWITCH dialog restarts `k1os-camera`, and an open WebRTC view reconnects. Signalling is camera-streamer's protocol, `POST /webcam/webrtc`; the daemon is an ICE-lite agent and offers one UDP port per viewer on the address that viewer reached the printer by, so it works on the local network and over a VPN, not through NAT. Packets a viewer reports as lost are sent again. With one WebRTC viewer the daemon uses about 2 MB of memory and 8 % of one core, encoder included.

### Viewer limits

`k1os-camera` has four places for WebRTC viewers, and nginx lets in two MJPEG streams at a time (`limit_conn` in `/etc/nginx/sites-enabled/mainsail`): an MJPEG stream is about 6 Mbit/s on the 2.4 GHz link, a WebRTC viewer 2.5 Mbit/s. One MJPEG viewer more gets a 503 and Mainsail's player tries again until a place is free. Snapshots are not counted, so the timelapse and the **K1 (snapshots)** camera always work. The limits guard the printer's resources; they are not an access control.

### OrcaSlicer

OrcaSlicer's device tab on macOS is an embedded WebKit browser. WebKit fails a `fetch()` of a `multipart/x-mixed-replace` body ("Load failed"), and Mainsail's MJPEG player reads the stream with `fetch()`, so it reported "Error while connecting to …/webcam/?action=stream". nginx now labels the same bytes `multipart/mixed` for that request (Mainsail's worker sends `Accept: */*` and `?timestamp=`); an `<img>` or a browser tab still gets `multipart/x-mixed-replace`. All three cameras work there, **K1 (WebRTC)** included.

## Timelapse

Timelapse uses [moonraker-timelapse](https://github.com/mainsail-crew/moonraker-timelapse) for the frames and the Mainsail panel, and renders the video on the X2000's Helix hardware encoder instead of a software x264. Rendering a print takes seconds and little CPU.

| Part | What it does |
|---|---|
| Moonraker component `[timelapse]` | Takes a snapshot per layer or per interval, offers the Timelapse panel in Mainsail. Frames go to `/usr/data/k1os/timelapse/frames/`, videos to `/usr/data/k1os/timelapse/` |
| `k1os-helix-enc` | Decodes the JPEG frames (libjpeg-turbo, or the Helix with `-H`) and encodes them through `/dev/video1` into an H.264 stream |
| `timelapse-render` | Stands in for ffmpeg in the component's configuration (there is no ffmpeg on the printer): runs the codec and lets `h264-to-mp4` write the MP4 file around the stream. Rotating or flipping is not possible on this path |

### Use

1. In the slicer, add `TIMELAPSE_TAKE_FRAME` to the layer change G-code (OrcaSlicer: Printer settings, Machine G-code, Layer change G-code). Alternatively choose the `hyperlapse` mode in the Timelapse panel, which takes a frame every 30 s without slicer changes.
2. Print. The panel shows the frames and renders the video when the print ends; `TIMELAPSE_RENDER` renders on demand.
3. The video appears in the Timelapse panel and under `/usr/data/k1os/timelapse/`.

The panel's CRF setting becomes the encoder's fixed quantiser (QP = CRF + 5, default 28). The macros are included by `k1os_kalico.cfg`; a printer converted before 8 November 2026 needs `[include /usr/share/k1os/timelapse.cfg]` added by hand.

### Options

`/usr/data/k1os/timelapse.env`:

| Variable | Effect |
|---|---|
| `HELIX_QP=28` | Quantiser when the panel's CRF is not used |
| `HELIX_GOP=30` | Keyframe interval in frames |
| `HELIX_JPEG=1` | Decode the JPEG frames on the Helix too (10 ms a frame instead of 49 ms). Off by default, see [NOTES.md](NOTES.md) |
| `HELIX_PROGRESS=1` | Draw a progress bar along the bottom of the video |

### Checking a render by hand

```bash
k1os-helix-enc -v -o out.h264 /usr/data/k1os/timelapse/frames/*.jpg
```

`-D -o out.nv12` writes the decoded frames instead, for inspection with `ffmpeg -f rawvideo -pix_fmt nv12 -s 1280x720 -i out.nv12 frame.png` on a computer.
