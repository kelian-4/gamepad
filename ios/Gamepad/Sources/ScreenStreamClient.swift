import AVFoundation
import CoreMedia
import Foundation
import Network
import SwiftUI
import UIKit

enum ScreenStreamState: Equatable {
    case off
    case waiting
    case active
    case unavailable(String)
}

struct StreamEndpoint: Equatable {
    let host: String
    let port: UInt16
}

final class ScreenStreamClient: ObservableObject {
    @Published private(set) var state: ScreenStreamState = .off

    let displayLayer = AVSampleBufferDisplayLayer()

    private let queue = DispatchQueue(label: "com.kelian.gamepad.stream")
    private var connection: NWConnection?
    private var target: (endpoint: StreamEndpoint, secret: String, quality: String)?
    private var currentState: ScreenStreamState = .off
    private var retryWork: DispatchWorkItem?
    private var generation = 0
    private var lastFrameAt: UInt64 = 0
    private var format: CMVideoFormatDescription?
    private var currentSPS: [UInt8] = []
    private var currentPPS: [UInt8] = []

    private static let retryDelay: Double = 3
    private static let stallSeconds: UInt64 = 3
    private static let watchdogInterval: Double = 1

    init() {
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    func start(endpoint: StreamEndpoint, secret: String?, quality: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let secret, !secret.isEmpty else {
                self.target = nil
                self.teardown()
                self.setState(.unavailable("Scanne le QR code du serveur pour autoriser le flux"))
                return
            }
            if let current = self.target, current.endpoint == endpoint, current.secret == secret, self.connection != nil {
                if current.quality != quality {
                    self.target = (endpoint, secret, quality)
                    self.sendJSON(["type": "quality", "quality": quality])
                }
                return
            }
            self.target = (endpoint, secret, quality)
            self.openConnection()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.target = nil
            self.teardown()
            self.setState(.off)
            DispatchQueue.main.async { self.displayLayer.flushAndRemoveImage() }
        }
    }

    private func setState(_ newState: ScreenStreamState) {
        guard newState != currentState else { return }
        currentState = newState
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
        }
    }

    private func teardown() {
        generation += 1
        retryWork?.cancel()
        retryWork = nil
        if let old = connection {
            connection = nil
            old.stateUpdateHandler = nil
            old.cancel()
        }
        format = nil
        currentSPS = []
        currentPPS = []
    }

    private func openConnection() {
        teardown()
        guard let target else { return }
        guard let url = URL(string: "ws://\(target.endpoint.host):\(target.endpoint.port)/") else {
            setState(.unavailable("Adresse du flux invalide"))
            return
        }
        setState(.waiting)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let conn = NWConnection(to: .url(url), using: params)
        connection = conn
        let token = generation

        conn.stateUpdateHandler = { [weak self, weak conn] newState in
            self?.queue.async {
                guard let self, let conn, self.connection === conn, self.generation == token else { return }
                switch newState {
                case .ready:
                    self.sendJSON(["type": "stream_hello", "secret": target.secret, "quality": target.quality])
                    self.scheduleWatchdog(token: token)
                case .failed:
                    self.fail("Flux interrompu", retry: true)
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
        receiveLoop(on: conn, token: token)
    }

    private func fail(_ message: String, retry: Bool) {
        teardown()
        setState(.unavailable(message))
        guard retry, target != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.target != nil else { return }
            self.openConnection()
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + Self.retryDelay, execute: work)
    }

    private func scheduleWatchdog(token: Int) {
        queue.asyncAfter(deadline: .now() + Self.watchdogInterval) { [weak self] in
            guard let self, self.generation == token, self.connection != nil else { return }
            if self.currentState == .active {
                let now = DispatchTime.now().uptimeNanoseconds
                if now > self.lastFrameAt + Self.stallSeconds * 1_000_000_000 {
                    self.setState(.waiting)
                }
            }
            self.scheduleWatchdog(token: token)
        }
    }

    private func receiveLoop(on conn: NWConnection, token: Int) {
        conn.receiveMessage { [weak self, weak conn] data, context, _, error in
            guard let self, let conn, self.connection === conn, self.generation == token else { return }
            if error != nil {
                self.fail("Flux interrompu", retry: true)
                return
            }
            if let data, !data.isEmpty {
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .text {
                    self.handleText(data)
                } else {
                    self.handleVideo([UInt8](data))
                }
            }
            self.receiveLoop(on: conn, token: token)
        }
    }

    private func sendJSON(_ object: [String: String]) {
        guard let conn = connection, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "streamMessage", metadata: [metadata])
        conn.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func handleText(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "stream_ack":
            if (obj["ok"] as? Bool) == true {
                setState(.waiting)
            } else {
                let reason = (obj["reason"] as? String) ?? "flux refusé"
                fail(reason, retry: false)
            }
        case "stream_status":
            let serverState = (obj["state"] as? String) ?? ""
            switch serverState {
            case "unavailable":
                let reason = (obj["reason"] as? String) ?? "capture indisponible sur le PC"
                setState(.unavailable(reason))
            case "waiting", "idle":
                if currentState != .active { setState(.waiting) }
            default:
                break
            }
        default:
            break
        }
    }

    private func readBlock(_ bytes: [UInt8], _ offset: inout Int) -> [UInt8]? {
        guard offset + 2 <= bytes.count else { return nil }
        let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        offset += 2
        guard offset + length <= bytes.count else { return nil }
        let block = Array(bytes[offset..<offset + length])
        offset += length
        return block
    }

    private func handleVideo(_ bytes: [UInt8]) {
        guard let flags = bytes.first else { return }
        var offset = 1
        if flags & 0x02 != 0 {
            guard let sps = readBlock(bytes, &offset), let pps = readBlock(bytes, &offset) else { return }
            if sps != currentSPS || pps != currentPPS || format == nil {
                format = Self.makeFormat(sps: sps, pps: pps)
                currentSPS = sps
                currentPPS = pps
            }
        }
        guard let format, offset < bytes.count else { return }
        let isKey = flags & 0x01 != 0
        guard let sample = Self.makeSampleBuffer(payload: Array(bytes[offset...]), format: format, isKey: isKey) else { return }
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        guard displayLayer.isReadyForMoreMediaData else { return }
        displayLayer.enqueue(sample)
        lastFrameAt = DispatchTime.now().uptimeNanoseconds
        setState(.active)
    }

    private static func makeFormat(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsBuffer in
            pps.withUnsafeBufferPointer { ppsBuffer -> OSStatus in
                guard let spsBase = spsBuffer.baseAddress, let ppsBase = ppsBuffer.baseAddress else { return -1 }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        return status == noErr ? description : nil
    }

    private static func makeSampleBuffer(payload: [UInt8], format: CMVideoFormatDescription, isKey: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let length = payload.count
        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &block
        )
        guard created == kCMBlockBufferNoErr, let block else { return nil }
        let copied = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: CMTime.invalid
        )
        var sampleSize = length
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !isKey {
                CFDictionarySetValue(
                    dictionary,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }
        return sample
    }
}

final class StreamHostView: UIView {
    private let streamLayer: AVSampleBufferDisplayLayer

    init(streamLayer: AVSampleBufferDisplayLayer) {
        self.streamLayer = streamLayer
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .black
        layer.addSublayer(streamLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) n'est pas pris en charge")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        streamLayer.frame = bounds
        CATransaction.commit()
    }
}

struct ScreenStreamView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> StreamHostView {
        StreamHostView(streamLayer: displayLayer)
    }

    func updateUIView(_ uiView: StreamHostView, context: Context) {}
}
