#!/usr/bin/env python3

import asyncio
import json
import logging
import os
import socket
import time

import websockets
from websockets.http11 import Response
from websockets.datastructures import Headers
from evdev import UInput, ecodes as e, AbsInfo

HTML_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gamepad_controller.html")

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

class VirtualGamepad:
    def __init__(self):
        self.ui = UInput(CAPABILITIES, name="iPhone Virtual Gamepad", version=0x1)
        log.info("Manette virtuelle créée : %s", self.ui.device.path)

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

    def close(self):
        self.ui.close()

def disable_nagle(websocket):
    try:
        sock = websocket.transport.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except Exception as exc:
        log.warning("TCP_NODELAY non appliqué: %s", exc)

QUEUE_WARN_THRESHOLD_MS = 50

async def handler(websocket, gamepad: VirtualGamepad):
    disable_nagle(websocket)
    peer = websocket.remote_address
    log.info("iPhone connecté depuis %s", peer)
    message_count = 0
    try:
        async for raw in websocket:
            receive_time = time.monotonic()
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                log.warning("JSON invalide: %r", raw)
                continue
            if msg.get("type") == "ping":
                await websocket.send(raw)
                continue
            gamepad.handle_message(msg)
            processed_time = time.monotonic()
            process_ms = (processed_time - receive_time) * 1000
            message_count += 1
            if message_count % 200 == 0 or process_ms > QUEUE_WARN_THRESHOLD_MS:
                log.info(
                    "perf: %d messages traités, dernier traitement %.2f ms (type=%s)",
                    message_count, process_ms, msg.get("type"),
                )
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        log.info("iPhone déconnecté (%s)", peer)

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

async def main(host="0.0.0.0", port=8765):
    gamepad = VirtualGamepad()
    try:
        async with websockets.serve(
            lambda ws: handler(ws, gamepad),
            host,
            port,
            process_request=process_request,
        ):
            log.info("Serveur sur http://%s:%d (page web + WebSocket sur le même port)", host, port)
            log.info("Un seul tunnel ngrok à faire pointer vers ce port.")
            await asyncio.Future()
    finally:
        gamepad.close()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("Arrêt du serveur.")
