#!/usr/bin/env python3

import argparse
import asyncio
import collections
import errno
import json
import logging
import os
import re
import resource
import shutil
import socket
import subprocess
import sys
import time

import websockets
from evdev import UInput, ecodes as e, AbsInfo
from evdev.uinput import UInputError

try:
    from zeroconf import ServiceInfo
    from zeroconf.asyncio import AsyncZeroconf
    ZEROCONF_AVAILABLE = True
except ImportError:
    ZEROCONF_AVAILABLE = False

try:
    import qrcode
    QRCODE_AVAILABLE = True
except ImportError:
    QRCODE_AVAILABLE = False

MDNS_SERVICE_TYPE = "_gamepad._tcp.local."
NETWORK_POLL_SECONDS = 1.5
CONTROL_TOS = 0xB8
SERVER_NICE = -10
RESTART_ENV = "GAMEPAD_RESTARTED"
SECRET_ENV = "GAMEPAD_STREAM_SECRET"
PROTOCOL_VERSION = 1

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("gamepad")
diag_log = logging.getLogger("gamepad.diag")

def route_diagnostics_to_file(path):
    path = os.path.abspath(path)
    handler = logging.FileHandler(path, mode="a" if os.environ.get(RESTART_ENV) else "w", encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    diag_log.addHandler(handler)
    diag_log.propagate = False
    try:
        os.chown(path, int(os.environ["SUDO_UID"]), int(os.environ.get("SUDO_GID", os.environ["SUDO_UID"])))
    except (KeyError, ValueError, OSError):
        pass
    return path

class ProbeDisconnectFilter(logging.Filter):
    def filter(self, record):
        exc = record.exc_info[1] if record.exc_info else None
        return not (
            isinstance(exc, websockets.exceptions.InvalidMessage)
            and isinstance(exc.__cause__, EOFError)
        )

logging.getLogger("websockets.server").addFilter(ProbeDisconnectFilter())

class NetworkDropFilter(logging.Filter):
    NETWORK_ERRNOS = {errno.ENETUNREACH, errno.ENETDOWN, errno.EHOSTUNREACH}

    def filter(self, record):
        exc = record.exc_info[1] if record.exc_info else None
        if isinstance(exc, OSError) and exc.errno in self.NETWORK_ERRNOS:
            record.msg = "mDNS: réseau injoignable pendant un envoi (%s), le serveur continue de tourner"
            record.args = (exc.strerror,)
            record.exc_info = None
            record.exc_text = None
        return True

logging.getLogger("zeroconf").addFilter(NetworkDropFilter())

AXIS_MIN = -32768
AXIS_MAX = 32767

BUTTON_MAP = {
    "a": e.BTN_SOUTH,
    "b": e.BTN_EAST,
    "x": e.BTN_NORTH,
    "y": e.BTN_WEST,
    "l1": e.BTN_TL,
    "r1": e.BTN_TR,
    "select": e.BTN_SELECT,
    "start": e.BTN_START,
    "mode": e.BTN_MODE,
    "thumbl": e.BTN_THUMBL,
    "thumbr": e.BTN_THUMBR,
}

STICK_AXES = {
    "left": (e.ABS_X, e.ABS_Y),
    "right": (e.ABS_RX, e.ABS_RY),
}

TRIGGER_AXES = {
    "l2": e.ABS_Z,
    "r2": e.ABS_RZ,
}

DPAD_AXES = (e.ABS_HAT0X, e.ABS_HAT0Y)

DEADMAN_TIMEOUT = 1.2

CAPABILITIES = {
    e.EV_KEY: list(BUTTON_MAP.values()),
    e.EV_ABS: [
        (axis, AbsInfo(value=0, min=AXIS_MIN, max=AXIS_MAX, fuzz=0, flat=0, resolution=0))
        for pair in STICK_AXES.values()
        for axis in pair
    ] + [
        (axis, AbsInfo(value=0, min=0, max=255, fuzz=0, flat=0, resolution=0))
        for axis in TRIGGER_AXES.values()
    ] + [
        (axis, AbsInfo(value=0, min=-1, max=1, fuzz=0, flat=0, resolution=0))
        for axis in DPAD_AXES
    ],
}

def clamp(v, lo, hi):
    return max(lo, min(hi, v))

def to_axis_value(f: float) -> int:
    f = clamp(f, -1.0, 1.0)
    return int(f * AXIS_MAX)

def to_trigger_value(f: float) -> int:
    f = clamp(f, 0.0, 1.0)
    return int(f * 255)

def uinput_problem():
    if not os.path.exists("/dev/uinput"):
        return "/dev/uinput absent (module uinput non chargé, ou hardware.uinput.enable sur NixOS)"
    if not os.access("/dev/uinput", os.R_OK | os.W_OK):
        return "/dev/uinput inaccessible : lance le serveur avec sudo ou ajoute ton utilisateur au groupe uinput"
    return None

XBOX360_VENDOR = 0x045e
XBOX360_PRODUCT = 0x028e

class VirtualGamepad:
    def __init__(self, index: int = 0):
        suffix = f" #{index + 1}" if index > 0 else ""
        self.ui = UInput(
            CAPABILITIES,
            name=f"Microsoft X-Box 360 pad{suffix}",
            vendor=XBOX360_VENDOR,
            product=XBOX360_PRODUCT,
            version=0x110,
        )
        log.info("Manette virtuelle créée (Xbox 360 %04x:%04x) : %s", XBOX360_VENDOR, XBOX360_PRODUCT, self.ui.device.path)

    def handle_message(self, msg: dict):
        mtype = msg.get("type")

        if mtype == "button":
            name = msg.get("name")
            code = BUTTON_MAP.get(name)
            if code is None:
                log.warning("Bouton inconnu: %s", name)
                return
            self.ui.write(e.EV_KEY, code, 1 if msg.get("pressed") else 0)
            self.ui.syn()

        elif mtype == "stick":
            name = msg.get("name")
            axes = STICK_AXES.get(name)
            if axes is None:
                log.warning("Stick inconnu: %s", name)
                return
            ax_x, ax_y = axes
            self.ui.write(e.EV_ABS, ax_x, to_axis_value(msg.get("x", 0.0)))
            self.ui.write(e.EV_ABS, ax_y, to_axis_value(msg.get("y", 0.0)))
            self.ui.syn()

        elif mtype == "trigger":
            name = msg.get("name")
            axis = TRIGGER_AXES.get(name)
            if axis is None:
                log.warning("Gâchette inconnue: %s", name)
                return
            self.ui.write(e.EV_ABS, axis, to_trigger_value(msg.get("value", 0.0)))
            self.ui.syn()

        elif mtype == "dpad":
            dx = clamp(int(msg.get("x", 0)), -1, 1)
            dy = clamp(int(msg.get("y", 0)), -1, 1)
            self.ui.write(e.EV_ABS, e.ABS_HAT0X, dx)
            self.ui.write(e.EV_ABS, e.ABS_HAT0Y, dy)
            self.ui.syn()

        elif mtype == "gyro":
            pass

        else:
            log.warning("Message inconnu: %s", msg)

    def neutralize(self):
        for code in BUTTON_MAP.values():
            self.ui.write(e.EV_KEY, code, 0)
        for pair in STICK_AXES.values():
            for axis in pair:
                self.ui.write(e.EV_ABS, axis, 0)
        for axis in TRIGGER_AXES.values():
            self.ui.write(e.EV_ABS, axis, 0)
        self.ui.write(e.EV_ABS, e.ABS_HAT0X, 0)
        self.ui.write(e.EV_ABS, e.ABS_HAT0Y, 0)
        self.ui.syn()

    def close(self):
        self.ui.close()

class GamepadPool:
    """Attribue une manette virtuelle par connexion cliente (multi-manettes)."""

    def __init__(self, max_pads: int = 4):
        self.max_pads = max_pads
        self._free_slots = list(range(max_pads))
        self._lock = asyncio.Lock()

    async def acquire(self) -> "tuple[int, VirtualGamepad] | None":
        async with self._lock:
            if not self._free_slots:
                return None
            slot = self._free_slots.pop(0)
            try:
                return slot, VirtualGamepad(index=slot)
            except Exception:
                self._free_slots.insert(0, slot)
                raise

    async def release(self, slot: int):
        async with self._lock:
            self._free_slots.append(slot)
            self._free_slots.sort()

def disable_nagle(websocket):
    try:
        sock = websocket.transport.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_TOS, CONTROL_TOS)
    except Exception as exc:
        log.warning("TCP_NODELAY non appliqué: %s", exc)

