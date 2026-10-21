import asyncio
import collections
import fcntl
import hmac
import json
import logging
import os
import pwd
import secrets
import shutil
import signal
import socket
import stat
import struct
import tempfile
import termios
import time
from dataclasses import dataclass
from typing import Optional

import websockets

log = logging.getLogger("gamepad.stream")
diag_log = logging.getLogger("gamepad.diag")

STREAM_PROTOCOL_VERSION = 1
DEFAULT_STREAM_PORT = 8766
MAX_STREAM_CLIENTS = 2
HANDSHAKE_TIMEOUT = 5.0
SEND_TIMEOUT = 2.0
SLOW_SEND_SECONDS = 0.25
SOFTWARE_MAX_FPS = 30
CLIENT_QUEUE_SIZE = 2
SOCKET_SEND_BUFFER = 16384
WRITE_BUFFER_HIGH = 8192
WRITE_BUFFER_LOW = 2048
RENDER_NODE = "/dev/dri/renderD128"
MIN_HEALTHY_RUN = 10.0
ADAPT_INTERVAL = 1.0
ADAPT_DROP_WINDOW = 6.0
ADAPT_DROPS_TO_DEGRADE = 2
ADAPT_MIN_STEP_INTERVAL = 6.0
ADAPT_CLEAN_TIME_TO_RECOVER = 45.0
IDLE_FLUSH_SECONDS = 0.006
DIAG_INTERVAL_TICKS = 5

QUALITY_LEVELS = (
    {"name": "high", "height": 720, "fps": 60, "kbps": 6000},
    {"name": "medium", "height": 540, "fps": 30, "kbps": 3000},
    {"name": "low", "height": 360, "fps": 24, "kbps": 1200},
)
LEVEL_INDEX = {level["name"]: index for index, level in enumerate(QUALITY_LEVELS)}
AUTO_START_INDEX = 1
ENCODER_CHOICES = ("auto", "vaapi", "nvenc", "x264")
CAPTURE_TOOLS = ("wl-screenrec", "wf-recorder", "ffmpeg")


class StreamUnavailable(Exception):
    pass


def generate_secret() -> str:
    return secrets.token_urlsafe(12)


@dataclass
class Session:
    uid: int
    gid: int
    groups: list
    env: dict
    kind: str
    home: str

    def spawn_args(self) -> dict:
        if os.geteuid() != 0:
            return {}
        return {"user": self.uid, "group": self.gid, "extra_groups": self.groups}


@dataclass
class Screen:
    name: str
    width: int
    height: int


@dataclass
class Frame:
    key: bool
    nals: list
    sps: bytes
    pps: bytes


def target_uid() -> Optional[int]:
    if os.geteuid() != 0:
        return os.geteuid()
    sudo_uid = os.environ.get("SUDO_UID")
    if sudo_uid and sudo_uid.isdigit():
        return int(sudo_uid)
    try:
        candidates = [int(name) for name in os.listdir("/run/user") if name.isdigit() and int(name) != 0]
    except OSError:
        return None
    return candidates[0] if len(candidates) == 1 else None


def is_socket(path: str) -> bool:
    try:
        return stat.S_ISSOCK(os.stat(path).st_mode)
    except OSError:
        return False


def find_wayland_socket(runtime: str, preferred: Optional[str]) -> Optional[str]:
    if preferred and is_socket(os.path.join(runtime, preferred)):
        return preferred
    try:
        names = sorted(os.listdir(runtime))
    except OSError:
        return None
    for name in names:
        if name.startswith("wayland-") and not name.endswith(".lock") and is_socket(os.path.join(runtime, name)):
            return name
    return None


def find_hyprland_signature(runtime: str) -> Optional[str]:
    base = os.path.join(runtime, "hypr")
    try:
        entries = [os.path.join(base, name) for name in os.listdir(base)]
    except OSError:
        return None
    entries = [path for path in entries if os.path.isdir(path)]
    if not entries:
        return None
    return os.path.basename(max(entries, key=os.path.getmtime))


