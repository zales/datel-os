# k1os_stream: Mainsail controls and an automatic stream title for the Twitch
# live stream of Datel OS (k1os-twitch.service).
#
# Remote methods (Klipper: action_call_remote_method), HTTP endpoint
# /server/k1os/stream (GET status, POST settings) and a Klipper prompt dialog.
# Settings live in /usr/data/k1os/twitch.env next to the stream key; the key
# itself is never read into a response, a log line or a G-code string. Twitch
# tokens (Device Code Grant, scope channel:manage:broadcast) live in
# /usr/data/k1os/twitch-auth.json, mode 0600.
#
# MIT License, part of Datel OS.
from __future__ import annotations
import asyncio
import json
import logging
import os
import re
import shlex
import time
import urllib.parse
from typing import TYPE_CHECKING, Any, Dict, Optional
try:
    import jinja2
except ImportError:  # Moonraker ships jinja2; plain placeholders still work without it
    jinja2 = None

if TYPE_CHECKING:
    from ..confighelper import ConfigHelper
    from ..common import WebRequest
    from .klippy_apis import KlippyAPI
    from .http_client import HttpClient
    from .machine import Machine

TWITCH_ID = "https://id.twitch.tv/oauth2"
TWITCH_API = "https://api.twitch.tv/helix"
SCOPE = "channel:manage:broadcast"
TITLE_MAX = 140
INGESTS = {
    "auto": "rtmp://live.twitch.tv/app",
    "eu": "rtmp://live-prg.twitch.tv/app",
    "us": "rtmp://live-iad.twitch.tv/app",
}
RESOLUTIONS = ("1280x720", "640x480")
DEFAULT_TEMPLATE = (
    "🖨️ {{ file }} | 🚀 {{ progress }}% done | ⏰ {{ elapsed }} elapsed | "
    "🔥 Hotend {{ hotend }} 🛏️ Bed {{ bed }} | {{ state_emoji }} {{ state }}"
)
STATE_EMOJI = {
    "standby": "💤", "printing": "✅", "paused": "⏸️", "complete": "🏁",
    "cancelled": "❌", "error": "⚠️",
}
# Settings the UI may change; everything else in twitch.env is left alone.
SETTING_KEYS = {
    "resolution": "TWITCH_RESOLUTION", "bitrate_kbps": "TWITCH_BITRATE",
    "overlay": "TWITCH_OVERLAY", "ingest": "TWITCH_INGEST",
    "channel": "TWITCH_CHANNEL", "client_id": "TWITCH_CLIENT_ID",
    "title_template": "TWITCH_TITLE_TEMPLATE", "idle_title": "TWITCH_IDLE_TITLE",
    "category": "TWITCH_CATEGORY",
    "m117": "TWITCH_M117", "autostart": "TWITCH_AUTOSTART",
}
PIPELINE_KEYS = ("resolution", "bitrate_kbps", "overlay", "ingest")
# Settings of the picture itself, which k1os-camera's encoder reads at start.
ENCODER_KEYS = ("resolution", "bitrate_kbps", "overlay")
# TWITCH_OVERLAY: 0 plain camera, 1 status bar, 2 status bar and graph panel
OVERLAY_NAMES = {0: "off", 1: "text", 2: "text+graph"}


def _truthy(v: Any) -> bool:
    return str(v).strip().lower() in ("1", "true", "yes", "on")


def _overlay_level(v: Any) -> Optional[int]:
    """0, 1 or 2 from a TWITCH_OVERLAY value; None when it is not one."""
    s = str(v).strip().lower()
    if s in ("0", "off", "false", "no", "none"):
        return 0
    if s in ("1", "on", "true", "yes", "text", "bar"):
        return 1
    if s in ("2", "graph", "graphs", "text+graph", "full"):
        return 2
    return None


def _read_env(path: str) -> Dict[str, str]:
    env: Dict[str, str] = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return env
    for line in lines:
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        key, _, val = s.partition("=")
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            continue
        try:
            parts = shlex.split(val, posix=True)
        except ValueError:
            parts = [val.strip()]
        env[key] = " ".join(parts)
    return env


def _sh_quote(val: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_./:=@%+,-]*", val):
        return val
    return "'" + val.replace("'", "'\\''") + "'"


