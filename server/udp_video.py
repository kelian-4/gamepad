import asyncio
import collections
import secrets
import socket
import struct
import time
from typing import Callable

PAYLOAD_SIZE = 1200
PARITY_GROUP = 10
BATCH_SIZE = 20
BATCH_PAUSE_SECONDS = 0.001
RETRANSMIT_WINDOW_SECONDS = 0.5
MAX_RETRANSMIT_PER_REQUEST = 64
MAX_QUEUED_FRAMES = 900
SEND_BUFFER_BYTES = 1 << 20
TOKEN_SIZE = 8

TYPE_DATA = 0x01
TYPE_PARITY = 0x02
TYPE_ACK = 0x03
TYPE_HELLO = 0x10
TYPE_STATS = 0x11
TYPE_NACK = 0x12
TYPE_RESYNC = 0x13

DATA_HEADER = struct.Struct(">BIHHB")
PARITY_HEADER = struct.Struct(">BIHBH")
ACK_PACKET = struct.Struct(">B8sBI")
CONTROL_HEADER = struct.Struct(">B8sB")
STATS_BODY = struct.Struct(">HHHH")
NACK_BODY = struct.Struct(">IB")


def split_payload(payload: bytes) -> list:
    fragments = [payload[offset:offset + PAYLOAD_SIZE] for offset in range(0, len(payload), PAYLOAD_SIZE)]
    return fragments or [b""]


def xor_group(fragments: list) -> tuple:
    accumulator = 0
    length = 0
    for fragment in fragments:
        accumulator ^= int.from_bytes(fragment.ljust(PAYLOAD_SIZE, b"\0"), "big")
        length ^= len(fragment)
    return accumulator.to_bytes(PAYLOAD_SIZE, "big"), length


def packetize(frame_id: int, payload: bytes, key: bool) -> tuple:
    fragments = split_payload(payload)
    count = len(fragments)
    flags = 1 if key else 0
    data = [DATA_HEADER.pack(TYPE_DATA, frame_id, index, count, flags) + fragment for index, fragment in enumerate(fragments)]
    parity = []
    for start in range(0, count, PARITY_GROUP):
        group = fragments[start:start + PARITY_GROUP]
        body, length = xor_group(group)
        parity.append(PARITY_HEADER.pack(TYPE_PARITY, frame_id, start, len(group), length) + body)
    return data, parity


def new_token() -> bytes:
    return secrets.token_bytes(TOKEN_SIZE)


class UdpSession:
    def __init__(self, server: "UdpVideoServer", token: bytes, owner):
        self.server = server
        self.token = token
        self.owner = owner
        self.addr = None
        self.last_seen = 0.0
        self.next_fid = 1
        self.queue = collections.deque()
        self.sent = collections.deque()
        self.wake = asyncio.Event()
        self.waiting_key = True
        self.serials = {}
        self.task = None
        self.frames_sent = 0
        self.retransmitted = 0

    def start(self):
        if self.task is None:
            self.task = asyncio.create_task(self.run())

    def close(self):
        if self.task is not None:
            self.task.cancel()
            self.task = None

    @property
    def active(self) -> bool:
        return self.addr is not None

    def idle(self) -> bool:
        return not self.queue

    def enqueue(self, payload: bytes, key: bool):
        if self.waiting_key and not key:
            return
        if key:
            self.waiting_key = False
        if len(self.queue) >= MAX_QUEUED_FRAMES:
            self.queue.clear()
            self.waiting_key = not key
            if not key:
                return
        self.queue.append((self.next_fid, payload, key))
        self.next_fid = (self.next_fid + 1) & 0xFFFFFFFF
        self.wake.set()

    def resync(self, frames: list) -> int:
        self.queue.clear()
        self.waiting_key = True
        start = self.next_fid
        for payload, key in frames:
            self.enqueue(payload, key)
        return start

    def remember(self, frame_id: int, packets: list):
        now = time.monotonic()
        self.sent.append((now, frame_id, packets))
        while self.sent and now - self.sent[0][0] > RETRANSMIT_WINDOW_SECONDS:
            self.sent.popleft()

    def retransmit(self, frame_id: int, indexes: list):
        for _, known, packets in reversed(self.sent):
            if known == frame_id:
                for index in indexes[:MAX_RETRANSMIT_PER_REQUEST]:
                    if 0 <= index < len(packets):
                        self.server.send(packets[index], self.addr)
                        self.retransmitted += 1
                return

    async def run(self):
        try:
            while True:
                if not self.queue:
                    self.wake.clear()
                    await self.wake.wait()
                    continue
                frame_id, payload, key = self.queue.popleft()
                data, parity = packetize(frame_id, payload, key)
                self.remember(frame_id, data)
                self.frames_sent += 1
                self.owner_sent()
                packets = data + parity
                for offset in range(0, len(packets), BATCH_SIZE):
                    if self.addr is None:
                        break
                    for packet in packets[offset:offset + BATCH_SIZE]:
                        self.server.send(packet, self.addr)
                    if offset + BATCH_SIZE < len(packets):
                        await asyncio.sleep(BATCH_PAUSE_SECONDS)
        except asyncio.CancelledError:
            pass

    def owner_sent(self):
        callback = getattr(self.server, "on_frame_sent", None)
        if callback is not None:
            callback(self)