def find_session() -> Session:
    uid = target_uid()
    if uid is None:
        raise StreamUnavailable(
            "session graphique introuvable : lance le serveur avec sudo depuis ta session, ou sans sudo si tu es dans le groupe uinput"
        )
    try:
        entry = pwd.getpwuid(uid)
    except KeyError:
        raise StreamUnavailable(f"utilisateur {uid} introuvable")
    runtime = f"/run/user/{uid}"
    env = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL") if key in os.environ}
    env.update(HOME=entry.pw_dir, USER=entry.pw_name, LOGNAME=entry.pw_name, XDG_RUNTIME_DIR=runtime)
    bus = os.path.join(runtime, "bus")
    if is_socket(bus):
        env["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path={bus}"
    signature = find_hyprland_signature(runtime)
    if signature:
        env["HYPRLAND_INSTANCE_SIGNATURE"] = signature
    preferred = os.environ.get("WAYLAND_DISPLAY") if os.geteuid() == uid else None
    wayland = find_wayland_socket(runtime, preferred)
    if wayland:
        env["WAYLAND_DISPLAY"] = wayland
        kind = "wayland"
    else:
        display = os.environ.get("DISPLAY") or (":0" if os.path.exists("/tmp/.X11-unix/X0") else None)
        if not display:
            raise StreamUnavailable(f"aucune session Wayland ni X11 trouvée pour l'utilisateur {entry.pw_name} ({runtime})")
        env["DISPLAY"] = display
        xauthority = os.environ.get("XAUTHORITY") or os.path.join(entry.pw_dir, ".Xauthority")
        if os.path.exists(xauthority):
            env["XAUTHORITY"] = xauthority
        kind = "x11"
    groups = os.getgrouplist(entry.pw_name, entry.pw_gid)
    return Session(uid=uid, gid=entry.pw_gid, groups=groups, env=env, kind=kind, home=entry.pw_dir)


def available_tools() -> list:
    return [tool for tool in CAPTURE_TOOLS if shutil.which(tool)]


def detect_encoder(preference: str) -> str:
    if preference != "auto":
        return preference
    if os.path.exists("/dev/nvidiactl"):
        return "nvenc"
    if os.path.exists(RENDER_NODE):
        return "vaapi"
    return "x264"


def candidate_pipelines(preference: str, kind: str, tools: list) -> list:
    encoders = [detect_encoder(preference)]
    if preference == "auto" and "x264" not in encoders:
        encoders.append("x264")
    pipelines = []
    for encoder in encoders:
        if kind == "wayland":
            if encoder == "vaapi" and "wl-screenrec" in tools:
                pipelines.append(("wl-screenrec", encoder))
            if "wf-recorder" in tools:
                pipelines.append(("wf-recorder", encoder))
        elif "ffmpeg" in tools:
            pipelines.append(("ffmpeg", encoder))
    return pipelines


def parse_hyprctl(text: Optional[str]) -> Optional[Screen]:
    try:
        monitors = json.loads(text or "")
    except json.JSONDecodeError:
        return None
    if not isinstance(monitors, list) or not monitors:
        return None
    chosen = next((m for m in monitors if m.get("focused")), monitors[0])
    try:
        return Screen(str(chosen["name"]), int(chosen["width"]), int(chosen["height"]))
    except (KeyError, TypeError, ValueError):
        return None


def parse_wlr_randr(text: Optional[str]) -> Optional[Screen]:
    try:
        outputs = json.loads(text or "")
    except json.JSONDecodeError:
        return None
    if not isinstance(outputs, list):
        return None
    for output in outputs:
        if not output.get("enabled", True):
            continue
        for mode in output.get("modes", []):
            if mode.get("current"):
                try:
                    return Screen(str(output["name"]), int(mode["width"]), int(mode["height"]))
                except (KeyError, TypeError, ValueError):
                    return None
    return None


async def run_text(argv: list, session: Session, timeout: float = 3.0) -> Optional[str]:
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
            env=session.env,
            **session.spawn_args(),
        )
    except OSError:
        return None
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return None
    return out.decode(errors="replace") if proc.returncode == 0 else None


async def detect_screen(session: Session) -> Optional[Screen]:
    if session.kind != "wayland":
        return None
    if shutil.which("hyprctl"):
        screen = parse_hyprctl(await run_text(["hyprctl", "monitors", "-j"], session))
        if screen:
            return screen
    if shutil.which("wlr-randr"):
        return parse_wlr_randr(await run_text(["wlr-randr", "--json"], session))
    return None


def target_size(level: dict, screen: Optional[Screen]) -> Optional[tuple]:
    if screen is None or screen.height <= 0:
        return None
    height = min(level["height"], screen.height)
    width = screen.width * height // screen.height
    return width // 2 * 2, height // 2 * 2