def _write_env(path: str, updates: Dict[str, Optional[str]]) -> None:
    """Set or remove keys in a shell env file, keeping every other line."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []
    pending = dict(updates)
    out = []
    for line in lines:
        m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)=", line)
        if m and m.group(1) in pending:
            val = pending.pop(m.group(1))
            if val is not None:
                out.append(f"{m.group(1)}={_sh_quote(val)}")
            continue
        out.append(line)
    for key, val in pending.items():
        if val is not None:
            out.append(f"{key}={_sh_quote(val)}")
    _write_private(path, "\n".join(out) + "\n")


def _write_private(path: str, text: str) -> None:
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _fmt_elapsed(secs: float) -> str:
    secs = max(0, int(secs))
    h, m = secs // 3600, (secs % 3600) // 60
    return f"{h}h{m:02d}m" if h else f"{m}m"


def _fmt_heater(cur: float, target: float) -> str:
    hint = ""
    if target > cur + 1:
        hint = " (heating)"
    elif target == 0 and cur > 40:
        hint = " (cooling)"
    return f"{cur:.1f}/{target:.0f}°C{hint}"


def _gcode_str(text: str) -> str:
    """A string safe inside RESPOND MSG="..." and M117."""
    return re.sub(r"[\r\n\"]", " ", text).strip()


class K1osStream:
    def __init__(self, config: ConfigHelper) -> None:
        self.server = config.get_server()
        self.eventloop = self.server.get_event_loop()
        self.env_file: str = config.get("env_file", "/usr/data/k1os/twitch.env")
        self.auth_file: str = config.get("auth_file", "/usr/data/k1os/twitch-auth.json")
        self.status_file: str = config.get("status_file", "/run/k1os/twitch-status.json")
        self.service: str = config.get("service", "k1os-twitch")
        # k1os-camera runs the one encoder for Twitch and Mainsail's WebRTC camera;
        # it reports its rate here, and takes new picture settings on a restart.
        self.encoder_service: str = config.get("encoder_service", "k1os-camera")
        self.encoder_status_file: str = config.get(
            "encoder_status_file", "/run/k1os/stream-status.json")
        self.title_interval: float = config.getfloat("title_interval", 60.0)
        self.klippy_apis: KlippyAPI = self.server.lookup_component("klippy_apis")
        self.http: HttpClient = self.server.lookup_component("http_client")

        self.printer: Dict[str, Dict[str, Any]] = {
            "print_stats": {}, "display_status": {}, "extruder": {}, "heater_bed": {},
        }
        self.klippy_ready = False
        self.active: Optional[bool] = None       # None until the first service poll
        self.active_since: float = 0.0
        self.last_title: str = ""
        self.last_title_at: float = 0.0
        self.force_title = False
        self.category_set = False
        self.last_state: Optional[str] = None
        self.last_m117: str = ""
        self.login_task: Optional[asyncio.Task] = None
        self.auth: Dict[str, Any] = self._load_auth()
        self.auth_warned = False
        self.webcam_cleaned = False
        self.dialog_shown_at = 0.0
        self.lock = asyncio.Lock()

        for name, cb in (
            ("k1os_stream_start", self.remote_start),
            ("k1os_stream_stop", self.remote_stop),
            ("k1os_stream_set", self.remote_set),
            ("k1os_stream_login", self.remote_login),
            ("k1os_stream_status", self.remote_status),
            ("k1os_stream_dialog", self.remote_dialog),
        ):
            self.server.register_remote_method(name, cb)
        self.server.register_endpoint(
            "/server/k1os/stream", ["GET", "POST"], self._handle_http)
        self.server.register_endpoint(
            "/server/k1os/stream/start", ["POST"], self._handle_http_start)
        self.server.register_endpoint(
            "/server/k1os/stream/stop", ["POST"], self._handle_http_stop)
        self.server.register_endpoint(
            "/server/k1os/stream/login", ["POST"], self._handle_http_login)
        self.server.register_event_handler("server:klippy_ready", self._on_klippy_ready)
        self.server.register_event_handler(
            "server:klippy_disconnect", self._on_klippy_disconnect)
        self.server.register_event_handler(
            "machine:service_state_changed", self._on_service_state)

    async def component_init(self) -> None:
        self.eventloop.create_task(self._tick_loop())

    # ----- settings -------------------------------------------------------

    def settings(self) -> Dict[str, Any]:
        env = _read_env(self.env_file)
        ingest_url = env.get("TWITCH_INGEST") or INGESTS["auto"]
        alias = next((k for k, v in INGESTS.items() if v == ingest_url), "custom")
        try:
            bitrate = int(env.get("TWITCH_BITRATE") or 2500)
        except ValueError:
            bitrate = 2500
        overlay = _overlay_level(env.get("TWITCH_OVERLAY", "1"))
        if overlay is None:
            overlay = 1
        return {
            "key_set": bool(env.get("TWITCH_KEY")),
            "resolution": env.get("TWITCH_RESOLUTION") or "1280x720",
            "bitrate_kbps": bitrate,
            "overlay": overlay,
            "ingest": alias,
            "ingest_url": ingest_url,
            "channel": env.get("TWITCH_CHANNEL") or self.auth.get("login", ""),
            "client_id": env.get("TWITCH_CLIENT_ID", ""),
            "title_template": env.get("TWITCH_TITLE_TEMPLATE") or DEFAULT_TEMPLATE,
            "idle_title": env.get("TWITCH_IDLE_TITLE", ""),
            "category": env.get("TWITCH_CATEGORY", "Makers & Crafting"),
            "m117": _truthy(env.get("TWITCH_M117", "1")),
            "autostart": _truthy(env.get("TWITCH_AUTOSTART", "0")),
        }

    def _validate(self, args: Dict[str, Any]) -> Dict[str, str]:
        """UI arguments -> env file values. Raises ValueError on bad input."""
        out: Dict[str, str] = {}
        for key, val in args.items():
            if val is None or key not in SETTING_KEYS:
                continue
            if key == "resolution":
                val = str(val).lower().replace("p", "")
                val = {"720": "1280x720", "480": "640x480"}.get(val, val)
                if val not in RESOLUTIONS:
                    raise ValueError(f"resolution must be one of {', '.join(RESOLUTIONS)}")
            elif key == "bitrate_kbps":
                val = int(float(val))
                if not 300 <= val <= 8000:
                    raise ValueError("bitrate_kbps must be between 300 and 8000")
                val = str(val)
            elif key == "overlay":
                level = _overlay_level(val)
                if level is None:
                    raise ValueError("overlay must be 0 (off), 1 (text) or 2 (text and graph)")
                val = str(level)
            elif key in ("m117", "autostart"):
                val = "1" if _truthy(val) else "0"
            elif key == "ingest":
                v = str(val).strip()
                if v.lower() in INGESTS:
                    val = INGESTS[v.lower()]
                elif re.fullmatch(r"rtmps?://[A-Za-z0-9.-]+(:\d+)?/[A-Za-z0-9_-]+", v):
                    val = v
                else:
                    raise ValueError("ingest must be auto, eu, us or an rtmp://host/app URL")
            elif key == "channel":
                val = str(val).strip().lower()
                if not re.fullmatch(r"[a-z0-9_]{0,25}", val):
                    raise ValueError("channel must be a Twitch login name")
            elif key == "client_id":
                val = str(val).strip()
                if not re.fullmatch(r"[A-Za-z0-9]{0,64}", val):
                    raise ValueError("client_id looks wrong")
            elif key == "category":
                val = str(val).strip()[:100]
            else:
                val = str(val)[:400]
            out[SETTING_KEYS[key]] = val
        return out

    async def apply_settings(self, args: Dict[str, Any]) -> Dict[str, Any]:
        updates = self._validate(args)
        if not updates:
            return self.settings()
        before = self.settings()
        _write_env(self.env_file, updates)
        after = self.settings()
        changed = [k for k in SETTING_KEYS if before.get(k) != after.get(k)]
        if changed:
            def show(k: str, v: Any) -> str:
                if k == "overlay":
                    return OVERLAY_NAMES.get(v, str(v))
                return ("on" if v else "off") if isinstance(v, bool) else str(v)
            desc = ", ".join(f"{k} {show(k, after[k])}" for k in changed)
            logging.info(f"k1os_stream: settings changed: {desc}")
            await self.console(f"Twitch: set {desc}")
        encoder = self._service_state(self.encoder_service) == "active" \
            and any(k in ENCODER_KEYS for k in changed)
        if self.active and (encoder or any(k in PIPELINE_KEYS for k in changed)):
            await self.console("Twitch: restarting the stream with the new settings")
            await self._service("stop")
            if encoder:
                await self._service("restart", self.encoder_service)
            await asyncio.sleep(1.5)
            await self._service("start")
        elif encoder:
            # The camera view in Mainsail shares the encoder: it reconnects.
            await self._service("restart", self.encoder_service)
        if any(k in ("title_template", "idle_title", "channel") for k in changed):
            self.force_title = True
        return after

    # ----- service control -----------------------------------------------

    def _machine(self) -> Machine:
        return self.server.lookup_component("machine")

    def service_state(self) -> str:
        return self._service_state(self.service)

    def _service_state(self, service: str) -> str:
        provider = getattr(self._machine(), "sys_provider", None)
        if provider is None:
            return "unknown"
        info = provider.get_available_services().get(service)
        return info["active_state"] if info else "unavailable"

    async def _service(self, action: str, service: Optional[str] = None) -> None:
        service = service or self.service
        machine = self._machine()
        provider = machine.sys_provider
        if not provider.is_service_available(service):
            raise self.server.error(
                f"service {service} is not known to Moonraker (moonraker.asvc)")
        await machine.do_service_action(action, service)

    async def start(self) -> None:
        s = self.settings()
        if not s["key_set"]:
            await self.console(
                "Twitch: no stream key. Put TWITCH_KEY=live_... into "
                f"{self.env_file} (mode 600) over SSH")
            raise self.server.error("TWITCH_KEY is not set", 400)
        if self.service_state() == "active":
            await self.console("Twitch: the stream is already running")
            return
        await self.console(
            f"Twitch: starting ({s['resolution']}, {s['bitrate_kbps']} kbit/s, "
            f"overlay {OVERLAY_NAMES[s['overlay']]}, ingest {s['ingest']})")
        await self._service("start")

    async def stop(self) -> None:
        if self.service_state() not in ("active", "activating", "reloading"):
            await self.console("Twitch: the stream is not running")
            return
        await self.console("Twitch: stopping")
        await self._service("stop")

    # ----- Klipper side ---------------------------------------------------

    async def console(self, msg: str) -> None:
        if not self.klippy_ready:
            logging.info(f"k1os_stream: {msg}")
            return
        try:
            await self.klippy_apis.run_gcode(
                f'RESPOND TYPE=echo MSG="{_gcode_str(msg)}"', None)
        except Exception:
            logging.exception("k1os_stream: console message failed")

    async def m117(self, msg: str) -> None:
        """Set the display line, but never over a message that is not ours."""
        if not self.klippy_ready or not self.settings()["m117"]:
            return
        current = (self.printer["display_status"].get("message") or "").strip()
        if current and not current.startswith("Twitch:") and current != self.last_m117:
            return
        if msg == current:
            return
        try:
            await self.klippy_apis.run_gcode(f"M117 {_gcode_str(msg)}", None)
            self.last_m117 = msg
        except Exception:
            logging.exception("k1os_stream: M117 failed")

    async def _on_klippy_ready(self) -> None:
        self.klippy_ready = True
        try:
            objs = {
                "print_stats": None, "display_status": None,
                "extruder": ["temperature", "target"],
                "heater_bed": ["temperature", "target"],
            }
            status = await self.klippy_apis.subscribe_objects(objs, self._on_status, {})
            self._on_status(status, 0.0)
        except Exception:
            logging.exception("k1os_stream: subscription failed")

    def _on_klippy_disconnect(self) -> None:
        self.klippy_ready = False

    def _on_status(self, status: Dict[str, Any], eventtime: float) -> None:
        for obj, fields in status.items():
            if obj in self.printer and isinstance(fields, dict):
                self.printer[obj].update(fields)
        ps = self.printer["print_stats"]
        state = ps.get("state")
        key = f"{state}:{ps.get('filename', '')}"
        if self.last_state is not None and key != self.last_state:
            self.force_title = True
        self.last_state = key

    def _on_service_state(self, info: Dict[str, Any]) -> None:
        if self.service in info:
            self.eventloop.create_task(self._poll_service())

    # ----- remote methods -------------------------------------------------

    async def _close_dialog(self) -> None:
        if self.dialog_shown_at and self.klippy_ready:
            self.dialog_shown_at = 0.0
            await self.klippy_apis.run_gcode(
                'RESPOND TYPE=command MSG="action:prompt_end"', None)

    async def remote_start(self, **kwargs) -> None:
        try:
            await self._close_dialog()
            await self.start()
        except Exception as e:
            await self.console(f"Twitch: start failed: {e}")

    async def remote_stop(self, **kwargs) -> None:
        try:
            await self._close_dialog()
            await self.stop()
        except Exception as e:
            await self.console(f"Twitch: stop failed: {e}")

    async def remote_set(self, **kwargs) -> None:
        if "bitrate" in kwargs and "bitrate_kbps" not in kwargs:
            kwargs["bitrate_kbps"] = kwargs.pop("bitrate")
        try:
            await self.apply_settings(kwargs)
        except Exception as e:
            await self.console(f"Twitch: setting rejected: {e}")
        # a button of the dialog: redraw it with the new selection
        if time.time() - self.dialog_shown_at < 600:
            await self.show_dialog()

    async def remote_login(self, **kwargs) -> None:
        try:
            await self.begin_login()
        except Exception as e:
            await self.console(f"Twitch: login failed: {e}")

    async def remote_status(self, **kwargs) -> None:
        for line in self.status_lines():
            await self.console(line)

    async def remote_dialog(self, **kwargs) -> None:
        await self.show_dialog()

    # ----- HTTP -----------------------------------------------------------

    async def _handle_http(self, web_request: WebRequest) -> Dict[str, Any]:
        if web_request.get_action() == "POST":
            args = dict(web_request.get_args())
            if "bitrate" in args and "bitrate_kbps" not in args:
                args["bitrate_kbps"] = args.pop("bitrate")
            try:
                await self.apply_settings(args)
            except ValueError as e:
                raise self.server.error(str(e), 400)
        return self.status()

    async def _handle_http_start(self, web_request: WebRequest) -> Dict[str, Any]:
        await self.start()
        return self.status()

    async def _handle_http_stop(self, web_request: WebRequest) -> Dict[str, Any]:
        await self.stop()
        return self.status()

    async def _handle_http_login(self, web_request: WebRequest) -> Dict[str, Any]:
        info = await self.begin_login()
        return {"user_code": info["user_code"], "verification_uri": info["verification_uri"],
                "expires_in": info["expires_in"]}

    # ----- status ---------------------------------------------------------

    @staticmethod
    def _read_json(path: str) -> Dict[str, Any]:
        try:
            with open(path) as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def read_stats(self) -> Dict[str, Any]:
        stats = self._read_json(self.status_file)
        if stats and "kbit" not in stats:
            # Twitch is sent by k1os-camera's encoder: the rate comes from the
            # encoder, the start time stays Twitch's own.
            enc = self._read_json(self.encoder_status_file)
            enc.pop("started", None)
            stats = {**enc, **stats}
        if "started" in stats:
            try:
                stats["uptime_s"] = int(time.time() - float(stats["started"]))
            except (TypeError, ValueError):
                pass
        return stats

    def channel_url(self) -> str:
        s = self.settings()
        if not s["channel"]:
            return ""
        return "https://www.twitch.tv/" + urllib.parse.quote(s["channel"])

    def status(self) -> Dict[str, Any]:
        s = self.settings()
        state = self.service_state()
        stats = self.read_stats()
        exp = self.auth.get("expires_at")
        return {
            "active": state == "active",
            "service_state": state,
            "settings": s,
            "stats": stats,
            "status_line": self.status_line(),
            "title": self.compose_title(s)[0],
            "title_sent": self.last_title,
            "auth": {
                "logged_in": bool(self.auth.get("refresh_token")),
                "login": self.auth.get("login", ""),
                "broadcaster_id": self.auth.get("broadcaster_id", ""),
                "expires_in": int(exp - time.time()) if exp else None,
                "category": self.auth.get("game_name", ""),
                "login_pending": bool(self.login_task and not self.login_task.done()),
            },
            "channel_url": self.channel_url(),
        }

    def status_line(self) -> str:
        state = self.service_state()
        if state != "active":
            return "Twitch: off" if state in ("inactive", "unavailable", "unknown") \
                else f"Twitch: {state}"
        stats = self.read_stats()
        parts = ["Twitch: live"]
        if float(stats.get("kbit") or 0) > 0:
            parts.append(f"{float(stats['kbit']) / 1000:.1f} Mbit/s")
        up = stats.get("uptime_s")
        if up is None and self.active_since:
            up = int(time.time() - self.active_since)
        if up is not None:
            parts.append(time.strftime("%H:%M:%S", time.gmtime(int(up))))
        return " ".join(parts)

    def status_lines(self) -> list:
        s = self.settings()
        st = self.status()
        lines = [
            self.status_line(),
            f"Twitch: {s['resolution']}, {s['bitrate_kbps']} kbit/s, overlay "
            f"{OVERLAY_NAMES[s['overlay']]}, ingest {s['ingest']}, key "
            f"{'set' if s['key_set'] else 'MISSING'}",
        ]
        a = st["auth"]
        if a["logged_in"]:
            lines.append(f"Twitch: logged in as {a['login']}, title: {st['title']}")
        elif s["client_id"]:
            lines.append("Twitch: not logged in; run TWITCH_LOGIN for the automatic title")
        else:
            lines.append(
                f"Twitch: no TWITCH_CLIENT_ID in {self.env_file}; the title stays manual")
        return lines

    async def show_dialog(self) -> None:
        s = self.settings()
        st = self.status()
        ch = s["channel"] or "?"
        live = st["active"]
        text = _gcode_str(
            f"{self.status_line()} — twitch.tv/{ch}. "
            f"{s['resolution']}, {s['bitrate_kbps']} kbit/s, overlay "
            f"{OVERLAY_NAMES[s['overlay']]}, ingest {s['ingest']}. "
            + (f"Title: {st['title']}" if st["auth"]["logged_in"]
               else "Not logged in: Login sets the title automatically.")
        )
        lines = [
            "action:prompt_end",
            "action:prompt_begin Twitch stream",
            f"action:prompt_text {text}",
            "action:prompt_button_group_start",
            "action:prompt_button Start|TWITCH_START|" + ("secondary" if live else "primary"),
            "action:prompt_button Stop|TWITCH_STOP|" + ("error" if live else "secondary"),
            "action:prompt_button_group_end",
            "action:prompt_button_group_start",
            "action:prompt_button 720p / 2.5 Mbit|TWITCH_SET RESOLUTION=1280x720 BITRATE=2500|"
            + ("primary" if s["resolution"] == "1280x720" else "secondary"),
            "action:prompt_button 480p / 1 Mbit|TWITCH_SET RESOLUTION=640x480 BITRATE=1000|"
            + ("primary" if s["resolution"] == "640x480" else "secondary"),
            "action:prompt_button_group_end",
            "action:prompt_button_group_start",
            "action:prompt_button Overlay off|TWITCH_SET OVERLAY=0|"
            + ("primary" if s["overlay"] == 0 else "secondary"),
            "action:prompt_button Text|TWITCH_SET OVERLAY=1|"
            + ("primary" if s["overlay"] == 1 else "secondary"),
            "action:prompt_button Text + graph|TWITCH_SET OVERLAY=2|"
            + ("primary" if s["overlay"] == 2 else "secondary"),
            "action:prompt_button_group_end",
            "action:prompt_button_group_start",
            "action:prompt_button Ingest EU|TWITCH_SET INGEST=eu|"
            + ("primary" if s["ingest"] == "eu" else "secondary"),
            "action:prompt_button Ingest US|TWITCH_SET INGEST=us|"
            + ("primary" if s["ingest"] == "us" else "secondary"),
            "action:prompt_button Ingest auto|TWITCH_SET INGEST=auto|"
            + ("primary" if s["ingest"] == "auto" else "secondary"),
            "action:prompt_button_group_end",
            "action:prompt_footer_button Status|TWITCH_STATUS|info",
            "action:prompt_footer_button Login|TWITCH_LOGIN|info",
            "action:prompt_footer_button Close|RESPOND TYPE=command MSG=action:prompt_end|warning",
            "action:prompt_show",
        ]
        script = "\n".join(f'RESPOND TYPE=command MSG="{line}"' for line in lines)
        try:
            await self.klippy_apis.run_gcode(script, None)
            self.dialog_shown_at = time.time()
        except Exception:
            logging.exception("k1os_stream: dialog failed")

    # ----- periodic work --------------------------------------------------

    async def _tick_loop(self) -> None:
        await asyncio.sleep(3)
        while True:
            try:
                await self._tick()
            except Exception:
                logging.exception("k1os_stream: tick failed")
            await asyncio.sleep(1)

    async def _tick(self) -> None:
        await self._poll_service()
        if not self.webcam_cleaned:
            self.webcam_cleaned = True
            await self._remove_webcam()
        now = time.time()
        if self.active:
            due = self.force_title or now - self.last_title_at >= self.title_interval
            if due:
                self.last_title_at = now   # the next check in a minute, PATCH or not
                await self.update_title()
                await self.m117(self.status_line())
            elif 15 <= now - self.active_since < 16:
                await self.m117(self.status_line())
        elif self.force_title:
            self.force_title = False
            await self.update_title()

    async def _poll_service(self) -> None:
        state = self.service_state()
        active = state == "active"
        if self.active is None:
            self.active = active
            if active:
                self.active_since = time.time() - self.read_stats().get("uptime_s", 0)
            return
        if active == self.active:
            return
        self.active = active
        if active:
            self.active_since = time.time()
            self.category_set = False
            self.force_title = True
            await self.console("Twitch: live")
            await self.m117("Twitch: live")
        else:
            if state == "failed":
                await self.console(
                    f"Twitch: the stream failed, see journalctl -u {self.service}")
            else:
                await self.console("Twitch: off")
            await self.m117("Twitch: off")
            idle = self.settings()["idle_title"]
            if idle:
                self.force_title = True

    # ----- title ----------------------------------------------------------

    def compose_title(self, s: Optional[Dict[str, Any]] = None) -> tuple:
        """Returns (title, state). The file name is shortened first when the
        title would exceed Twitch's 140 characters."""
        s = s or self.settings()
        ps, ds = self.printer["print_stats"], self.printer["display_status"]
        ex, hb = self.printer["extruder"], self.printer["heater_bed"]
        state = str(ps.get("state") or "standby")
        if self.active is False and s["idle_title"]:
            return s["idle_title"][:TITLE_MAX], state
        fname = str(ps.get("filename") or "")
        fname = os.path.basename(fname)
        fname = re.sub(r"\.g(code|co|)$", "", fname, flags=re.I) or "idle"
        progress = float(ds.get("progress") or 0.0)
        if state in ("complete",):
            progress = 1.0
        info = ps.get("info") or {}
        fields = {
            "progress": int(round(progress * 100)),
            "elapsed": _fmt_elapsed(float(ps.get("print_duration") or 0.0)),
            "total_elapsed": _fmt_elapsed(float(ps.get("total_duration") or 0.0)),
            "hotend": _fmt_heater(float(ex.get("temperature") or 0), float(ex.get("target") or 0)),
            "bed": _fmt_heater(float(hb.get("temperature") or 0), float(hb.get("target") or 0)),
            "hotend_temp": round(float(ex.get("temperature") or 0), 1),
            "hotend_target": round(float(ex.get("target") or 0)),
            "bed_temp": round(float(hb.get("temperature") or 0), 1),
            "bed_target": round(float(hb.get("target") or 0)),
            "state": state,
            "state_emoji": STATE_EMOJI.get(state, "ℹ️"),
            "layer": info.get("current_layer") or 0,
            "total_layers": info.get("total_layer") or 0,
            "channel": s["channel"],
            "message": str(ds.get("message") or ""),
        }
        tpl = s["title_template"]
        title = ""
        for cut in range(0, len(fname) + 1):
            name = fname if cut == 0 else fname[: max(3, len(fname) - cut)] + "…"
            title = self._render(tpl, dict(fields, file=name))
            if len(title) <= TITLE_MAX or len(name) <= 4:
                break
        return title[:TITLE_MAX], state

    def _render(self, tpl: str, fields: Dict[str, Any]) -> str:
        def plain(t: str) -> str:
            return re.sub(r"\{\{\s*(\w+)\s*\}\}",
                          lambda m: str(fields.get(m.group(1), "")), t)
        if jinja2 is None:
            return " ".join(plain(tpl).split())
        try:
            text = jinja2.Template(tpl, autoescape=False).render(**fields)
        except Exception as e:
            logging.info(f"k1os_stream: title template error: {e}")
            text = plain(DEFAULT_TEMPLATE)
        return " ".join(text.split())

    async def update_title(self) -> None:
        self.force_title = False
        s = self.settings()
        if not self.auth.get("refresh_token") or not s["client_id"]:
            return
        if not self.active and not s["idle_title"]:
            return   # no stream: the title stays as it is
        title, _ = self.compose_title(s)
        if not title or title == self.last_title:
            return
        body: Dict[str, Any] = {"title": title}
        if self.active and s["category"] and not self.category_set:
            gid = await self._category_id(s["category"])
            if gid:
                body["game_id"] = gid
        bid = self.auth.get("broadcaster_id")
        if not bid:
            if not await self._fetch_user():
                return
            bid = self.auth["broadcaster_id"]
        code, _ = await self._api("PATCH", f"/channels?broadcaster_id={bid}", body)
        self.last_title_at = time.time()
        if code == 204:
            self.last_title = title
            if "game_id" in body:
                self.category_set = True

    async def _category_id(self, name: str) -> Optional[str]:
        if self.auth.get("game_name") == name and self.auth.get("game_id"):
            return self.auth["game_id"]
        code, data = await self._api(
            "GET", "/search/categories?query=" + urllib.parse.quote(name))
        if code != 200 or not isinstance(data, dict):
            return None
        items = data.get("data") or []
        match = next((c for c in items if c.get("name", "").lower() == name.lower()), None)
        if match is None and items:
            match = items[0]
        if not match:
            return None
        self.auth["game_id"], self.auth["game_name"] = match["id"], name
        self._save_auth()
        return match["id"]

    # ----- Twitch auth ----------------------------------------------------

    def _load_auth(self) -> Dict[str, Any]:
        try:
            with open(self.auth_file) as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _save_auth(self) -> None:
        _write_private(self.auth_file, json.dumps(self.auth, indent=1) + "\n")

    async def begin_login(self) -> Dict[str, Any]:
        s = self.settings()
        if not s["client_id"]:
            await self.console(
                f"Twitch: put TWITCH_CLIENT_ID=<id of your Twitch application> into "
                f"{self.env_file} first (dev.twitch.tv/console, a public client with "
                "Device Code Grant)")
            raise self.server.error("TWITCH_CLIENT_ID is not set", 400)
        if self.login_task and not self.login_task.done():
            raise self.server.error("a login is already waiting for the code", 400)
        form = urllib.parse.urlencode({"client_id": s["client_id"], "scopes": SCOPE})
        resp = await self.http.request(
            "POST", f"{TWITCH_ID}/device", body=form,
            headers={"Content-Type": "application/x-www-form-urlencoded"})
        logging.info(f"k1os_stream: POST oauth2/device -> {resp.status_code}")
        if resp.status_code != 200:
            raise self.server.error(
                f"Twitch rejected the device code request (HTTP {resp.status_code}); "
                "check TWITCH_CLIENT_ID", 502)
        info = resp.json()
        uri = info.get("verification_uri", "https://www.twitch.tv/activate")
        code = info["user_code"]
        minutes = int(info.get("expires_in", 1800)) // 60
        await self.console(f"Twitch: open {uri} and enter the code {code} (valid {minutes} min)")
        text = _gcode_str(f"Open {uri} on any device, log in as the channel owner and "
                          f"enter the code {code}. Valid for {minutes} minutes.")
        script = "\n".join(f'RESPOND TYPE=command MSG="{line}"' for line in (
            "action:prompt_end",
            "action:prompt_begin Twitch login",
            f"action:prompt_text {text}",
            f"action:prompt_text Code: {code}",
            "action:prompt_footer_button Close|RESPOND TYPE=command MSG=action:prompt_end|primary",
            "action:prompt_show",
        ))
        if self.klippy_ready:
            await self.klippy_apis.run_gcode(script, None)
        self.login_task = self.eventloop.create_task(
            self._poll_login(s["client_id"], info))
        return info

    async def _poll_login(self, client_id: str, info: Dict[str, Any]) -> None:
        interval = float(info.get("interval", 5))
        deadline = time.time() + float(info.get("expires_in", 1800))
        form = urllib.parse.urlencode({
            "client_id": client_id, "scopes": SCOPE, "device_code": info["device_code"],
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"})
        while time.time() < deadline:
            await asyncio.sleep(interval)
            resp = await self.http.request(
                "POST", f"{TWITCH_ID}/token", body=form,
                headers={"Content-Type": "application/x-www-form-urlencoded"})
            if resp.status_code == 200:
                data = resp.json()
                self.auth = {
                    "client_id": client_id,
                    "access_token": data["access_token"],
                    "refresh_token": data.get("refresh_token", ""),
                    "expires_at": time.time() + float(data.get("expires_in", 3600)),
                    "scope": data.get("scope", [SCOPE]),
                }
                self._save_auth()
                logging.info("k1os_stream: Twitch login complete")
                if await self._fetch_user():
                    await self.console(
                        f"Twitch: logged in as {self.auth.get('login')}; the title "
                        "follows the print from now on")
                self.auth_warned = False
                self.last_title = ""
                self.force_title = True
                self.category_set = False
                if self.klippy_ready:
                    await self.klippy_apis.run_gcode(
                        'RESPOND TYPE=command MSG="action:prompt_end"', None)
                return
            try:
                msg = resp.json().get("message", "")
            except Exception:
                msg = ""
            if resp.status_code == 400 and msg == "authorization_pending":
                continue
            if resp.status_code == 400 and msg == "slow_down":
                interval += 5
                continue
            logging.info(f"k1os_stream: POST oauth2/token -> {resp.status_code} {msg}")
            await self.console(f"Twitch: login did not complete ({msg or resp.status_code})")
            return
        await self.console("Twitch: the login code expired, run TWITCH_LOGIN again")

    async def _fetch_user(self) -> bool:
        code, data = await self._api("GET", "/users")
        if code == 200 and isinstance(data, dict) and data.get("data"):
            u = data["data"][0]
            self.auth["broadcaster_id"] = u["id"]
            self.auth["login"] = u["login"]
            self._save_auth()
            return True
        return False

    async def _ensure_token(self) -> bool:
        async with self.lock:
            if not self.auth.get("refresh_token"):
                return False
            if self.auth.get("access_token") and \
                    time.time() < float(self.auth.get("expires_at", 0)) - 600:
                return True
            return await self._refresh()

    async def _refresh(self) -> bool:
        client_id = self.auth.get("client_id") or self.settings()["client_id"]
        form = urllib.parse.urlencode({
            "client_id": client_id, "grant_type": "refresh_token",
            "refresh_token": self.auth.get("refresh_token", "")})
        resp = await self.http.request(
            "POST", f"{TWITCH_ID}/token", body=form,
            headers={"Content-Type": "application/x-www-form-urlencoded"})
        logging.info(f"k1os_stream: POST oauth2/token (refresh) -> {resp.status_code}")
        if resp.status_code == 200:
            data = resp.json()
            self.auth["access_token"] = data["access_token"]
            self.auth["refresh_token"] = data.get("refresh_token", self.auth["refresh_token"])
            self.auth["expires_at"] = time.time() + float(data.get("expires_in", 3600))
            self._save_auth()
            return True
        if resp.status_code in (400, 401):
            # the refresh token was revoked or expired: a new login is needed
            self.auth.pop("access_token", None)
            self.auth.pop("refresh_token", None)
            self._save_auth()
            if not self.auth_warned:
                self.auth_warned = True
                await self.console("Twitch: the login expired, run TWITCH_LOGIN again")
        return False

    async def _api(self, method: str, path: str, body: Any = None) -> tuple:
        """Helix request with the user token; logs the HTTP status only."""
        if not await self._ensure_token():
            return 0, None
        for attempt in range(2):
            headers = {
                "Authorization": f"Bearer {self.auth.get('access_token', '')}",
                "Client-Id": self.auth.get("client_id") or self.settings()["client_id"],
            }
            resp = await self.http.request(
                method, TWITCH_API + path, body=body, headers=headers, request_timeout=15.)
            logging.info(f"k1os_stream: {method} /helix{path.split('?')[0]} -> {resp.status_code}")
            if resp.status_code == 401 and attempt == 0:
                async with self.lock:
                    if not await self._refresh():
                        return 401, None
                continue
            data = None
            if resp.content:
                try:
                    data = resp.json()
                except Exception:
                    data = None
            return resp.status_code, data
        return 0, None

    # ----- Mainsail webcam ------------------------------------------------

    async def _remove_webcam(self) -> None:
        """Earlier releases added a Mainsail webcam "Twitch" with the Twitch
        player in an iframe. Twitch embeds its player only into HTTPS pages
        from a listed host name, which Mainsail on the printer is not, so the
        frame stayed black; the webcam is removed on the first tick."""
        try:
            wcmgr = self.server.lookup_component("webcam")
            cams = [c for c in wcmgr.get_webcams().values()
                    if c.extra_data.get("k1os") == "twitch"]
            for cam in cams:
                await wcmgr._delete_cam(cam)
                logging.info("k1os_stream: removed the Twitch player webcam '%s'", cam.name)
            if cams:
                self.server.send_event("webcam:webcams_changed",
                                       {"webcams": wcmgr._list_webcams()})
        except Exception:
            logging.exception("k1os_stream: webcam cleanup failed")


def load_component(config: ConfigHelper) -> K1osStream:
    return K1osStream(config)
