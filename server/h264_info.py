from typing import Optional

HIGH_PROFILES = (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)
SLICE_KINDS = {0: "P", 1: "B", 2: "I", 3: "SP", 4: "SI"}


def unescape(data: bytes) -> bytes:
    out = bytearray()
    zeros = 0
    for byte in data:
        if zeros >= 2 and byte == 3:
            zeros = 0
            continue
        out.append(byte)
        zeros = zeros + 1 if byte == 0 else 0
    return bytes(out)


class BitReader:
    def __init__(self, data: bytes):
        self.data = data
        self.position = 0

    def bit(self) -> int:
        index, offset = divmod(self.position, 8)
        if index >= len(self.data):
            raise ValueError("fin des données")
        self.position += 1
        return (self.data[index] >> (7 - offset)) & 1

    def bits(self, count: int) -> int:
        value = 0
        for _ in range(count):
            value = (value << 1) | self.bit()
        return value

    def ue(self) -> int:
        zeros = 0
        while self.bit() == 0:
            zeros += 1
            if zeros > 32:
                raise ValueError("code invalide")
        return (1 << zeros) - 1 + self.bits(zeros)

    def se(self) -> int:
        value = self.ue()
        return (value + 1) // 2 if value % 2 else -(value // 2)


def skip_scaling_list(reader: BitReader, size: int):
    last = 8
    current = 8
    for _ in range(size):
        if current != 0:
            current = (last + reader.se() + 256) % 256
        if current != 0:
            last = current


def parse_sps(nal: bytes) -> Optional[dict]:
    try:
        reader = BitReader(unescape(nal[1:]))
        profile = reader.bits(8)
        reader.bits(8)
        level = reader.bits(8)
        reader.ue()
        chroma_format = 1
        if profile in HIGH_PROFILES:
            chroma_format = reader.ue()
            if chroma_format == 3:
                reader.bit()
            reader.ue()
            reader.ue()
            reader.bit()
            if reader.bit():
                for index in range(8 if chroma_format != 3 else 12):
                    if reader.bit():
                        skip_scaling_list(reader, 16 if index < 6 else 64)
        log2_frame_num = reader.ue() + 4
        poc_type = reader.ue()
        log2_poc_lsb = None
        if poc_type == 0:
            log2_poc_lsb = reader.ue() + 4
        elif poc_type == 1:
            reader.bit()
            reader.se()
            reader.se()
            for _ in range(reader.ue()):
                reader.se()
        refs = reader.ue()
        reader.bit()
        width = reader.ue() + 1
        height = reader.ue() + 1
        frame_mbs_only = reader.bit()
        return {
            "profile": profile,
            "level": level,
            "log2_frame_num": log2_frame_num,
            "poc_type": poc_type,
            "log2_poc_lsb": log2_poc_lsb,
            "refs": refs,
            "width_mbs": width,
            "height_mbs": height * (2 - frame_mbs_only),
            "frame_mbs_only": frame_mbs_only,
        }
    except ValueError:
        return None


def parse_pps(nal: bytes) -> Optional[dict]:
    try:
        reader = BitReader(unescape(nal[1:]))
        reader.ue()
        reader.ue()
        cabac = reader.bit()
        reader.bit()
        slice_groups = reader.ue() + 1
        default_refs = reader.ue() + 1
        reader.ue()
        weighted = reader.bit()
        return {"cabac": cabac, "slice_groups": slice_groups, "default_refs": default_refs, "weighted_pred": weighted}
    except ValueError:
        return None


def slice_kind(nal: bytes) -> Optional[str]:
    try:
        reader = BitReader(unescape(nal[1:9]))
        reader.ue()
        return SLICE_KINDS.get(reader.ue() % 5)
    except ValueError:
        return None


def describe(sps_nal: bytes, pps_nal: bytes) -> str:
    sps = parse_sps(sps_nal)
    pps = parse_pps(pps_nal)
    if sps is None or pps is None:
        return "flux H.264 : SPS ou PPS illisible"
    return (
        "flux H.264 : profil %d niveau %d | %dx%d macroblocs | poc type %d (bits %s) | images de référence max %d | "
        "codage %s | prédiction pondérée %s | groupes de tranches %d"
    ) % (
        sps["profile"],
        sps["level"],
        sps["width_mbs"],
        sps["height_mbs"],
        sps["poc_type"],
        sps["log2_poc_lsb"],
        sps["refs"],
        "CABAC" if pps["cabac"] else "CAVLC",
        "oui" if pps["weighted_pred"] else "non",
        pps["slice_groups"],
    )