def scale_filter(level: dict, size: Optional[tuple]) -> str:
    if size:
        return f"scale={size[0]}:{size[1]}"
    return f"scale=-2:{level['height']}"


def build_command(tool: str, encoder: str, level: dict, screen: Optional[Screen], session: Session, fifo: Optional[str]) -> list:
    fps = level["fps"] if tool == "wl-screenrec" else min(level["fps"], SOFTWARE_MAX_FPS)
    kbps = level["kbps"]
    size = target_size(level, screen)
    if tool == "wl-screenrec":
        argv = [
            "wl-screenrec",
            "--codec", "avc",
            "--gop-size", str(fps),
            "--max-fps", str(fps),
            "--no-damage",
            "--ffmpeg-encoder-options", "bf=0",
            "-b", f"{kbps // 8}KB",
            "--ffmpeg-muxer", "h264",
            "-f", fifo,
        ]
        if screen:
            argv += ["-o", screen.name]
        if size:
            argv += ["--encode-resolution", f"{size[0]}x{size[1]}"]
        return argv
    if tool == "wf-recorder":
        argv = ["wf-recorder", "-y", "-m", "h264", "-f", fifo, "-r", str(fps)]
        if screen:
            argv += ["-o", screen.name]
        argv += ["-p", f"b={kbps}k", "-p", f"maxrate={kbps}k", "-p", f"bufsize={kbps // 2}k", "-p", f"g={fps}", "-p", "bf=0"]
        if encoder == "vaapi":
            vaapi_scale = f"w={size[0]}:h={size[1]}" if size else f"w=-2:h={level['height']}"
            argv += ["-c", "h264_vaapi", "-d", RENDER_NODE, "-F", f"scale_vaapi={vaapi_scale}:format=nv12:out_range=full"]
        elif encoder == "nvenc":
            argv += ["-c", "h264_nvenc", "-p", "preset=p1", "-p", "tune=ll", "-p", "zerolatency=1", "-F", scale_filter(level, size)]
        else:
            argv += ["-c", "libx264", "-x", "yuv420p", "-p", "preset=ultrafast", "-p", "tune=zerolatency", "-p", "threads=2", "-F", scale_filter(level, size)]
        return argv
    argv = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-fflags", "nobuffer",
        "-f", "x11grab", "-framerate", str(fps), "-i", session.env["DISPLAY"],
    ]
    base_filter = f"scale=-2:{level['height']}"
    if encoder == "vaapi":
        argv[1:1] = ["-vaapi_device", RENDER_NODE]
        argv += ["-vf", f"{base_filter},format=nv12,hwupload", "-c:v", "h264_vaapi"]
    elif encoder == "nvenc":
        argv += ["-vf", base_filter, "-c:v", "h264_nvenc", "-preset", "p1", "-tune", "ll", "-zerolatency", "1"]
    else:
        argv += ["-vf", f"{base_filter},format=yuv420p", "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-threads", "2"]
    argv += ["-b:v", f"{kbps}k", "-maxrate", f"{kbps}k", "-bufsize", f"{kbps // 2}k", "-g", str(fps), "-bf", "0", "-f", "h264", "pipe:1"]
    return argv


class AnnexBSplitter:
    MAX_BUFFER = 8 * 1024 * 1024

    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data: bytes) -> list:
        self.buffer += data
        starts = []
        position = 0
        while True:
            index = self.buffer.find(b"\x00\x00\x01", position)
            if index < 0:
                break
            starts.append(index)
            position = index + 3
        if not starts:
            if len(self.buffer) > self.MAX_BUFFER:
                self.buffer.clear()
            return []
        nals = []
        for begin, end in zip(starts, starts[1:]):
            nal = bytes(self.buffer[begin + 3:end]).rstrip(b"\x00")
            if nal:
                nals.append(nal)
        del self.buffer[:starts[-1]]
        return nals

    def take_open(self) -> Optional[bytes]:
        if not self.buffer.startswith(b"\x00\x00\x01"):
            self.buffer.clear()
            return None
        nal = bytes(self.buffer[3:]).rstrip(b"\x00")
        self.buffer.clear()
        return nal or None


