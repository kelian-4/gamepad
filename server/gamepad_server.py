#!/usr/bin/env python3

import argparse
import asyncio
import json
import logging
import os
import secrets
import socket
import sys

import websockets
from websockets.http11 import Response
from websockets.datastructures import Headers
from evdev import UInput, ecodes as e, AbsInfo

try:
    from zeroconf import ServiceInfo, Zeroconf
    ZEROCONF_AVAILABLE = True
except ImportError:
    ZEROCONF_AVAILABLE = False

HTML_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gamepad_controller.html")
TOKEN_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".pairing_token")
MDNS_SERVICE_TYPE = "_gamepad._tcp.local."
PROTOCOL_VERSION = 1

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("gamepad")

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

DEADMAN_TIMEOUT = 0.4

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

def load_or_create_token() -> str:
    try:
        with open(TOKEN_PATH, "r") as f:
            token = f.read().strip()
            if token:
                return token
    except FileNotFoundError:
        pass
    token = secrets.token_hex(16)
    try:
        with open(TOKEN_PATH, "w") as f:
            f.write(token)
        os.chmod(TOKEN_PATH, 0o600)
    except OSError as exc:
        log.warning("Impossible d'enregistrer le token (%s), il changera au prochain démarrage", exc)
    return token

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
            return slot, VirtualGamepad(index=slot)

    async def release(self, slot: int):
        async with self._lock:
            self._free_slots.append(slot)
            self._free_slots.sort()

def disable_nagle(websocket):
    try:
        sock = websocket.transport.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except Exception as exc:
        log.warning("TCP_NODELAY non appliqué: %s", exc)

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

async def handler(websocket, pool: GamepadPool, token: str):
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
        if hello.get("token") != token:
            log.warning("Token invalide depuis %s", peer)
            await websocket.send(json.dumps({"type": "hello_ack", "ok": False, "reason": "token invalide"}))
            return

        slot_and_pad = await pool.acquire()
        if slot_and_pad is None:
            await websocket.send(json.dumps({"type": "hello_ack", "ok": False, "reason": "nombre maximum de manettes atteint"}))
            return
        slot, gamepad = slot_and_pad

        await websocket.send(json.dumps({
            "type": "hello_ack",
            "ok": True,
            "protocolVersion": PROTOCOL_VERSION,
            "slot": slot,
            "features": ["deadman", "xbox360_id", "trigger_analog", "thumb_click"],
        }))
        log.info("iPhone %s apparié, manette virtuelle #%d", peer, slot + 1)

    except (asyncio.TimeoutError, json.JSONDecodeError, websockets.exceptions.ConnectionClosed):
        log.warning("Handshake échoué depuis %s", peer)
        return

    last_seen = {"t": asyncio.get_event_loop().time(), "neutral": False}
    watchdog_task = asyncio.create_task(deadman_watchdog(gamepad, last_seen, stop_event))
    try:
        async for raw in websocket:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                log.warning("JSON invalide: %r", raw)
                continue
            last_seen["t"] = asyncio.get_event_loop().time()
            last_seen["neutral"] = False
            if msg.get("type") == "ping":
                await websocket.send(raw)
                continue
            gamepad.handle_message(msg)
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

async def process_request(connection, request):
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return None

    if request.path in ("/", "/gamepad_controller.html"):
        try:
            with open(HTML_PATH, "rb") as f:
                body = f.read()
        except FileNotFoundError:
            return Response(404, "Not Found", Headers(), b"gamepad_controller.html introuvable")
        return Response(200, "OK", Headers([("Content-Type", "text/html; charset=utf-8")]), body)

    return Response(404, "Not Found", Headers(), b"Not Found")

def local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()

def start_mdns(port: int) -> "Zeroconf | None":
    if not ZEROCONF_AVAILABLE:
        log.warning("zeroconf non installé, découverte auto désactivée (pip install zeroconf)")
        return None
    try:
        zc = Zeroconf()
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
        zc.register_service(info)
        log.info("Annonce mDNS active (%s, hôte %s.local.)", MDNS_SERVICE_TYPE, hostname)
        return zc
    except Exception as exc:
        log.warning("mDNS indisponible: %s", exc)
        return None

def run_doctor() -> int:
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
    print(f"[INFO] token d'appairage : {TOKEN_PATH} ({'existe' if os.path.exists(TOKEN_PATH) else 'sera généré au démarrage'})")

    print("== résultat:", "OK" if ok else "PROBLÈMES DÉTECTÉS", "==")
    return 0 if ok else 1

async def main(host="0.0.0.0", port=8765, max_pads=4):
    token = load_or_create_token()
    pool = GamepadPool(max_pads=max_pads)
    zc = start_mdns(port)
    try:
        async with websockets.serve(
            lambda ws: handler(ws, pool, token),
            host,
            port,
            process_request=process_request,
        ):
            ip = local_ip()
            log.info("Serveur sur http://%s:%d (page web + WebSocket sur le même port)", ip, port)
            log.info("Token d'appairage : %s (voir %s)", token, TOKEN_PATH)
            log.info("Jusqu'à %d manette(s) virtuelle(s) simultanée(s).", max_pads)
            await asyncio.Future()
    finally:
        if zc is not None:
            zc.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Serveur de manette virtuelle")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--max-pads", type=int, default=4)
    parser.add_argument("doctor_cmd", nargs="?", default=None, help="passer 'doctor' pour diagnostiquer l'environnement")
    args = parser.parse_args()

    if args.doctor_cmd == "doctor":
        sys.exit(run_doctor())

    try:
        asyncio.run(main(host=args.host, port=args.port, max_pads=args.max_pads))
    except KeyboardInterrupt:
        log.info("Arrêt du serveur.")
