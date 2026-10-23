import threading
from typing import Optional

import h264_info

RANGE_LPS = (
    (128, 176, 208, 240), (128, 167, 197, 227), (128, 158, 187, 216), (123, 150, 178, 205),
    (116, 142, 169, 195), (111, 135, 160, 185), (105, 128, 152, 175), (100, 122, 144, 166),
    (95, 116, 137, 158), (90, 110, 130, 150), (85, 104, 123, 142), (81, 99, 117, 135),
    (77, 94, 111, 128), (73, 89, 105, 122), (69, 85, 100, 116), (66, 80, 95, 110),
    (62, 76, 90, 104), (59, 72, 86, 99), (56, 69, 81, 94), (53, 65, 77, 89),
    (51, 62, 73, 85), (48, 59, 69, 80), (46, 56, 66, 76), (43, 53, 63, 72),
    (41, 50, 59, 69), (39, 48, 56, 65), (37, 45, 54, 62), (35, 43, 51, 59),
    (33, 41, 48, 56), (32, 39, 46, 53), (30, 37, 43, 50), (29, 35, 41, 48),
    (27, 33, 39, 45), (26, 31, 37, 43), (24, 30, 35, 41), (23, 28, 33, 39),
    (22, 27, 32, 37), (21, 26, 30, 35), (20, 24, 29, 33), (19, 23, 27, 31),
    (18, 22, 26, 30), (17, 21, 25, 28), (16, 20, 23, 27), (15, 19, 22, 25),
    (14, 18, 21, 24), (14, 17, 20, 23), (13, 16, 19, 22), (12, 15, 18, 21),
    (12, 14, 17, 20), (11, 14, 16, 19), (11, 13, 15, 18), (10, 12, 15, 17),
    (10, 12, 14, 16), (9, 11, 13, 15), (9, 11, 12, 14), (8, 10, 12, 14),
    (8, 9, 11, 13), (7, 9, 11, 12), (7, 9, 10, 12), (7, 8, 10, 11),
    (6, 8, 9, 11), (6, 7, 9, 10), (6, 7, 8, 9), (2, 2, 2, 2),
)
TRANS_LPS = (
    0, 0, 1, 2, 2, 4, 4, 5, 6, 7, 8, 9, 9, 11, 11, 12,
    13, 13, 15, 15, 16, 16, 18, 18, 19, 19, 21, 21, 22, 22, 23, 24,
    24, 25, 26, 26, 27, 27, 28, 29, 29, 30, 30, 30, 31, 32, 32, 33,
    33, 33, 34, 34, 35, 35, 35, 36, 36, 36, 37, 37, 37, 38, 38, 63,
)
SKIP_CONTEXT_M = 23
SKIP_CONTEXT_N = 33

payload_cache = {}


def escape(data: bytes) -> bytes:
    out = bytearray()
    zeros = 0
    for byte in data:
        if zeros >= 2 and byte <= 3:
            out.append(3)
            zeros = 0
        out.append(byte)
        zeros = zeros + 1 if byte == 0 else 0
    return bytes(out)


class BitWriter:
    def __init__(self):
        self.bits = []

    def put(self, value: int, count: int):
        for shift in range(count - 1, -1, -1):
            self.bits.append((value >> shift) & 1)

    def ue(self, value: int):
        coded = value + 1
        length = coded.bit_length()
        self.put(0, length - 1)
        self.put(coded, length)

    def se(self, value: int):
        self.ue(2 * value - 1 if value > 0 else -2 * value)

    def pad(self, bit: int):
        while len(self.bits) % 8:
            self.bits.append(bit)

    def to_bytes(self) -> bytes:
        self.pad(0)
        out = bytearray()
        for index in range(0, len(self.bits), 8):
            value = 0
            for bit in self.bits[index:index + 8]:
                value = (value << 1) | bit
            out.append(value)
        return bytes(out)


class CabacEncoder:
    def __init__(self, qp: int):
        self.low = 0
        self.range = 510
        self.first = True
        self.outstanding = 0
        self.bits = []
        pre = max(1, min(126, ((SKIP_CONTEXT_M * max(0, min(51, qp))) >> 4) + SKIP_CONTEXT_N))
        if pre <= 63:
            self.state = 63 - pre
            self.mps = 0
        else:
            self.state = pre - 64
            self.mps = 1

    def put_bit(self, bit: int):
        if self.first:
            self.first = False
        else:
            self.bits.append(bit)
        while self.outstanding > 0:
            self.bits.append(1 - bit)
            self.outstanding -= 1

    def renorm(self):
        while self.range < 256:
            if self.low < 256:
                self.put_bit(0)
            elif self.low >= 512:
                self.low -= 512
                self.put_bit(1)
            else:
                self.low -= 256
                self.outstanding += 1
            self.range <<= 1
            self.low <<= 1

    def decision(self, bit: int):
        lps = RANGE_LPS[self.state][(self.range >> 6) & 3]
        self.range -= lps
        if bit != self.mps:
            self.low += self.range
            self.range = lps
            if self.state == 0:
                self.mps = 1 - self.mps
            self.state = TRANS_LPS[self.state]
        else:
            self.state = min(self.state + 1, 62)
        self.renorm()

    def terminate(self, bit: int):
        self.range -= 2
        if bit:
            self.low += self.range
            self.range = 2
            self.renorm()
            self.put_bit((self.low >> 9) & 1)
            tail = ((self.low >> 7) & 3) | 1
            self.bits.append((tail >> 1) & 1)
            self.bits.append(tail & 1)
        else:
            self.renorm()