class FrameAssembler:
    def __init__(self):
        self.sps = None
        self.pps = None
        self.pending = []
        self.has_slice = False
        self.key = False

    def flush(self) -> list:
        frames = []
        if self.pending and self.has_slice:
            if not self.key or (self.sps and self.pps):
                frames.append(Frame(self.key, self.pending, self.sps, self.pps))
        self.pending = []
        self.has_slice = False
        self.key = False
        return frames

    def push(self, nal: bytes) -> list:
        kind = nal[0] & 0x1F
        if kind in (6, 7, 8, 9):
            frames = self.flush() if self.has_slice else []
            if kind == 7:
                self.sps = nal
            elif kind == 8:
                self.pps = nal
            return frames
        if kind in (1, 5):
            starts_picture = len(nal) > 1 and bool(nal[1] & 0x80)
            frames = self.flush() if (starts_picture and self.has_slice) else []
            self.pending.append(nal)
            self.has_slice = True
            self.key = self.key or kind == 5
            return frames
        return []


def encode_frame(frame: Frame) -> bytes:
    parts = [bytes([0b11 if frame.key else 0])]
    if frame.key:
        parts.append(struct.pack(">H", len(frame.sps)) + frame.sps)
        parts.append(struct.pack(">H", len(frame.pps)) + frame.pps)
    parts.extend(struct.pack(">I", len(nal)) + nal for nal in frame.nals)
    return b"".join(parts)


def parse_quality(value) -> Optional[int]:
    return LEVEL_INDEX.get(value) if isinstance(value, str) else None


class StreamClient:
    def __init__(self, websocket, fixed: Optional[int]):
        self.websocket = websocket
        self.fixed = fixed
        self.queue = asyncio.Queue(maxsize=CLIENT_QUEUE_SIZE)
        self.need_key = True

    def offer(self, payload: bytes, key: bool) -> bool:
        if self.need_key and not key:
            return False
        dropped = False
        if self.queue.full():
            while not self.queue.empty():
                self.queue.get_nowait()
            dropped = True
            if not key:
                self.need_key = True
                return True
        if key:
            self.need_key = False
        self.queue.put_nowait(payload)
        return dropped

    def push_text(self, text: str):
        if self.queue.full():
            while not self.queue.empty():
                self.queue.get_nowait()
            self.need_key = True
        self.queue.put_nowait(text)


def tune_socket(websocket):
    try:
        sock = websocket.transport.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, SOCKET_SEND_BUFFER)
        websocket.transport.set_write_buffer_limits(high=WRITE_BUFFER_HIGH, low=WRITE_BUFFER_LOW)
    except Exception as exc:
        log.warning("Réglage de la socket vidéo non appliqué: %s", exc)


def send_backlog(websocket) -> int:
    transport = websocket.transport
    pending = transport.get_write_buffer_size()
    try:
        sock = transport.get_extra_info("socket")
        pending += struct.unpack("i", fcntl.ioctl(sock.fileno(), termios.TIOCOUTQ, b"\0\0\0\0"))[0]
    except (OSError, AttributeError, ValueError):
        pass
    return pending


def lower_priority(pid: int):
    try:
        os.sched_setscheduler(pid, os.SCHED_OTHER, os.sched_param(0))
    except (OSError, AttributeError):
        pass
    try:
        os.setpriority(os.PRIO_PROCESS, pid, 5)
    except OSError:
        pass


async def stop_process(proc):
    if proc.returncode is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        await asyncio.wait_for(proc.wait(), 2.0)
    except asyncio.TimeoutError:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        await proc.wait()


def make_fifo(session: Session) -> tuple:
    directory = tempfile.mkdtemp(prefix="gamepad-stream-")
    path = os.path.join(directory, "video.h264")
    os.mkfifo(path, 0o600)
    if os.geteuid() == 0:
        os.chown(directory, session.uid, session.gid)
        os.chown(path, session.uid, session.gid)
    return directory, path


async def open_fifo_reader(path: str):
    loop = asyncio.get_running_loop()
    descriptor = os.open(path, os.O_RDWR | os.O_NONBLOCK)
    reader = asyncio.StreamReader(limit=2 ** 20)
    protocol = asyncio.StreamReaderProtocol(reader)
    transport, _ = await loop.connect_read_pipe(lambda: protocol, os.fdopen(descriptor, "rb", 0))
    return reader, transport


