import Foundation
import VideoToolbox
import CoreMedia
import QuartzCore
import simd

final class DecodedFrame {
    let pixelBuffer: CVPixelBuffer
    let header: VideoFrameHeader
    let arrival = CACurrentMediaTime()
    init(pixelBuffer: CVPixelBuffer, header: VideoFrameHeader) {
        self.pixelBuffer = pixelBuffer
        self.header = header
    }
}

/// Decodes Annex-B H.264 / HEVC access units (one per message) with VideoToolbox.
final class VideoDecoder {
    enum Codec { case h264, hevc }

    private(set) var codec: Codec = .h264
    var onFrame: ((DecodedFrame) -> Void)?
    var onError: (() -> Void)?

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var vps: Data?, sps: Data?, pps: Data?
    private var lastErrorTime = 0.0

    func setCodec(_ c: Codec) {
        if c != codec { codec = c; reset() }
    }

    func reset() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil; format = nil; vps = nil; sps = nil; pps = nil
    }

    func decode(annexB: Data, header: VideoFrameHeader) {
        var vcl: [Data] = []
        var changed = false
        for nal in splitAnnexB(annexB) {
            guard let first = nal.first else { continue }
            switch codec {
            case .h264:
                switch first & 0x1F {
                case 7: if sps != nal { sps = nal; changed = true }
                case 8: if pps != nal { pps = nal; changed = true }
                case 1, 5: vcl.append(nal)
                default: break
                }
            case .hevc:
                let t = (first >> 1) & 0x3F
                switch t {
                case 32: if vps != nal { vps = nal; changed = true }
                case 33: if sps != nal { sps = nal; changed = true }
                case 34: if pps != nal { pps = nal; changed = true }
                case 0..<32: vcl.append(nal)
                default: break
                }
            }
        }

        if changed || (format == nil && session == nil) {
            rebuildFormat()
        }
        guard let session = session, let format = format, !vcl.isEmpty else { return }

        var avcc = Data()
        for n in vcl {
            var len = UInt32(n.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(n)
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
                                                 blockLength: avcc.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: 0,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let bb = block else { return }
        let rep = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard rep == kCMBlockBufferNoErr else { return }

        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr,
              let sb = sample else { return }

        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb,
                                                   flags: [._EnableAsynchronousDecompression],
                                                   infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard let self = self else { return }
            if status != noErr || image == nil { self.reportError(); return }
            self.onFrame?(DecodedFrame(pixelBuffer: image!, header: header))
        }
        if st != noErr { reportError() }
    }

    private func reportError() {
        let now = CACurrentMediaTime()
        if now - lastErrorTime > 0.5 { lastErrorTime = now; onError?() }
    }

    private func rebuildFormat() {
        let sets: [Data]
        switch codec {
        case .h264:
            guard let sps = sps, let pps = pps else { return }
            sets = [sps, pps]
        case .hevc:
            guard let vps = vps, let sps = sps, let pps = pps else { return }
            sets = [vps, sps, pps]
        }

        var ptrs: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var allocs: [UnsafeMutablePointer<UInt8>] = []
        defer { allocs.forEach { $0.deallocate() } }
        for s in sets {
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count)
            s.copyBytes(to: p, count: s.count)
            allocs.append(p); ptrs.append(UnsafePointer(p)); sizes.append(s.count)
        }

        var fmt: CMVideoFormatDescription?
        let st: OSStatus
        if codec == .hevc {
            st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: ptrs,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                formatDescriptionOut: &fmt)
        } else {
            st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: ptrs,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        }
        guard st == noErr, let f = fmt else { print("format error \(st)"); return }
        format = f
        makeSession(f)
    }

    private func makeSession(_ fmt: CMVideoFormatDescription) {
        if let s = session { VTDecompressionSessionInvalidate(s); session = nil }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()
        ]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt,
                                              decoderSpecification: nil,
                                              imageBufferAttributes: attrs as CFDictionary,
                                              outputCallback: nil, decompressionSessionOut: &s)
        guard st == noErr, let sess = s else { print("session error \(st)"); return }
        VTSessionSetProperty(sess, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = sess
    }

    private func splitAnnexB(_ d: Data) -> [Data] {
        var result: [Data] = []
        let bytes = [UInt8](d)
        let n = bytes.count
        var i = 0
        var start = -1
        while i + 2 < n {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start && bytes[end - 1] == 0 { end -= 1 }
                    if end > start { result.append(Data(bytes[start..<end])) }
                }
                start = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        if start >= 0 && start < n { result.append(Data(bytes[start..<n])) }
        return result
    }
}