def build_cabac_payload(mb_count: int, qp: int) -> bytes:
    encoder = CabacEncoder(qp)
    for index in range(mb_count):
        encoder.decision(1)
        encoder.terminate(1 if index == mb_count - 1 else 0)
    writer = BitWriter()
    writer.bits = encoder.bits
    return writer.to_bytes()


def build_payload(config: dict) -> bytes:
    key = (config["cabac"], config["mb_count"], config["init_qp"])
    cached = payload_cache.get(key)
    if cached is not None:
        return cached
    if config["cabac"]:
        payload = build_cabac_payload(config["mb_count"], config["init_qp"])
    else:
        writer = BitWriter()
        writer.ue(config["mb_count"])
        writer.put(1, 1)
        payload = writer.to_bytes()
    payload_cache[key] = payload
    return payload


def build_skip_nal(config: dict, payload: bytes, frame_num: int, pps_id: int, ref_idc: int) -> bytes:
    writer = BitWriter()
    writer.ue(0)
    writer.ue(0)
    writer.ue(pps_id)
    writer.put(frame_num, config["log2_frame_num"])
    if config["redundant_pic_cnt"]:
        writer.ue(0)
    writer.put(1, 1)
    writer.ue(0)
    writer.put(0, 1)
    if ref_idc:
        writer.put(0, 1)
    if config["cabac"]:
        writer.ue(0)
    writer.se(0)
    if config["deblocking_control"]:
        writer.ue(1)
    if config["cabac"]:
        writer.pad(1)
        body = writer.to_bytes() + payload
    else:
        writer.bits.extend(bit for byte in payload for bit in ((byte >> shift) & 1 for shift in range(7, -1, -1)))
        body = writer.to_bytes()
    return bytes([(ref_idc << 5) | 1]) + escape(body)


def unsupported_reason(sps: Optional[dict], pps: Optional[dict]) -> Optional[str]:
    if sps is None or pps is None:
        return "SPS ou PPS illisible"
    if not sps["frame_mbs_only"]:
        return "flux entrelacé"
    if sps["poc_type"] != 2:
        return "type de POC %d non géré" % sps["poc_type"]
    if sps["refs"] != 1:
        return "%d images de référence" % sps["refs"]
    if pps["slice_groups"] != 1:
        return "groupes de tranches"
    if pps["weighted_pred"]:
        return "prédiction pondérée"
    return None


class FrameRepeater:
    def __init__(self):
        self.key = None
        self.config = None
        self.payload = None
        self.reason = None
        self.inserted = 0
        self.last_ref = 0
        self.pps_id = 0
        self.ref_idc = 1
        self.token = None

    @property
    def ready(self) -> bool:
        return self.config is not None and self.payload is not None

    def configure(self, sps_nal: bytes, pps_nal: bytes):
        if self.key == (sps_nal, pps_nal):
            return
        self.key = (sps_nal, pps_nal)
        self.config = None
        self.payload = None
        sps = h264_info.parse_sps(sps_nal)
        pps = h264_info.parse_pps(pps_nal)
        self.reason = unsupported_reason(sps, pps)
        if self.reason is not None:
            return
        config = {
            "cabac": pps["cabac"],
            "log2_frame_num": sps["log2_frame_num"],
            "mb_count": sps["width_mbs"] * sps["height_mbs"],
            "init_qp": pps["init_qp"],
            "deblocking_control": pps["deblocking_control"],
            "redundant_pic_cnt": pps["redundant_pic_cnt"],
        }
        self.config = config
        token = object()
        self.token = token

        def work():
            payload = build_payload(config)
            if self.token is token:
                self.payload = payload

        threading.Thread(target=work, daemon=True).start()

    def patch(self, nal: bytes) -> bytes:
        kind = nal[0] & 0x1F
        ref_idc = (nal[0] >> 5) & 3
        rbsp = bytearray(h264_info.unescape(nal[1:]))
        reader = h264_info.BitReader(rbsp)
        reader.ue()
        reader.ue()
        pps_id = reader.ue()
        position = reader.position
        width = self.config["log2_frame_num"]
        frame_num = reader.bits(width)
        self.pps_id = pps_id
        if kind == 5:
            self.inserted = 0
            self.last_ref = frame_num
            self.ref_idc = ref_idc or 1
            return nal
        wanted = (frame_num + self.inserted) % (1 << width)
        if ref_idc:
            self.last_ref = wanted
            self.ref_idc = ref_idc
        if wanted == frame_num:
            return nal
        for index in range(width):
            bit = (wanted >> (width - 1 - index)) & 1
            byte, offset = divmod(position + index, 8)
            mask = 0x80 >> offset
            rbsp[byte] = (rbsp[byte] | mask) if bit else (rbsp[byte] & ~mask & 0xFF)
        return bytes([nal[0]]) + escape(bytes(rbsp))

    def process(self, key: bool, sps: Optional[bytes], pps: Optional[bytes], nals: list) -> list:
        if key and sps and pps:
            self.configure(sps, pps)
        if self.config is None:
            return nals
        try:
            return [self.patch(nal) for nal in nals]
        except ValueError:
            self.config = None
            self.reason = "en-tête de tranche illisible"
            return nals

    def make_skip_nal(self) -> Optional[bytes]:
        if not self.ready:
            return None
        frame_num = (self.last_ref + 1) % (1 << self.config["log2_frame_num"])
        nal = build_skip_nal(self.config, self.payload, frame_num, self.pps_id, self.ref_idc)
        self.inserted += 1
        self.last_ref = frame_num
        return nal