def stream_report(preference: str = "auto") -> tuple:
    ok = True
    lines = []
    tools = available_tools()
    for tool in CAPTURE_TOOLS:
        lines.append(f"[{'OK' if tool in tools else 'WARN'}] {tool} {'trouvé' if tool in tools else 'absent'}")
    try:
        session = find_session()
        lines.append(f"[OK] session {session.kind} trouvée pour l'utilisateur {session.uid}")
    except StreamUnavailable as exc:
        lines.append(f"[FAIL] {exc}")
        return False, lines
    lines.append(f"[INFO] encodeur retenu : {detect_encoder(preference)}")
    pipelines = candidate_pipelines(preference, session.kind, tools)
    if pipelines:
        lines.append("[OK] chaînes de capture possibles : " + ", ".join(f"{tool}/{encoder}" for tool, encoder in pipelines))
    else:
        ok = False
        lines.append("[FAIL] aucun outil de capture utilisable (installe wl-screenrec ou wf-recorder, ou ffmpeg sous X11 ; module NixOS : programs.gamepadServer.screenStream)")
    return ok, lines


class ScreenStream:
    def __init__(self, secret: str, encoder: str = "auto", diagnostics: bool = False):
        self.secret = secret
        self.encoder = encoder
        self.diagnostics = diagnostics
        self.pipeline_label = ""
        self.stats = {"frames": 0, "bytes": 0, "gap": 0.0, "last": None, "drops": 0, "backlog": 0, "send": 0.0}
        self.clients = set()
        self.state = "idle"
        self.reason = None
        self.running_index = AUTO_START_INDEX
        self.auto_index = AUTO_START_INDEX
        self.drops = collections.deque()
        self.last_change = 0.0
        self.supervisor = None
        self.restart = asyncio.Event()

    def availability(self) -> Optional[str]:
        ok, lines = stream_report(self.encoder)
        if ok:
            return None
        failures = [line.split("] ", 1)[1] for line in lines if line.startswith("[FAIL]")]
        return "; ".join(failures)

    async def start(self, host: str, port: int):
        return await websockets.serve(self.handle, host, port, max_size=4096)

    async def stop(self, server):
        server.close()
        for client in list(self.clients):
            await client.websocket.close()
        await server.wait_closed()
        if self.supervisor is not None:
            self.supervisor.cancel()
            await asyncio.gather(self.supervisor, return_exceptions=True)

    def desired_index(self) -> int:
        indexes = [client.fixed if client.fixed is not None else self.auto_index for client in self.clients]
        return max(indexes) if indexes else self.auto_index

    def request_restart_if_needed(self):
        if self.state != "idle" and self.desired_index() != self.running_index:
            self.restart.set()

    def status_message(self) -> str:
        message = {"type": "stream_status", "state": self.state, "level": QUALITY_LEVELS[self.running_index]["name"]}
        if self.reason:
            message["reason"] = self.reason
        return json.dumps(message)

    def set_state(self, state: str, reason: Optional[str] = None):
        if state == self.state and reason == self.reason:
            return
        self.state = state
        self.reason = reason
        text = self.status_message()
        for client in self.clients:
            client.push_text(text)

    def on_frame(self, frame: Frame):
        if self.state != "active":
            self.set_state("active")
        payload = encode_frame(frame)
        now = asyncio.get_running_loop().time()
        if self.diagnostics:
            if self.stats["last"] is not None:
                self.stats["gap"] = max(self.stats["gap"], now - self.stats["last"])
            self.stats["last"] = now
            self.stats["frames"] += 1
            self.stats["bytes"] += len(payload)
        for client in list(self.clients):
            dropped = client.offer(payload, frame.key)
            if dropped:
                self.stats["drops"] += 1
            if dropped and client.fixed is None:
                self.drops.append(now)

    def on_clients_changed(self):
        if not self.clients:
            self.restart.set()
            return
        if self.supervisor is None or self.supervisor.done():
            self.auto_index = AUTO_START_INDEX
            self.drops.clear()
            self.last_change = asyncio.get_running_loop().time()
            self.supervisor = asyncio.create_task(self.supervise())
        else:
            self.request_restart_if_needed()

    async def handle(self, websocket):
        tune_socket(websocket)
        peer = websocket.remote_address
        try:
            hello = json.loads(await asyncio.wait_for(websocket.recv(), HANDSHAKE_TIMEOUT))
        except (asyncio.TimeoutError, json.JSONDecodeError, websockets.exceptions.ConnectionClosed):
            return
        if not isinstance(hello, dict) or hello.get("type") != "stream_hello":
            await websocket.send(json.dumps({"type": "stream_ack", "ok": False, "reason": "handshake attendu"}))
            return
        given = hello.get("secret")
        if not isinstance(given, str) or not hmac.compare_digest(given.encode(), self.secret.encode()):
            log.warning("Flux d'écran refusé pour %s : secret absent ou invalide", peer)
            await websocket.send(json.dumps({
                "type": "stream_ack",
                "ok": False,
                "reason": "secret absent ou invalide, scanne le QR code affiché par le serveur",
            }))
            await asyncio.sleep(1.0)
            return
        if len(self.clients) >= MAX_STREAM_CLIENTS:
            await websocket.send(json.dumps({"type": "stream_ack", "ok": False, "reason": "nombre maximum de flux atteint"}))
            return
        client = StreamClient(websocket, parse_quality(hello.get("quality")))
        self.clients.add(client)
        await websocket.send(json.dumps({
            "type": "stream_ack",
            "ok": True,
            "protocolVersion": STREAM_PROTOCOL_VERSION,
            "codec": "h264",
            "qualities": [level["name"] for level in QUALITY_LEVELS],
        }))
        log.info("Flux d'écran ouvert pour %s", peer)
        sender = asyncio.create_task(self.send_loop(client))
        self.on_clients_changed()
        client.push_text(self.status_message())
        try:
            async for raw in websocket:
                if not isinstance(raw, str):
                    continue
                try:
                    message = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if isinstance(message, dict) and message.get("type") == "quality":
                    client.fixed = parse_quality(message.get("quality"))
                    self.request_restart_if_needed()
        except websockets.exceptions.ConnectionClosed:
            pass
        finally:
            sender.cancel()
            self.clients.discard(client)
            self.on_clients_changed()
            log.info("Flux d'écran fermé pour %s", peer)

    async def send_loop(self, client: StreamClient):
        try:
            while True:
                item = await client.queue.get()
                started = time.perf_counter()
                await asyncio.wait_for(client.websocket.send(item), SEND_TIMEOUT)
                elapsed = time.perf_counter() - started
                if elapsed > SLOW_SEND_SECONDS and client.fixed is None:
                    self.drops.append(asyncio.get_running_loop().time())
                if self.diagnostics:
                    self.stats["send"] = max(self.stats["send"], elapsed)
        except asyncio.TimeoutError:
            log.warning("Flux d'écran : client trop lent, connexion vidéo fermée")
            await client.websocket.close()
        except websockets.exceptions.ConnectionClosed:
            pass

    def log_stats(self, seconds: float):
        stats = self.stats
        diag_log.info(
            "diag flux : %.0f img/s | %.0f kbit/s | écart max entre images %.0f ms | %d abandon(s) | file d'envoi max %.0f Ko | envoi max %.0f ms | niveau %s | capture %s",
            stats["frames"] / seconds,
            stats["bytes"] * 8 / 1000 / seconds,
            stats["gap"] * 1000,
            stats["drops"],
            stats["backlog"] / 1024,
            stats["send"] * 1000,
            QUALITY_LEVELS[self.running_index]["name"],
            self.pipeline_label,
        )
        stats.update(frames=0, bytes=0, gap=0.0, drops=0, backlog=0, send=0.0)

    async def adapt_loop(self):
        loop = asyncio.get_running_loop()
        ticks = 0
        while True:
            await asyncio.sleep(ADAPT_INTERVAL)
            ticks += 1
            if self.diagnostics:
                for client in list(self.clients):
                    self.stats["backlog"] = max(self.stats["backlog"], send_backlog(client.websocket))
                if ticks % DIAG_INTERVAL_TICKS == 0 and self.clients:
                    self.log_stats(DIAG_INTERVAL_TICKS * ADAPT_INTERVAL)
            now = loop.time()
            while self.drops and now - self.drops[0] > ADAPT_DROP_WINDOW:
                self.drops.popleft()
            since_change = now - self.last_change
            last_index = len(QUALITY_LEVELS) - 1
            if len(self.drops) >= ADAPT_DROPS_TO_DEGRADE and self.auto_index < last_index and since_change >= ADAPT_MIN_STEP_INTERVAL:
                self.auto_index += 1
                self.drops.clear()
                self.last_change = now
                log.info("Flux d'écran : réseau chargé, qualité abaissée à %s", QUALITY_LEVELS[self.auto_index]["name"])
                self.request_restart_if_needed()
            elif not self.drops and self.auto_index > 0 and since_change >= ADAPT_CLEAN_TIME_TO_RECOVER:
                self.auto_index -= 1
                self.last_change = now
                log.info("Flux d'écran : réseau stable, qualité relevée à %s", QUALITY_LEVELS[self.auto_index]["name"])
                self.request_restart_if_needed()

    async def supervise(self):
        loop = asyncio.get_running_loop()
        self.stats.update(frames=0, bytes=0, gap=0.0, last=None, drops=0, backlog=0, send=0.0)
        adapt = asyncio.create_task(self.adapt_loop())
        try:
            try:
                session = find_session()
            except StreamUnavailable as exc:
                self.set_state("unavailable", str(exc))
                return
            pipelines = candidate_pipelines(self.encoder, session.kind, available_tools())
            if not pipelines:
                self.set_state("unavailable", "aucun outil de capture installé sur le PC")
                return
            screen = await detect_screen(session)
            position = 0
            while self.clients:
                self.running_index = self.desired_index()
                self.restart.clear()
                self.set_state("waiting")
                tool, encoder = pipelines[position]
                self.pipeline_label = f"{tool}/{encoder}"
                log.info("Flux d'écran : capture %s/%s, qualité %s", tool, encoder, QUALITY_LEVELS[self.running_index]["name"])
                started = loop.time()
                outcome, detail = await self.run_capture(session, screen, tool, encoder, QUALITY_LEVELS[self.running_index])
                if outcome == "restart":
                    continue
                if not self.clients:
                    break
                log.warning("Flux d'écran : %s/%s arrêté (%s)", tool, encoder, detail)
                if loop.time() - started >= MIN_HEALTHY_RUN:
                    await asyncio.sleep(1.0)
                    continue
                position += 1
                if position >= len(pipelines):
                    self.set_state("unavailable", f"la capture échoue : {detail}"[:200])
                    break
                await asyncio.sleep(1.0)
        finally:
            adapt.cancel()
            if not self.clients:
                self.state = "idle"
                self.reason = None

    async def run_capture(self, session, screen, tool, encoder, level) -> tuple:
        fifo_dir = None
        transport = None
        proc = None
        tasks = []
        stderr_tail = collections.deque(maxlen=15)
        try:
            fifo = None
            source = None
            if tool != "ffmpeg":
                fifo_dir, fifo = make_fifo(session)
                source, transport = await open_fifo_reader(fifo)
            argv = build_command(tool, encoder, level, screen, session, fifo)
            proc = await asyncio.create_subprocess_exec(
                *argv,
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE if tool == "ffmpeg" else asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
                env=session.env,
                cwd=session.home if os.path.isdir(session.home) else "/",
                start_new_session=True,
                **session.spawn_args(),
            )
            lower_priority(proc.pid)
            if source is None:
                source = proc.stdout

            async def collect_errors():
                async for line in proc.stderr:
                    stderr_tail.append(line.decode(errors="replace").strip())

            async def pump():
                splitter = AnnexBSplitter()
                assembler = FrameAssembler()
                while True:
                    try:
                        data = await asyncio.wait_for(source.read(65536), IDLE_FLUSH_SECONDS if splitter.buffer else None)
                    except asyncio.TimeoutError:
                        last = splitter.take_open()
                        frames = assembler.push(last) if last else []
                        frames += assembler.flush()
                        for frame in frames:
                            self.on_frame(frame)
                        continue
                    if not data:
                        return
                    for nal in splitter.feed(data):
                        for frame in assembler.push(nal):
                            self.on_frame(frame)

            pump_task = asyncio.create_task(pump())
            exit_task = asyncio.create_task(proc.wait())
            restart_task = asyncio.create_task(self.restart.wait())
            tasks = [asyncio.create_task(collect_errors()), pump_task, exit_task, restart_task]
            done, _ = await asyncio.wait({pump_task, exit_task, restart_task}, return_when=asyncio.FIRST_COMPLETED)
            if restart_task in done and exit_task not in done:
                return "restart", None
            await asyncio.sleep(0.1)
            detail = next((line for line in reversed(stderr_tail) if line), f"code de sortie {proc.returncode}")
            return "exited", detail
        finally:
            if proc is not None:
                await stop_process(proc)
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            if transport is not None:
                transport.close()
            if fifo_dir is not None:
                shutil.rmtree(fifo_dir, ignore_errors=True)
