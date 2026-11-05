import MetalKit
import simd

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
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
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
    private var textureCache: CVMetalTextureCache?
    private let tracker = HeadTracker()
    private let decoder = VideoDecoder()
    let link = PCLink()

    let pxPerMM: Float = 460.0 / 25.4   // iPhone Pro-class panels (~460 ppi)
    var lens = LensSettings()
    var forceTest = false

    private var poseSeq: UInt32 = 0
    private let lock = NSLock()
    private var latest: DecodedFrame?
    private var streamCfg: StreamConfig?
    private var decodedCount = 0
    private var lastCount = 0
    private var lastTime = CACurrentMediaTime()
    private var lastFPS = 0.0
    private var showingVideo = false

    init?(view: MTKView) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                          width: 1, height: 1, mipmapped: false)
        guard let dummyTex = dev.makeTexture(descriptor: td) else { return nil }
        device = dev
        queue = q
        dummy = dummyTex
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

        tracker.start()

        link.onStreamConfig = { [weak self] cfg in
            guard let self = self else { return }
            self.lock.lock(); self.streamCfg = cfg; self.lock.unlock()
            self.decoder.setCodec(cfg.codec == 2 ? .hevc : .h264)
            self.link.sendRequestKeyframe()
        }
        link.onVideoFrame = { [weak self] header, data in
            self?.decoder.decode(annexB: data, header: header)
        }
        decoder.onFrame = { [weak self] f in
            guard let self = self else { return }
            self.lock.lock(); self.latest = f; self.decodedCount += 1; self.lock.unlock()
        }
        decoder.onError = { [weak self] in self?.link.sendRequestKeyframe() }
        link.start(port: 9000)
        link.updateHello(makeHello())
    }

    func recenter() { tracker.recenter() }

    func setLens(_ s: LensSettings, notify: Bool) {
        lens = s
        if notify { link.updateHello(makeHello()) }
    }

    func makeHello() -> Hello {
        let b = UIScreen.main.nativeBounds
        let W = Float(max(b.width, b.height)), H = Float(min(b.width, b.height))
        let (fl, fr) = recommendedFrusta(lens: lens, pxPerMM: pxPerMM, W: W, H: H)
        return Hello(screenW: UInt16(W), screenH: UInt16(H),
                     refresh: UInt16(UIScreen.main.maximumFramesPerSecond),
                     lens: lens, frustL: fl, frustR: fr)
    }

    func statusText() -> String {
        let now = CACurrentMediaTime()
        lock.lock()
        let count = decodedCount
        let cfg = streamCfg
        lock.unlock()
        if now - lastTime >= 0.4 {
            lastFPS = Double(count - lastCount) / (now - lastTime)
            lastCount = count
            lastTime = now
        }
        var s = "Port 9000  -  \(link.stateText)\n"
        let ips = localIPv4Addresses()
        s += "Phone IPs: " + (ips.isEmpty ? "none" : ips.joined(separator: ", ")) + "\n"
        s += String(format: "Round trip: %.1f ms\n", link.rttMs)
        if let c = cfg {
            s += "Stream: \(c.width)x\(c.height) \(c.codec == 2 ? "HEVC" : "H.264")\n"
        } else {
            s += "Stream: none\n"
        }
        s += String(format: "Decoded: %.0f fps\n", lastFPS)
        s += "View: " + (showingVideo ? "video" : "test scene")
        return s
    }

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
        let R = tracker.viewMatrix()

        if link.isConnected {
            poseSeq &+= 1
            link.sendPose(seq: poseSeq, time: ProcessInfo.processInfo.systemUptime, rotation: R)
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
           CACurrentMediaTime() - f.arrival < 1.0,
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
                         frustL: fL, frustR: fR, mode: mode)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(tex, index: 0)
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
    float pad0;
    float pad1;
    float pad2;
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

fragment float4 fs(VOut in [[stage_in]],
                   constant Uniforms& u [[buffer(0)]],
                   texture2d<float> tex [[texture(0)]]) {
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

    if (u.mode > 0.5) {
        // video: rotational timewarp, then project into the rendered frame
        float3 d = u.warp * normalize(float3(tu.x, tu.y, -1.0));
        if (d.z > -1e-3) { return float4(0.0, 0.0, 0.0, 1.0); }
        float tx = d.x / -d.z;
        float ty = d.y / -d.z;
        float4 fr = left ? u.frustL : u.frustR;   // left, right, up, down
        float uu = (tx + fr.x) / (fr.x + fr.y);
        float vv = (fr.z - ty) / (fr.z + fr.w);
        if (uu < 0.0 || uu > 1.0 || vv < 0.0 || vv > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        float2 uv = float2((left ? 0.0 : 0.5) + uu * 0.5, vv);
        float3 c = tex.sample(smp, uv).rgb;
        return float4(c * vig, 1.0);
    }

    float3 rd = normalize(u.view * float3(tu.x, tu.y, -1.0));
    float3 ro = u.view * float3(eye * u.ipd * 0.5, 0.0, 0.0);

    float h = clamp(rd.y * 0.5 + 0.5, 0.0, 1.0);
    float3 col = mix(float3(0.05, 0.07, 0.12), float3(0.01, 0.01, 0.04), h);

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

    return float4(col * vig, 1.0);
}
"""
