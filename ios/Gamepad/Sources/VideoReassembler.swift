import Foundation

final class VideoReassembler {
    private static let payloadSize = 1200
    private static let parityGroup = 10
    private static let maxFragments = 4096
    private static let giveUp: Double = 0.15
    private static let nackDelay: Double = 0.012
    private static let nackRepeat: Double = 0.03
    private static let maxNacks = 4
    private static let helloRepeat: Double = 0.1
    private static let statsEvery: Double = 0.25
    private static let dataHeader = 10
    private static let parityHeader = 10
    private static let ackSize = 14

    private static let typeData: UInt8 = 0x01
    private static let typeParity: UInt8 = 0x02
    private static let typeAck: UInt8 = 0x03
    private static let typeHello: UInt8 = 0x10
    private static let typeStats: UInt8 = 0x11
    private static let typeNack: UInt8 = 0x12
    private static let typeResync: UInt8 = 0x13

    private struct Parity {
        let length: Int
        let xorLength: Int
        let body: [UInt8]
    }

    private final class FrameState {
        var count: Int
        var key: Bool
        let firstSeen: Double
        var fragments: [[UInt8]?]
        var parity: [Int: Parity] = [:]
        var lastNack: Double = 0
        var nacks = 0

        init(count: Int, key: Bool, now: Double) {
            self.count = count
            self.key = key
            self.firstSeen = now
            self.fragments = Array(repeating: nil, count: count)
        }

        func setCount(_ newCount: Int, key newKey: Bool) {
            count = newCount
            key = newKey
            fragments = Array(repeating: nil, count: newCount)
        }

        func isComplete() -> Bool {
            if count == 0 { return false }
            for fragment in fragments where fragment == nil { return false }
            return true
        }

        func recover() -> Int {
            var recovered = 0
            for (start, entry) in parity {
                let end = min(start + entry.length, count)
                if start >= end { continue }
                var missing: [Int] = []
                for index in start..<end where fragments[index] == nil {
                    missing.append(index)
                }
                if missing.count != 1 { continue }
                var accumulator = entry.body
                var size = entry.xorLength
                for index in start..<end {
                    if let fragment = fragments[index] {
                        for position in 0..<fragment.count {
                            accumulator[position] ^= fragment[position]
                        }
                        size ^= fragment.count
                    }
                }
                if size >= 0 && size <= VideoReassembler.payloadSize {
                    fragments[missing[0]] = Array(accumulator[0..<size])
                    recovered += 1
                }
            }
            return recovered
        }

        func unrecoverableMissing() -> [Int] {
            var result: [Int] = []
            var start = 0
            while start < count {
                let end = min(start + VideoReassembler.parityGroup, count)
                var group: [Int] = []
                for index in start..<end where fragments[index] == nil {
                    group.append(index)
                }
                if group.count == 1 && parity[start] != nil {
                    start = end
                    continue
                }
                result.append(contentsOf: group)
                start = end
            }
            return result
        }
    }

    private let token: [UInt8]
    private var frames: [UInt32: FrameState] = [:]
    private var nextFrameId: UInt32?
    private var serial: UInt8 = 0
    private var lastHello: Double?
    private var lastStats: Double = 0
    private var deliveredCount = 0
    private var lostCount = 0
    private var recoveredCount = 0
    private var nackRequests = 0

    init(token: [UInt8]) {
        self.token = token
    }

    var isActive: Bool {
        return nextFrameId != nil
    }

    private func control(_ kind: UInt8, _ serialValue: UInt8, _ body: [UInt8] = []) -> [UInt8] {
        return [kind] + token + [serialValue] + body
    }

    private func u16(_ data: [UInt8], _ offset: Int) -> Int {
        return Int(data[offset]) << 8 | Int(data[offset + 1])
    }

    private func u32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private func ahead(_ a: UInt32, _ b: UInt32) -> Bool {
        return (a &- b) < 0x8000_0000
    }

