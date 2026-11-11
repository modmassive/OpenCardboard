import MetalKit
import simd
import UIKit

struct Uniforms {
    var view: simd_float3x3
    var warp: simd_float3x3
    var viewport: SIMD2<Float>
    var ipd: Float
    var screenToLens: Float
    var k1: Float
    var k2: Float
    var pxPerMM: Float
    var lensSepMM: Float
    var frustL: SIMD4<Float>
    var frustR: SIMD4<Float>
    var mode: Float
    var hud: Float
    var menu: Float
    var sharpen: Float
    var params: SIMD4<Float>
}

/// Tangent extents (left, right, up, down) each eye needs rendered to fill the visible lens area.
func recommendedFrusta(lens: LensSettings, pxPerMM: Float, W: Float, H: Float,
                       maxR: Float = 1.1) -> (SIMD4<Float>, SIMD4<Float>) {
    func eye(_ sign: Float) -> SIMD4<Float> {
        let cx = W * 0.5 + sign * lens.lensSeparationMM * 0.5 * pxPerMM
        let cy = H * 0.5
        let x0: Float = sign < 0 ? 0 : W * 0.5
        let x1: Float = sign < 0 ? W * 0.5 : W
        var ext = SIMD4<Float>(repeating: 0.2)   // l, r, u, d
        let n = 48
        for iy in 0...n {
            for ix in 0...n {
                let x = x0 + (x1 - x0) * Float(ix) / Float(n)
                let y = H * Float(iy) / Float(n)
                var t = SIMD2<Float>(x - cx, -(y - cy)) / (pxPerMM * lens.screenToLensMM)
                let r2 = simd_dot(t, t)
                if r2.squareRoot() > maxR { continue }
                t *= 1 + lens.k1 * r2 + lens.k2 * r2 * r2
                ext[0] = max(ext[0], -t.x)
                ext[1] = max(ext[1], t.x)
                ext[2] = max(ext[2], t.y)
                ext[3] = max(ext[3], -t.y)
            }
        }
        return ext
    }
    return (eye(-1), eye(1))
}

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let dummy: MTLTexture
    private let hudTexture: MTLTexture
    private let menuTexture: MTLTexture
    private var textureCache: CVMetalTextureCache?
    private let tracker = HeadTracker()
    private let positionTracker = PositionTracker()
    private let decoder = VideoDecoder()
    let link = PCLink()
    let menu = MenuController()

    let pxPerMM: Float = 460.0 / 25.4   // iPhone Pro-class panels (~460 ppi)
    var lens = LensSettings()
    var display = DisplaySettings()
    private(set) var slot = 0
    var forceTest = false
    var hudManual = false               // toggled by double-tap

    private var poseSeq: UInt32 = 0
    private let lock = NSLock()
    private var latest: DecodedFrame?
    private var streamCfg: StreamConfig?
    private var pcInfoRows: [(String, String)] = []
    private var decodedCount = 0
    private var lastCount = 0
    private var lastTime = CACurrentMediaTime()
    private var lastFPS = 0.0
    private var showingVideo = false

    private var hudAutoUntil = CACurrentMediaTime() + 10
    private var lastHUDUpdate = 0.0
    private var lastConnected = false
    private var lastConnectedTime = CACurrentMediaTime()
    private var hudLastCount = 0
    private var hudLastTime = CACurrentMediaTime()
    private var hudFPS = 0.0
    private var lastMenuRender = 0.0
    private var helloDirtyAt = 0.0
    private var frameCounter: UInt64 = 0
    private var fpsFrames = 0
    private var fpsStart = CACurrentMediaTime()
    private var drawFPS = 0.0

    init?(view: MTKView) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                          width: 1, height: 1, mipmapped: false)
        let hd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: 1024, height: 512, mipmapped: false)
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: 1280, height: 800, mipmapped: false)
        guard let dummyTex = dev.makeTexture(descriptor: td),
              let hudTex = dev.makeTexture(descriptor: hd),
              let menuTex = dev.makeTexture(descriptor: md) else { return nil }
        device = dev
        queue = q
        dummy = dummyTex
        hudTexture = hudTex
        menuTexture = menuTex
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache)
        textureCache = cache

        view.device = dev
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 120
        view.contentScaleFactor = UIScreen.main.nativeScale
        do {
            let lib = try dev.makeLibrary(source: shaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vs")
            d.fragmentFunction = lib.makeFunction(name: "fs")
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try dev.makeRenderPipelineState(descriptor: d)
        } catch {
            print("Pipeline error: \(error)")
            return nil
        }
        super.init()

        UIDevice.current.isBatteryMonitoringEnabled = true
        slot = SettingsStore.shared.slot
        lens = SettingsStore.shared.load(slot)
        display = SettingsStore.shared.loadDisplay()
        positionTracker.headForward = { [weak self] in
            self?.tracker.forwardVector() ?? SIMD3<Float>(0, 0, -1)
        }
        applyDisplayEffects()
        tracker.start()

        menu.tabs = buildTabs()
        menu.onOpenChanged = { [weak self] open in
            guard let self = self else { return }
            self.link.sendMenuState(open)
            if !open { self.forceTest = false }
        }

        link.onStreamConfig = { [weak self] cfg in
            guard let self = self else { return }
            self.lock.lock(); self.streamCfg = cfg; self.lock.unlock()
            self.decoder.setCodec(cfg.codec == 2 ? .hevc : .h264)
            self.link.sendRequestKeyframe()
        }
        link.onVideoFrame = { [weak self] header, data in
            self?.decoder.decode(annexB: data, header: header)
        }
        link.onUiInput = { [weak self] st in
            DispatchQueue.main.async { self?.menu.handle(st) }
        }
        link.onMenuState = { [weak self] open in
            DispatchQueue.main.async { self?.menu.isOpen = open }
        }
        link.onPcInfo = { [weak self] text in self?.setPcInfo(text) }
        decoder.onFrame = { [weak self] f in
            guard let self = self else { return }
            self.lock.lock(); self.latest = f; self.decodedCount += 1; self.lock.unlock()
        }
        decoder.onError = { [weak self] in self?.link.sendRequestKeyframe() }
        link.start(port: 9000)
        link.updateHello(makeHello())
    }

    func recenter() {
        tracker.recenter()
        positionTracker.resetOrigin()
    }

    // MARK: settings changes

    func setLens(_ s: LensSettings, notify: Bool) {
        lens = s
        if notify { link.updateHello(makeHello()) }
    }

    private func changeLens(_ mutate: (inout LensSettings) -> Void) {
        var l = lens
        mutate(&l)
        lens = l
        SettingsStore.shared.save(l, slot: slot)
        helloDirtyAt = CACurrentMediaTime()      // tell the PC once the adjustment settles
        menu.dirty = true
    }

    private func setSlot(_ i: Int) {
        let n = min(max(i, 0), 2)
        slot = n
        SettingsStore.shared.slot = n
        lens = SettingsStore.shared.load(n)
        helloDirtyAt = CACurrentMediaTime()
        menu.dirty = true
    }

    private func changeDisplay(_ mutate: (inout DisplaySettings) -> Void) {
        var d = display
        mutate(&d)
        display = d
        SettingsStore.shared.saveDisplay(d)
        applyDisplayEffects()
        menu.dirty = true
    }

    private func applyDisplayEffects() {
        UIScreen.main.brightness = CGFloat(display.brightness)
        positionTracker.setEnabled(display.cameraTracking)
    }

    func makeHello() -> Hello {
        let b = UIScreen.main.nativeBounds
        let W = Float(max(b.width, b.height)), H = Float(min(b.width, b.height))
        let (fl, fr) = recommendedFrusta(lens: lens, pxPerMM: pxPerMM, W: W, H: H)
        return Hello(screenW: UInt16(W), screenH: UInt16(H),
                     refresh: UInt16(UIScreen.main.maximumFramesPerSecond),
                     lens: lens, frustL: fl, frustR: fr)
    }

    // MARK: the menu contents

    private func buildTabs() -> [MenuTab] {
        func lensItem(_ title: String, _ mn: Float, _ mx: Float, _ st: Float, _ fmt: String,
                      _ read: @escaping (LensSettings) -> Float,
                      _ write: @escaping (inout LensSettings, Float) -> Void) -> MenuItem {
            return MenuItem(title, .slider(min: mn, max: mx, step: st, fmt: fmt),
                            get: { [weak self] in self.map { read($0.lens) } ?? 0 },
                            set: { [weak self] v in self?.changeLens { write(&$0, v) } })
        }

        var fit: [MenuItem] = []
        fit.append(lensItem("IPD", 50, 80, 0.5, "%.1f mm", { $0.ipdMM }, { $0.ipdMM = $1 }))
        fit.append(lensItem("Lens separation", 45, 80, 0.5, "%.1f mm", { $0.lensSeparationMM }, { $0.lensSeparationMM = $1 }))
        fit.append(lensItem("Screen to lens", 20, 70, 0.5, "%.1f mm", { $0.screenToLensMM }, { $0.screenToLensMM = $1 }))
        fit.append(MenuItem("Housing preset", .choice(["1", "2", "3"]),
                            get: { [weak self] in Float(self?.slot ?? 0) },
                            set: { [weak self] v in self?.setSlot(Int(v.rounded())) }))
        fit.append(MenuItem("Lens test grid", .toggle,
                            get: { [weak self] in (self?.forceTest ?? false) ? 1 : 0 },
                            set: { [weak self] v in self?.forceTest = v > 0.5 }))
        fit.append(lensItem("Distortion k1", 0, 1, 0.01, "%.2f", { $0.k1 }, { $0.k1 = $1 }))
        fit.append(lensItem("Distortion k2", 0, 1, 0.01, "%.2f", { $0.k2 }, { $0.k2 = $1 }))
        fit.append(MenuItem("Reset this preset", .action,
                            perform: { [weak self] in self?.changeLens { $0 = LensSettings() } }))

        var disp: [MenuItem] = []
        disp.append(MenuItem("Sharpening", .slider(min: 0, max: 1, step: 0.05, fmt: "%.2f"),
                             get: { [weak self] in self?.display.sharpen ?? 0 },
                             set: { [weak self] v in self?.changeDisplay { $0.sharpen = v } }))
        disp.append(MenuItem("Black frames", .toggle,
                             get: { [weak self] in (self?.display.blackFrames ?? false) ? 1 : 0 },
                             set: { [weak self] v in self?.changeDisplay { $0.blackFrames = v > 0.5 } }))
        disp.append(MenuItem("Screen brightness", .slider(min: 0.2, max: 1, step: 0.05, fmt: "%.2f"),
                             get: { [weak self] in self?.display.brightness ?? 1 },
                             set: { [weak self] v in self?.changeDisplay { $0.brightness = v } }))
        disp.append(MenuItem("Status display", .choice(["Auto", "Always", "Off"]),
                             get: { [weak self] in Float(self?.display.statusMode ?? 0) },
                             set: { [weak self] v in self?.changeDisplay { $0.statusMode = Int(v.rounded()) } }))

        var track: [MenuItem] = []
        track.append(MenuItem("Camera tracking", .toggle,
                              get: { [weak self] in (self?.display.cameraTracking ?? false) ? 1 : 0 },
                              set: { [weak self] v in self?.changeDisplay { $0.cameraTracking = v > 0.5 } }))
        track.append(MenuItem("Recenter now", .action, perform: { [weak self] in self?.recenter() }))
        track.append(MenuItem("Reset position", .action, perform: { [weak self] in self?.positionTracker.resetOrigin() }))

        return [
            MenuTab(title: "Fit", items: fit),
            MenuTab(title: "Display", items: disp),
            MenuTab(title: "Tracking", items: track,
                    infoRows: { [weak self] in [("Camera", self?.positionTracker.statusText ?? "off")] }),
            MenuTab(title: "Status", items: [],
                    infoRows: { [weak self] in self?.statusRows() ?? [] })
        ]
    }

    private func setPcInfo(_ text: String) {
        var rows: [(String, String)] = []
        for part in text.split(separator: "|") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { rows.append((String(kv[0]), String(kv[1]))) }
        }
        lock.lock(); pcInfoRows = rows; lock.unlock()
    }

    private func batteryText() -> String {
        let l = UIDevice.current.batteryLevel
        return l < 0 ? "unknown" : String(format: "%.0f%%", l * 100)
    }

    private func thermalText() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "normal"
        case .fair: return "warm"
        case .serious: return "hot (slowing down)"
        case .critical: return "very hot"
        @unknown default: return "unknown"
        }
    }

    func statusRows() -> [(String, String)] {
        let now = CACurrentMediaTime()
        lock.lock()
        let count = decodedCount
        let cfg = streamCfg
        let info = pcInfoRows
        lock.unlock()
        if now - lastTime >= 0.4 {
            lastFPS = Double(count - lastCount) / (now - lastTime)
            lastCount = count
            lastTime = now
        }
        var rows: [(String, String)] = []
        rows.append(("PC link", link.isConnected ? "connected" : "waiting"))
        rows.append(("Round trip", String(format: "%.1f ms", link.rttMs)))
        if let c = cfg {
            rows.append(("Stream", "\(c.width)x\(c.height) \(c.codec == 2 ? "HEVC" : "H.264")"))
        } else {
            rows.append(("Stream", "none"))
        }
        rows.append(("Video decode", String(format: "%.0f fps", lastFPS)))
        rows.append(("Display", String(format: "%.0f fps (panel up to %d Hz)", drawFPS, UIScreen.main.maximumFramesPerSecond)))
        rows.append(("Battery", batteryText()))
        rows.append(("Heat", thermalText()))
        rows.append(contentsOf: info)
        rows.append(("Phone", primaryIP()))
        return rows
    }

    // MARK: in-headset status display

    private func primaryIP() -> String {
        let all = localIPv4Addresses()
        func addr(_ s: String) -> String { s.split(separator: " ").last.map(String.init) ?? s }
        if let b = all.first(where: { $0.hasPrefix("bridge") }) { return "USB " + addr(b) }
        if let w = all.first(where: { $0.hasPrefix("en0") }) { return "WiFi " + addr(w) }
        return "no network address (USB tunnel)"
    }

    private func hudLines() -> [String] {
        let now = CACurrentMediaTime()
        lock.lock()
        let count = decodedCount
        let cfg = streamCfg
        lock.unlock()
        if now - hudLastTime >= 0.4 {
            hudFPS = Double(count - hudLastCount) / (now - hudLastTime)
            hudLastCount = count
            hudLastTime = now
        }
        let connected = link.isConnected
        var l: [String] = []
        l.append(connected ? "PC: connected" : "PC: waiting")
        l.append(connected ? String(format: "Ping: %.1f ms", link.rttMs) : "Ping: -")
        if let c = cfg {
            l.append("Stream: \(c.width)x\(c.height) \(c.codec == 2 ? "HEVC" : "H264")")
        } else {
            l.append("Stream: none")
        }
        l.append(String(format: "Decode: %.0f fps", hudFPS))
        l.append("View: " + (showingVideo ? "video" : "test scene"))
        l.append("Hold LB+RB: menu")
        if !connected, !link.lastCloseReason.isEmpty {
            l.append("Drop: " + String(link.lastCloseReason.prefix(24)))
        }
        return l
    }

    private func upload(_ cg: CGImage, to tex: MTLTexture, width: Int, height: Int) {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: pixels, bytesPerRow: width * 4)
    }

    private func renderHUD(lines: [String]) {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        let size = CGSize(width: 1024, height: 512)
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            UIColor(white: 0, alpha: 0.78).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 40).fill()
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 48, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: para
            ]
            (lines.joined(separator: "\n") as NSString)
                .draw(in: CGRect(x: 20, y: 24, width: 984, height: 470), withAttributes: attrs)
        }
        if let cg = img.cgImage { upload(cg, to: hudTexture, width: 1024, height: 512) }
    }

    // MARK: drawing

    private func makeTexture(_ pb: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        guard let cache = textureCache else { return nil }
        var cv: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let st = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm,
                                                           w, h, 0, &cv)
        guard st == kCVReturnSuccess, let c = cv, let tex = CVMetalTextureGetTexture(c) else { return nil }
        return (tex, c)
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let size = view.drawableSize
        let now = CACurrentMediaTime()
        frameCounter &+= 1

        fpsFrames += 1
        if now - fpsStart >= 1.0 {
            drawFPS = Double(fpsFrames) / (now - fpsStart)
            fpsFrames = 0
            fpsStart = now
        }

        // menu housekeeping: key repeat, auto-close when idle or when the PC link is gone
        menu.tick(now)
        let connected = link.isConnected
        if connected { lastConnectedTime = now }
        if menu.isOpen && (now - menu.lastInputTime > 60 || (!connected && now - lastConnectedTime > 3)) {
            menu.isOpen = false
        }
        if helloDirtyAt > 0 && now - helloDirtyAt > 0.4 {
            helloDirtyAt = 0
            link.updateHello(makeHello())
        }

        let sm = tracker.sample()
        let R = sm.matrix
        let pos = positionTracker.position()
        if connected {
            poseSeq &+= 1
            link.sendPose(seq: poseSeq, time: ProcessInfo.processInfo.systemUptime,
                          rotation: R, position: pos, omega: sm.omega)
        }
        if connected != lastConnected {
            lastConnected = connected
            hudAutoUntil = now + 6          // show status for a few seconds when the link changes
        }

        // black-frame mode: every other refresh is left black
        if display.blackFrames && frameCounter % 2 == 1 {
            enc.endEncoding()
            cb.present(drawable)
            cb.commit()
            return
        }

        let menuOn = menu.isOpen
        let hudOn = !menuOn && display.statusMode != 2 &&
                    (display.statusMode == 1 || hudManual || now < hudAutoUntil)
        if hudOn && now - lastHUDUpdate > 0.3 {
            lastHUDUpdate = now
            renderHUD(lines: hudLines())
        }
        if menuOn && (menu.dirty || (menu.currentTabHasInfo && now - lastMenuRender > 0.25)) {
            lastMenuRender = now
            menu.dirty = false
            if let cg = menu.makeImage() { upload(cg, to: menuTexture, width: 1280, height: 800) }
        }

        lock.lock()
        let frame = latest
        let cfg = streamCfg
        lock.unlock()

        var mode: Float = 0
        var warp = matrix_identity_float3x3
        var fL = SIMD4<Float>(repeating: 1)
        var fR = SIMD4<Float>(repeating: 1)
        var tex: MTLTexture = dummy
        var cvHold: CVMetalTexture?

        if !forceTest, let f = frame, let c = cfg,
           now - f.arrival < 1.0,
           let (t, cv) = makeTexture(f.pixelBuffer) {
            mode = 1
            // rotate view rays from "head now" into "head at render time"
            warp = f.header.rotation.transpose * R
            fL = c.frustL
            fR = c.frustR
            tex = t
            cvHold = cv
        }
        showingVideo = mode > 0.5

        var u = Uniforms(view: R, warp: warp,
                         viewport: SIMD2(Float(size.width), Float(size.height)),
                         ipd: lens.ipdMM / 1000,
                         screenToLens: lens.screenToLensMM,
                         k1: lens.k1, k2: lens.k2,
                         pxPerMM: pxPerMM,
                         lensSepMM: lens.lensSeparationMM,
                         frustL: fL, frustR: fR, mode: mode,
                         hud: hudOn ? 1 : 0,
                         menu: menuOn ? 1 : 0,
                         sharpen: display.sharpen,
                         params: SIMD4<Float>(0, 0, 0, 0))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentTexture(hudTexture, index: 1)
        enc.setFragmentTexture(menuTexture, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        let keepCV = cvHold
        let keepFrame = frame
        cb.addCompletedHandler { _ in withExtendedLifetime((keepCV, keepFrame)) {} }
        cb.present(drawable)
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

// Shader is compiled at runtime so the CI build needs no Metal toolchain.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float3x3 view;
    float3x3 warp;
    float2 viewport;
    float ipd;
    float screenToLens;
    float k1;
    float k2;
    float pxPerMM;
    float lensSepMM;
    float4 frustL;
    float4 frustR;
    float mode;
    float hud;
    float menu;
    float sharpen;
    float4 params;
};