def raise_priority():
    try:
        os.setpriority(os.PRIO_PROCESS, 0, SERVER_NICE)
    except OSError as exc:
        log.info("Priorité du serveur inchangée (%s), lance-le avec sudo pour la relever", exc.strerror)
        return
    try:
        with open("/proc/self/autogroup", "w", encoding="ascii") as group:
            group.write(str(SERVER_NICE))
    except OSError:
        pass

def default_interface() -> "str | None":
    try:
        with open("/proc/net/route", encoding="ascii") as routes:
            for line in list(routes)[1:]:
                fields = line.split()
                if len(fields) > 3 and fields[1] == "00000000" and int(fields[3], 16) & 2:
                    return fields[0]
    except (OSError, ValueError):
        pass
    return None

def wifi_power_save_off() -> "str | None":
    interface = default_interface()
    if interface is None or os.geteuid() != 0 or shutil.which("iw") is None:
        return None
    if not os.path.isdir(f"/sys/class/net/{interface}/wireless"):
        return None
    try:
        state = subprocess.run(["iw", "dev", interface, "get", "power_save"], capture_output=True, text=True, timeout=3).stdout
        if not re.search(r"power save:\s*on", state, re.IGNORECASE):
            return None
        subprocess.run(["iw", "dev", interface, "set", "power_save", "off"], check=True, capture_output=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return None
    log.info("Économie d'énergie Wi-Fi coupée sur %s pendant la session (rétablie à l'arrêt)", interface)
    return interface

def wifi_power_save_restore(interface: "str | None"):
    if interface is None:
        return
    try:
        subprocess.run(["iw", "dev", interface, "set", "power_save", "on"], check=True, capture_output=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        pass

class DiagStats:
    def __init__(self):
        self.reset()

    def reset(self):
        self.messages = 0
        self.ping_gap_max = 0.0
        self.up_sum = 0.0
        self.up_count = 0
        self.up_max = 0.0
        self.process_max = 0.0
        self.echo_max = 0.0

def read_pressure() -> dict:
    totals = {}
    for name in ("cpu", "memory", "io"):
        try:
            with open(f"/proc/pressure/{name}", encoding="ascii") as handle:
                for line in handle:
                    if line.startswith("some"):
                        totals[name] = int(line.rsplit("total=", 1)[1])
        except (OSError, ValueError, IndexError):
            pass
    return totals

async def diag_monitor(diag: DiagStats):
    loop = asyncio.get_running_loop()
    tick = 0.01
    lag_sum = 0.0
    lag_max = 0.0
    lag_count = 0
    report_at = loop.time() + 1.0
    pressure = read_pressure()
    usage = resource.getrusage(resource.RUSAGE_SELF)
    usage_at = time.monotonic()
    while True:
        started = loop.time()
        await asyncio.sleep(tick)
        now = loop.time()
        lag = max(0.0, now - started - tick)
        lag_sum += lag
        lag_max = max(lag_max, lag)
        lag_count += 1
        if now >= report_at:
            current_pressure = read_pressure()
            current_usage = resource.getrusage(resource.RUSAGE_SELF)
            current_at = time.monotonic()
            blocked = {name: (current_pressure.get(name, 0) - pressure.get(name, 0)) / 1000 for name in ("cpu", "memory", "io")}
            cpu_share = (current_usage.ru_utime + current_usage.ru_stime - usage.ru_utime - usage.ru_stime) / max(current_at - usage_at, 1e-6) * 100
            preempted = current_usage.ru_nivcsw - usage.ru_nivcsw
            pressure = current_pressure
            usage = current_usage
            usage_at = current_at
            if diag.messages:
                diag_log.info(
                    "diag: retard boucle moy %.2f max %.2f ms | %d msg | écart max entre pings %.0f ms | montée relative moy %.1f max %.1f ms | traitement max %.2f ms | écho max %.2f ms | machine bloquée cpu %.0f mém %.0f dsk %.0f ms/s | CPU serveur %.0f %% | préemptions %d",
                    lag_sum / lag_count * 1000,
                    lag_max * 1000,
                    diag.messages,
                    diag.ping_gap_max * 1000,
                    diag.up_sum / diag.up_count if diag.up_count else 0.0,
                    diag.up_max,
                    diag.process_max * 1000,
                    diag.echo_max * 1000,
                    blocked["cpu"],
                    blocked["memory"],
                    blocked["io"],
                    cpu_share,
                    preempted,
                )
            diag.reset()
            lag_sum = 0.0
            lag_max = 0.0
            lag_count = 0
            report_at = now + 1.0

async def deadman_watchdog(gamepad: VirtualGamepad, last_seen: dict, stop_event: asyncio.Event):
    try:
        while not stop_event.is_set():
            await asyncio.sleep(DEADMAN_TIMEOUT / 2)
            elapsed = asyncio.get_event_loop().time() - last_seen["t"]
            if elapsed > DEADMAN_TIMEOUT and not last_seen.get("neutral", False):
                log.warning("Deadman: aucun message depuis %.2fs, remise au neutre", elapsed)
                gamepad.neutralize()
                last_seen["neutral"] = True
    except asyncio.CancelledError:
        pass

async def handler(websocket, pool: GamepadPool, diag: DiagStats, stream_info=None):
    disable_nagle(websocket)
    peer = websocket.remote_address
    log.info("iPhone connecté depuis %s, en attente du handshake", peer)

    slot_and_pad = None
    watchdog_task = None
    stop_event = asyncio.Event()
    try:
        raw = await asyncio.wait_for(websocket.recv(), timeout=5.0)
        hello = json.loads(raw)
        if hello.get("type") != "hello":
            await websocket.send(json.dumps({"type": "hello_ack", "ok": False, "reason": "handshake attendu"}))
            return

        try:
            slot_and_pad = await pool.acquire()
        except (UInputError, OSError) as exc:
            reason = uinput_problem() or f"{type(exc).__name__}: {exc}"
            log.error("Création de la manette virtuelle impossible pour %s : %s", peer, reason)
            await websocket.send(json.dumps({
                "type": "hello_ack",
                "ok": False,
                "reason": f"Le serveur ne peut pas créer la manette virtuelle : {reason}",
            }))
            return
        if slot_and_pad is None:
            await websocket.send(json.dumps({"type": "hello_ack", "ok": False, "reason": "nombre maximum de manettes atteint"}))
            return
        slot, gamepad = slot_and_pad

        ack = {
            "type": "hello_ack",
            "ok": True,
            "protocolVersion": PROTOCOL_VERSION,
            "slot": slot,
            "features": ["deadman", "xbox360_id", "trigger_analog", "thumb_click"],
        }
        if stream_info is not None:
            ack["features"].append("screen_stream")
            ack.update(stream_info)
        await websocket.send(json.dumps(ack))
        log.info("iPhone %s apparié, manette virtuelle #%d", peer, slot + 1)

    except (asyncio.TimeoutError, json.JSONDecodeError, websockets.exceptions.ConnectionClosed):
        log.warning("Handshake échoué depuis %s", peer)
        return

    last_seen = {"t": asyncio.get_event_loop().time(), "neutral": False}
    watchdog_task = asyncio.create_task(deadman_watchdog(gamepad, last_seen, stop_event))
    last_ping = None
    up_window = collections.deque()
    try:
        async for raw in websocket:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                log.warning("JSON invalide: %r", raw)
                continue
            now = asyncio.get_event_loop().time()
            last_seen["t"] = now
            last_seen["neutral"] = False
            diag.messages += 1
            if msg.get("type") == "ping":
                if last_ping is not None:
                    diag.ping_gap_max = max(diag.ping_gap_max, now - last_ping)
                last_ping = now
                sent = msg.get("t")
                if isinstance(sent, (int, float)):
                    up_window.append((now, (time.monotonic_ns() - sent) / 1e6))
                    while now - up_window[0][0] > 10.0:
                        up_window.popleft()
                    up = up_window[-1][1] - min(value for _, value in up_window)
                    diag.up_sum += up
                    diag.up_count += 1
                    diag.up_max = max(diag.up_max, up)
                started = time.perf_counter()
                await websocket.send(raw)
                diag.echo_max = max(diag.echo_max, time.perf_counter() - started)
                continue
            started = time.perf_counter()
            gamepad.handle_message(msg)
            diag.process_max = max(diag.process_max, time.perf_counter() - started)
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        stop_event.set()
        if watchdog_task:
            watchdog_task.cancel()
        gamepad.neutralize()
        gamepad.close()
        await pool.release(slot)
        log.info("iPhone déconnecté (%s), manette #%d libérée", peer, slot + 1)

def local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()

def network_address() -> "str | None":
    address = local_ip()
    return None if address.startswith("127.") else address

async def watch_network(known: "str | None", changed: asyncio.Event):
    candidate = None
    lost = False
    while True:
        await asyncio.sleep(NETWORK_POLL_SECONDS)
        current = network_address()
        if current is None:
            candidate = None
            if not lost:
                lost = True
                log.warning("Réseau perdu, en attente d'un nouveau réseau")
            continue
        lost = False
        if current == known:
            candidate = None
            continue
        if current != candidate:
            candidate = current
            continue
        log.info("Changement de réseau détecté (%s -> %s), le serveur se relance", known or "aucun", current)
        changed.set()
        return

async def start_mdns(port: int) -> "AsyncZeroconf | None":
    if not ZEROCONF_AVAILABLE:
        log.warning("zeroconf non installé, découverte auto désactivée (pip install zeroconf)")
        return None
    try:
        aiozc = AsyncZeroconf()
        ip = local_ip()
        hostname = socket.gethostname().split(".")[0]
        info = ServiceInfo(
            MDNS_SERVICE_TYPE,
            f"{hostname}.{MDNS_SERVICE_TYPE}",
            addresses=[socket.inet_aton(ip)],
            port=port,
            properties={"proto": str(PROTOCOL_VERSION)},
            server=f"{hostname}.local.",
        )
        await aiozc.async_register_service(info)
        log.info("Annonce mDNS active (%s, hôte %s.local.)", MDNS_SERVICE_TYPE, hostname)
        return aiozc
    except Exception as exc:
        log.warning("mDNS indisponible: %s: %r", type(exc).__name__, exc, exc_info=True)
        return None

def run_doctor(check_stream: bool = False) -> int:
    ok = True
    print("== gamepad doctor ==")

    if os.path.exists("/dev/uinput"):
        print("[OK] /dev/uinput existe")
        if os.access("/dev/uinput", os.R_OK | os.W_OK):
            print("[OK] /dev/uinput accessible en lecture/écriture")
        else:
            print("[FAIL] /dev/uinput non accessible (ajoute ton utilisateur au groupe uinput, ou vérifie udev)")
            ok = False
    else:
        print("[FAIL] /dev/uinput absent (module uinput non chargé, ou hardware.uinput.enable sur NixOS)")
        ok = False

    try:
        test_ui = UInput({e.EV_KEY: [e.BTN_SOUTH]}, name="gamepad-doctor-test")
        test_ui.close()
        print("[OK] création d'un device uinput de test réussie")
    except Exception as exc:
        print(f"[FAIL] impossible de créer un device uinput de test: {exc}")
        ok = False

    if ZEROCONF_AVAILABLE:
        print("[OK] zeroconf installé (découverte mDNS disponible)")
    else:
        print("[WARN] zeroconf non installé (pip install zeroconf) — découverte mDNS désactivée")

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1)
        result = s.connect_ex(("127.0.0.1", 8765))
        s.close()
        if result == 0:
            print("[INFO] un serveur écoute déjà sur le port 8765")
        else:
            print("[OK] port 8765 libre")
    except OSError as exc:
        print(f"[WARN] impossible de tester le port 8765: {exc}")

    ip = local_ip()
    print(f"[INFO] adresse IP locale détectée : {ip}")

    if check_stream:
        import screen_stream
        stream_ok, stream_lines = screen_stream.stream_report()
        for line in stream_lines:
            print(line)
        ok = ok and stream_ok

    print("== résultat:", "OK" if ok else "PROBLÈMES DÉTECTÉS", "==")
    return 0 if ok else 1

def render_qr(text: str) -> str:
    qr = qrcode.QRCode(border=4, error_correction=qrcode.constants.ERROR_CORRECT_M)
    qr.add_data(text)
    qr.make(fit=True)
    matrix = qr.get_matrix()
    if len(matrix) % 2:
        matrix = matrix + [[False] * len(matrix[0])]
    lines = []
    for top_row, bottom_row in zip(matrix[::2], matrix[1::2]):
        cells = []
        for top, bottom in zip(top_row, bottom_row):
            fg = 16 if top else 15
            bg = 16 if bottom else 15
            cells.append(f"\x1b[38;5;{fg};48;5;{bg}m\u2580")
        lines.append("".join(cells) + "\x1b[0m")
    return "\n".join(lines)

def print_pairing_qr(ip: str, port: int, stream_secret=None):
    url = f"gamepad://{ip}:{port}"
    if stream_secret:
        url += f"?s={stream_secret}"
    if not QRCODE_AVAILABLE:
        log.info("QR code d'appairage indisponible (module qrcode absent). Adresse : %s", url)
        return
    if not sys.stdout.isatty():
        if stream_secret:
            log.info("Adresse d'appairage du flux d'écran : %s", url)
        return
    print(render_qr(url))
    print(f"Scanne ce QR code depuis l'app ({url})", flush=True)

async def start_screen_stream(host, stream_port, encoder, diagnostics=False):
    import screen_stream
    stream = screen_stream.ScreenStream(os.environ.pop(SECRET_ENV, None) or screen_stream.generate_secret(), encoder, diagnostics)
    problem = stream.availability()
    if problem:
        log.warning("Flux d'écran désactivé : %s", problem)
        return None, None, None
    server = await stream.start(host, stream_port)
    info = {
        "streamPort": stream_port,
        "streamCodec": "h264",
        "streamProtocol": screen_stream.STREAM_PROTOCOL_VERSION,
    }
    log.info("Flux d'écran activé sur le port %d (scanne le QR code pour l'autoriser)", stream_port)
    return stream, server, info

async def main(host="0.0.0.0", port=8765, max_pads=4, diag_enabled=False,
               stream_enabled=False, stream_port=8766, stream_encoder="auto") -> "str | bool":
    raise_priority()
    power_interface = wifi_power_save_off()
    pool = GamepadPool(max_pads=max_pads)
    problem = uinput_problem()
    if problem:
        log.warning("Les manettes virtuelles ne pourront pas être créées : %s", problem)
    diag = DiagStats()
    diag_task = asyncio.create_task(diag_monitor(diag)) if diag_enabled else None
    aiozc = await start_mdns(port)
    stream = stream_server = stream_info = None
    if stream_enabled:
        stream, stream_server, stream_info = await start_screen_stream(host, stream_port, stream_encoder, diag_enabled)
    changed = asyncio.Event()
    watch_task = None
    try:
        async with websockets.serve(
            lambda ws: handler(ws, pool, diag, stream_info),
            host,
            port,
            compression=None,
            close_timeout=1,
        ):
            ip = local_ip()
            log.info("Serveur WebSocket sur %s:%d", ip, port)
            log.info("Jusqu'à %d manette(s) virtuelle(s) simultanée(s).", max_pads)
            print_pairing_qr(ip, port, stream.secret if stream else None)
            watch_task = asyncio.create_task(watch_network(network_address(), changed))
            await changed.wait()
    finally:
        if watch_task is not None:
            watch_task.cancel()
        if stream_server is not None:
            await stream.stop(stream_server)
        if diag_task is not None:
            diag_task.cancel()
        if aiozc is not None:
            await aiozc.async_close()
        wifi_power_save_restore(power_interface)
    return (stream.secret if stream else "") if changed.is_set() else False

def restart_process(secret: str):
    os.environ[RESTART_ENV] = "1"
    if secret:
        os.environ[SECRET_ENV] = secret
    sys.stdout.flush()
    os.execv(sys.executable, [sys.executable] + sys.argv)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Serveur de manette virtuelle")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--max-pads", type=int, default=4)
    parser.add_argument("--diag", action="store_true", help="écrit chaque seconde le retard de la boucle et les écarts de ping dans un fichier")
    parser.add_argument("--diag-file", default="gamepad-diag.log", help="fichier des diagnostics de --diag (réécrit à chaque lancement)")
    parser.add_argument("--stream", action="store_true", help="active le flux de l'écran du PC vers l'app (désactivé par défaut)")
    parser.add_argument("--stream-port", type=int, default=8766, help="port du flux vidéo")
    parser.add_argument("--stream-encoder", choices=("auto", "vaapi", "nvenc", "x264"), default="auto", help="encodeur H.264 du flux")
    parser.add_argument("doctor_cmd", nargs="?", default=None, help="passer 'doctor' pour diagnostiquer l'environnement (avec --stream pour tester aussi la capture d'écran)")
    args = parser.parse_args()

    if args.doctor_cmd == "doctor":
        sys.exit(run_doctor(check_stream=args.stream))

    if args.diag:
        log.info("Diagnostics écrits dans %s", route_diagnostics_to_file(args.diag_file))

    try:
        outcome = asyncio.run(main(
            host=args.host,
            port=args.port,
            max_pads=args.max_pads,
            diag_enabled=args.diag,
            stream_enabled=args.stream,
            stream_port=args.stream_port,
            stream_encoder=args.stream_encoder,
        ))
    except KeyboardInterrupt:
        log.info("Arrêt du serveur.")
    else:
        if outcome is not False:
            restart_process(outcome)