class UdpVideoServer(asyncio.DatagramProtocol):
    def __init__(self, snapshot: Callable[[], list], on_loss: Callable[[object], None], on_off: Callable[[object], None]):
        self.transport = None
        self.sessions = {}
        self.snapshot = snapshot
        self.on_loss = on_loss
        self.on_off = on_off
        self.on_frame_sent = None

    def connection_made(self, transport):
        self.transport = transport
        sock = transport.get_extra_info("socket")
        if sock is not None:
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, SEND_BUFFER_BYTES)
            except OSError:
                pass

    def register(self, owner) -> UdpSession:
        token = new_token()
        session = UdpSession(self, token, owner)
        self.sessions[token] = session
        return session

    def unregister(self, session: UdpSession):
        session.close()
        self.sessions.pop(session.token, None)

    def send(self, packet: bytes, addr):
        if self.transport is not None and not self.transport.is_closing():
            self.transport.sendto(packet, addr)

    def send_ack(self, session: UdpSession, serial: int, start: int):
        self.send(ACK_PACKET.pack(TYPE_ACK, session.token, serial, start), session.addr)

    def datagram_received(self, data: bytes, addr):
        if len(data) < CONTROL_HEADER.size:
            return
        kind, token, serial = CONTROL_HEADER.unpack_from(data)
        session = self.sessions.get(token)
        if session is None:
            return
        body = data[CONTROL_HEADER.size:]
        if kind == TYPE_HELLO or kind == TYPE_RESYNC:
            session.addr = addr
            session.last_seen = time.monotonic()
            known = session.serials.get(serial)
            if known is None:
                start = session.resync(self.snapshot())
                session.serials[serial] = start
                if len(session.serials) > 16:
                    session.serials.pop(next(iter(session.serials)))
                known = start
            self.send_ack(session, serial, known)
            session.start()
            return
        if session.addr != addr:
            return
        session.last_seen = time.monotonic()
        if kind == TYPE_NACK and len(body) >= NACK_BODY.size:
            frame_id, count = NACK_BODY.unpack_from(body)
            indexes = [struct.unpack_from(">H", body, NACK_BODY.size + 2 * position)[0] for position in range(min(count, (len(body) - NACK_BODY.size) // 2))]
            session.retransmit(frame_id, indexes)
        elif kind == TYPE_STATS and len(body) >= STATS_BODY.size:
            delivered, lost, recovered, requested = STATS_BODY.unpack_from(body)
            if lost:
                self.on_loss(session.owner)

    def check_liveness(self, now: float, timeout: float) -> list:
        silent = [session for session in self.sessions.values() if session.active and now - session.last_seen > timeout]
        for session in silent:
            session.addr = None
            session.queue.clear()
        return silent

    def close(self):
        for session in list(self.sessions.values()):
            session.close()
        self.sessions.clear()
        if self.transport is not None:
            self.transport.close()