struct VOut { float4 pos [[position]]; };

vertex VOut vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

float gridLine(float2 p, float scale) {
    float2 q = p / scale;
    float2 w = max(fwidth(q), float2(1e-4));
    float2 g = abs(fract(q - 0.5) - 0.5) / w;
    return 1.0 - min(min(g.x, g.y), 1.0);
}

// Catmull-Rom resampling with 9 bilinear taps (much sharper than plain bilinear for small text)
float3 sampleBicubic(texture2d<float> tex, sampler s, float2 uv, float2 texSize) {
    float2 samplePos = uv * texSize;
    float2 texPos1 = floor(samplePos - 0.5) + 0.5;
    float2 f = samplePos - texPos1;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 offset12 = w2 / w12;
    float2 p0 = (texPos1 - 1.0) / texSize;
    float2 p3 = (texPos1 + 2.0) / texSize;
    float2 p12 = (texPos1 + offset12) / texSize;
    float3 r = float3(0.0);
    r += tex.sample(s, float2(p0.x,  p0.y),  level(0)).rgb * (w0.x  * w0.y);
    r += tex.sample(s, float2(p12.x, p0.y),  level(0)).rgb * (w12.x * w0.y);
    r += tex.sample(s, float2(p3.x,  p0.y),  level(0)).rgb * (w3.x  * w0.y);
    r += tex.sample(s, float2(p0.x,  p12.y), level(0)).rgb * (w0.x  * w12.y);
    r += tex.sample(s, float2(p12.x, p12.y), level(0)).rgb * (w12.x * w12.y);
    r += tex.sample(s, float2(p3.x,  p12.y), level(0)).rgb * (w3.x  * w12.y);
    r += tex.sample(s, float2(p0.x,  p3.y),  level(0)).rgb * (w0.x  * w3.y);
    r += tex.sample(s, float2(p12.x, p3.y),  level(0)).rgb * (w12.x * w3.y);
    r += tex.sample(s, float2(p3.x,  p3.y),  level(0)).rgb * (w3.x  * w3.y);
    return r;
}