    func ingest(_ data: [UInt8], now: Double) {
        guard let kind = data.first else { return }
        if kind == Self.typeAck {
            guard data.count >= Self.ackSize else { return }
            let received = Array(data[1..<9])
            guard received == token, data[9] == serial, nextFrameId == nil else { return }
            nextFrameId = u32(data, 10)
            frames.removeAll()
            return
        }
        guard let expected = nextFrameId else { return }
        if kind == Self.typeData {
            guard data.count >= Self.dataHeader else { return }
            let frameId = u32(data, 1)
            let index = u16(data, 5)
            let count = u16(data, 7)
            let key = data[9] & 1 == 1
            guard ahead(frameId, expected), count > 0, count <= Self.maxFragments, index < count else { return }
            var frame = frames[frameId]
            if frame == nil {
                frame = FrameState(count: count, key: key, now: now)
                frames[frameId] = frame
            } else if frame!.count == 0 {
                frame!.setCount(count, key: key)
            }
            guard let state = frame, state.count == count, state.fragments[index] == nil else { return }
            state.fragments[index] = Array(data[Self.dataHeader...])
        } else if kind == Self.typeParity {
            guard data.count >= Self.parityHeader + Self.payloadSize else { return }
            let frameId = u32(data, 1)
            guard ahead(frameId, expected) else { return }
            let start = u16(data, 5)
            let length = Int(data[7])
            let xorLength = u16(data, 8)
            var frame = frames[frameId]
            if frame == nil {
                frame = FrameState(count: 0, key: false, now: now)
                frames[frameId] = frame
            }
            frame!.parity[start] = Parity(length: length, xorLength: xorLength, body: Array(data[Self.parityHeader..<(Self.parityHeader + Self.payloadSize)]))
        }
    }

    func popReady() -> [[UInt8]] {
        var output: [[UInt8]] = []
        while let expected = nextFrameId, let frame = frames[expected], frame.count > 0 {
            let before = frame.fragments.reduce(0) { $0 + ($1 == nil ? 1 : 0) }
            let recovered = frame.recover()
            if before > 0 { recoveredCount += recovered }
            if !frame.isComplete() { break }
            var payload: [UInt8] = []
            for fragment in frame.fragments {
                if let fragment { payload.append(contentsOf: fragment) }
            }
            output.append(payload)
            frames.removeValue(forKey: expected)
            nextFrameId = expected &+ 1
            deliveredCount += 1
        }
        return output
    }

    func start(now: Double) -> [UInt8] {
        lastHello = now
        return control(Self.typeHello, serial)
    }

    func tick(now: Double) -> [[UInt8]] {
        var outgoing: [[UInt8]] = []
        guard let expected = nextFrameId else {
            if lastHello == nil || now - (lastHello ?? 0) >= Self.helloRepeat {
                lastHello = now
                outgoing.append(control(serial == 0 ? Self.typeHello : Self.typeResync, serial))
            }
            return outgoing
        }
        var stalledSince: Double?
        if let frame = frames[expected], frame.count > 0 {
            stalledSince = frame.firstSeen
        } else {
            var oldest: Double?
            for (frameId, frame) in frames where frameId != expected && ahead(frameId, expected) {
                if oldest == nil || frame.firstSeen < oldest! { oldest = frame.firstSeen }
            }
            stalledSince = oldest
        }
        if let stalledSince, now - stalledSince > Self.giveUp {
            lostCount += 1
            frames.removeAll()
            nextFrameId = nil
            serial = serial &+ 1
            if serial == 0 { serial = 1 }
            lastHello = now
            outgoing.append(control(Self.typeResync, serial))
            return outgoing
        }
        for (frameId, frame) in frames {
            if frame.count == 0 || frame.isComplete() { continue }
            if now - frame.firstSeen > Self.nackDelay && now - frame.lastNack > Self.nackRepeat && frame.nacks < Self.maxNacks {
                let missing = frame.unrecoverableMissing()
                if missing.isEmpty { continue }
                frame.lastNack = now
                frame.nacks += 1
                nackRequests += 1
                let listed = Array(missing.prefix(255))
                var body: [UInt8] = [
                    UInt8(frameId >> 24 & 0xFF), UInt8(frameId >> 16 & 0xFF), UInt8(frameId >> 8 & 0xFF), UInt8(frameId & 0xFF),
                    UInt8(listed.count),
                ]
                for index in listed {
                    body.append(UInt8(index >> 8 & 0xFF))
                    body.append(UInt8(index & 0xFF))
                }
                outgoing.append(control(Self.typeNack, 0, body))
            }
        }
        if now - lastStats >= Self.statsEvery {
            lastStats = now
            let values = [deliveredCount, lostCount, recoveredCount, nackRequests].map { min($0, 65535) }
            var body: [UInt8] = []
            for value in values {
                body.append(UInt8(value >> 8 & 0xFF))
                body.append(UInt8(value & 0xFF))
            }
            outgoing.append(control(Self.typeStats, 0, body))
            deliveredCount = 0
            lostCount = 0
            recoveredCount = 0
            nackRequests = 0
        }
        return outgoing
    }
}
