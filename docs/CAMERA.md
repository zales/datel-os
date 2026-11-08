# Camera and timelapse

## Camera

The K1 camera is a USB UVC device (Sonix 0c45:6366) that produces MJPEG and H.264 in hardware. Datel OS serves the MJPEG with [uStreamer](https://github.com/pikvm/ustreamer) 6.67 without re-encoding; nginx exposes it at `http://<ip>/webcam/?action=stream` and `?action=snapshot`. The camera node is found automatically (the USB node with index 0), and the camera is registered in Moonraker once on the first boot, so Mainsail shows it without setup.

Defaults: 1280×720 at 8 fps, about 6 Mbit/s. 15 fps is about 12 Mbit/s and stutters on a weak 2.4 GHz link. Change it in `/usr/data/k1os/camera.env`:

```
CAMERA_RESOLUTION=1280x720
CAMERA_FPS=8
```

and restart with `systemctl restart ustreamer`. Keep the frame rate in Mainsail's camera settings in step.

### OrcaSlicer

OrcaSlicer's device tab is an embedded WebKit browser that cannot show an MJPEG stream in an image; Mainsail reports "Error while connecting to …/webcam/?action=stream". Moonraker therefore has a second camera **K1 (snapshots)** in adaptive snapshot mode (5 fps). Pick it from the camera dropdown of the webcam panel in OrcaSlicer; Mainsail remembers the choice per browser, so a normal browser keeps the full stream.

## Timelapse

Timelapse uses [moonraker-timelapse](https://github.com/mainsail-crew/moonraker-timelapse) for the frames and the Mainsail panel, and renders the video on the X2000's Helix hardware encoder instead of a software x264. Rendering a print takes seconds and little CPU.

| Part | What it does |
|---|---|
| Moonraker component `[timelapse]` | Takes a snapshot per layer or per interval, offers the Timelapse panel in Mainsail. Frames go to `/usr/data/k1os/timelapse/frames/`, videos to `/usr/data/k1os/timelapse/` |
| `k1os-helix-enc` | Decodes the JPEG frames (libjpeg-turbo, or the Helix with `-H`) and encodes them through `/dev/video1` into an H.264 stream |
| `timelapse-render` | Stands in for ffmpeg in the component's configuration: runs the codec and lets ffmpeg wrap the stream into MP4 with `-c copy`. If the codec fails, the MJPEG frames go into the MP4 unchanged |

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