fragment float4 fs(VOut in [[stage_in]],
                   constant Uniforms& u [[buffer(0)]],
                   texture2d<float> tex [[texture(0)]],
                   texture2d<float> hudTex [[texture(1)]],
                   texture2d<float> menuTex [[texture(2)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);

    float2 frag = in.pos.xy;
    bool left = frag.x < u.viewport.x * 0.5;
    float eye = left ? -1.0 : 1.0;
    float2 center = float2(u.viewport.x * 0.5 + eye * u.lensSepMM * 0.5 * u.pxPerMM,
                           u.viewport.y * 0.5);

    // screen pixels -> tangent space, then Cardboard-style radial distortion
    float2 t = (frag - center) / (u.pxPerMM * u.screenToLens);
    t.y = -t.y;
    float r2 = dot(t, t);
    float2 tu = t * (1.0 + u.k1 * r2 + u.k2 * r2 * r2);
    float vig = smoothstep(1.4, 1.0, length(t));

    float3 col = float3(0.0);

    if (u.mode > 0.5) {
        // video: rotational timewarp, then project into the rendered frame
        float3 d = u.warp * normalize(float3(tu.x, tu.y, -1.0));
        if (d.z < -1e-3) {
            float tx = d.x / -d.z;
            float ty = d.y / -d.z;
            float4 fr = left ? u.frustL : u.frustR;   // left, right, up, down
            float uu = (tx + fr.x) / (fr.x + fr.y);
            float vv = (fr.z - ty) / (fr.z + fr.w);
            if (uu >= 0.0 && uu <= 1.0 && vv >= 0.0 && vv <= 1.0) {
                float2 uv = float2((left ? 0.0 : 0.5) + uu * 0.5, vv);
                if (u.sharpen > 0.001) {
                    float2 ts = float2(tex.get_width(), tex.get_height());
                    float3 c = clamp(sampleBicubic(tex, smp, uv, ts), 0.0, 1.0);
                    float2 px = 1.0 / ts;
                    float3 n  = tex.sample(smp, uv + float2(0.0, -px.y), level(0)).rgb;
                    float3 s2 = tex.sample(smp, uv + float2(0.0,  px.y), level(0)).rgb;
                    float3 e2 = tex.sample(smp, uv + float2( px.x, 0.0), level(0)).rgb;
                    float3 w2 = tex.sample(smp, uv + float2(-px.x, 0.0), level(0)).rgb;
                    float3 blur = (n + s2 + e2 + w2) * 0.25;
                    float3 mn = min(min(min(n, s2), min(e2, w2)), c);
                    float3 mx = max(max(max(n, s2), max(e2, w2)), c);
                    col = clamp(c + (c - blur) * (u.sharpen * 1.5), mn, mx);
                } else {
                    col = tex.sample(smp, uv, level(0)).rgb;
                }
            }
        }
    } else {
        float3 rd = normalize(u.view * float3(tu.x, tu.y, -1.0));
        float3 ro = u.view * float3(eye * u.ipd * 0.5, 0.0, 0.0);

        float h = clamp(rd.y * 0.5 + 0.5, 0.0, 1.0);
        col = mix(float3(0.05, 0.07, 0.12), float3(0.01, 0.01, 0.04), h);

        if (rd.y < -1e-3) {
            float tt = (-1.6 - ro.y) / rd.y;
            float3 p = ro + rd * tt;
            float g1 = gridLine(p.xz, 1.0);
            float g5 = gridLine(p.xz, 5.0);
            float3 fl = float3(0.04, 0.06, 0.09) + float3(0.15, 0.55, 0.9) * g1 * 0.6
                      + float3(1.0, 0.6, 0.2) * g5 * 0.8;
            col = mix(col, fl, exp(-tt * 0.06));
        } else if (rd.y > 1e-3) {
            float tt = (2.4 - ro.y) / rd.y;
            float3 p = ro + rd * tt;
            float g1 = gridLine(p.xz, 1.0);
            float3 cl = float3(0.03, 0.04, 0.07) + float3(0.3, 0.2, 0.6) * g1 * 0.5;
            col = mix(col, cl, exp(-tt * 0.08));
        }

        float az = atan2(rd.x, -rd.z);
        float step45 = M_PI_F / 4.0;
        float k = round(az / step45);
        if (abs(az - k * step45) < 0.012 && abs(rd.y) < 0.4) {
            float3 pc = (k == 0.0) ? float3(1.0, 0.2, 0.2) : float3(0.9);
            col = mix(col, pc, 0.9);
        }
    }

    col *= vig;

    // head-locked status panel, centered in each eye, floating about 1.5 m away
    if (u.hud > 0.5) {
        float2 hc = float2(-eye * 0.032 / 1.5, 0.0);
        float2 hp = (tu - hc) / float2(0.6, 0.3);
        if (abs(hp.x) <= 1.0 && abs(hp.y) <= 1.0) {
            float2 huv = float2(hp.x * 0.5 + 0.5, 0.5 - hp.y * 0.5);
            float4 h = hudTex.sample(smp, huv, level(0));
            col = h.rgb + col * (1.0 - h.a);
        }
    }

    // settings menu, larger, about 1.2 m away
    if (u.menu > 0.5) {
        float2 mc = float2(-eye * 0.032 / 1.2, 0.0);
        float2 mp = (tu - mc) / float2(0.70, 0.4375);
        if (abs(mp.x) <= 1.0 && abs(mp.y) <= 1.0) {
            float2 muv = float2(mp.x * 0.5 + 0.5, 0.5 - mp.y * 0.5);
            float4 m = menuTex.sample(smp, muv, level(0));
            col = m.rgb + col * (1.0 - m.a);
        }
    }

    return float4(col, 1.0);
}
"""
