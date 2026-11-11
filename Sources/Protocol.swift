import Foundation
import simd

// Wire format: see PROTOCOL.md. All integers/floats little-endian.

enum MsgType: UInt16 {
    case hello = 1, streamConfig = 2, pose = 3, videoFrame = 4, ping = 5, pong = 6, requestKeyframe = 7
    case uiInput = 8, menuState = 9, pcInfo = 10
}

let protocolMagic: UInt32 = 0x3143564F
let headerSize = 12

struct ByteWriter {
    private(set) var data = Data()
    mutating func put<T>(_ v: T) {
        var x = v
        withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
    }
}

struct ByteReader {
    let data: Data
    var pos = 0
    init(_ d: Data) { data = d }
    mutating func get<T>(_ t: T.Type) -> T {
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: T.self) }
        pos += MemoryLayout<T>.size
        return v
    }
}

func makeFrame(_ type: MsgType, _ payload: Data) -> Data {
    var w = ByteWriter()
    w.put(protocolMagic)
    w.put(type.rawValue)
    w.put(UInt16(0))
    w.put(UInt32(payload.count))
    var d = w.data
    d.append(payload)
    return d
}

struct Hello {
    var screenW: UInt16
    var screenH: UInt16
    var refresh: UInt16
    var lens: LensSettings
    var frustL: SIMD4<Float>   // left, right, up, down tangents (positive)
    var frustR: SIMD4<Float>

    func encode() -> Data {
        var w = ByteWriter()
        w.put(UInt16(1))
        w.put(screenW); w.put(screenH); w.put(refresh)
        w.put(lens.ipdMM); w.put(lens.lensSeparationMM); w.put(lens.screenToLensMM)
        w.put(lens.k1); w.put(lens.k2)
        for i in 0..<4 { w.put(frustL[i]) }
        for i in 0..<4 { w.put(frustR[i]) }
        return w.data
    }
}

struct StreamConfig {
    var codec: UInt8          // 1 = H.264, 2 = HEVC
    var width: UInt16         // full side-by-side frame
    var height: UInt16
    var frustL: SIMD4<Float>
    var frustR: SIMD4<Float>

    init?(_ p: Data) {
        guard p.count >= 40 else { return nil }
        var r = ByteReader(p)
        let c = r.get(UInt8.self)
        _ = r.get(UInt8.self); _ = r.get(UInt8.self); _ = r.get(UInt8.self)
        let w = r.get(UInt16.self), h = r.get(UInt16.self)
        var fl = SIMD4<Float>(), fr = SIMD4<Float>()
        for i in 0..<4 { fl[i] = r.get(Float.self) }
        for i in 0..<4 { fr[i] = r.get(Float.self) }
        codec = c; width = w; height = h; frustL = fl; frustR = fr
    }
}

struct VideoFrameHeader {
    var poseSeq: UInt32
    var flags: UInt32
    var rotation: simd_float3x3   // pose the frame was rendered with (columns: right, up, back)
    var position: SIMD3<Float>
}

func parseVideoFrame(_ p: Data) -> (VideoFrameHeader, Data)? {
    guard p.count > 56 else { return nil }
    var r = ByteReader(p)
    let seq = r.get(UInt32.self)
    let flags = r.get(UInt32.self)
    var cols: [SIMD3<Float>] = []
    for _ in 0..<3 {
        let x = r.get(Float.self), y = r.get(Float.self), z = r.get(Float.self)
        cols.append(SIMD3(x, y, z))
    }
    let px = r.get(Float.self), py = r.get(Float.self), pz = r.get(Float.self)
    let h = VideoFrameHeader(poseSeq: seq, flags: flags,
                             rotation: simd_float3x3(columns: (cols[0], cols[1], cols[2])),
                             position: SIMD3(px, py, pz))
    return (h, p.subdata(in: 56..<p.count))
}

/// Pose message: 64 bytes as before, plus the gyro rate (rad/s, same space as the rotation) = 76 bytes.
func encodePose(seq: UInt32, time: Double, rotation: simd_float3x3,
                position: SIMD3<Float>, omega: SIMD3<Float>) -> Data {
    var w = ByteWriter()
    w.put(seq); w.put(UInt32(0)); w.put(time)
    for c in 0..<3 { for r in 0..<3 { w.put(rotation[c][r]) } }
    w.put(position.x); w.put(position.y); w.put(position.z)
    w.put(omega.x); w.put(omega.y); w.put(omega.z)
    return w.data
}

/// Xbox-style controller state relayed from the PC while the headset menu is open.
/// Button bits are the same as Windows XInput (0x0001 up, 0x0002 down, 0x0004 left, 0x0008 right,
/// 0x0010 start, 0x0020 back, 0x0040 L3, 0x0080 R3, 0x0100 LB, 0x0200 RB, 0x1000 A, 0x2000 B, 0x4000 X, 0x8000 Y).
struct PadState: Equatable {
    var buttons: UInt32 = 0
    var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0
    var lt: UInt8 = 0, rt: UInt8 = 0
}

func parsePadState(_ p: Data) -> PadState? {
    guard p.count >= 16 else { return nil }
    var r = ByteReader(p)
    var s = PadState()
    s.buttons = r.get(UInt32.self)
    s.lx = r.get(Int16.self); s.ly = r.get(Int16.self)
    s.rx = r.get(Int16.self); s.ry = r.get(Int16.self)
    s.lt = r.get(UInt8.self); s.rt = r.get(UInt8.self)
    return s
}
