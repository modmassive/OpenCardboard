import MetalKit
import simd

/// Approximate Cardboard v2-style lens settings. Tune these.
struct LensParams {
    var ipdMM: Float = 64
    var lensSeparationMM: Float = 64
    var screenToLensMM: Float = 39
    var k1: Float = 0.34
    var k2: Float = 0.55
    var pxPerMM: Float = 460.0 / 25.4   // iPhone Pro-class panels (~460 ppi)
}

struct Uniforms {
    var view: simd_float3x3
    var viewport: SIMD2<Float>
    var ipd: Float          // meters
    var screenToLens: Float // mm
    var k1: Float
    var k2: Float
    var pxPerMM: Float
    var lensSepMM: Float
}

final class Renderer: NSObject, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let tracker = HeadTracker()
    var params = LensParams()

    init?(view: MTKView) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        queue = q
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
    }

    func recenter() { tracker.recenter() }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let size = view.drawableSize
        var u = Uniforms(view: tracker.viewMatrix(),
                         viewport: SIMD2(Float(size.width), Float(size.height)),
                         ipd: params.ipdMM / 1000,
                         screenToLens: params.screenToLensMM,
                         k1: params.k1, k2: params.k2,
                         pxPerMM: params.pxPerMM,
                         lensSepMM: params.lensSeparationMM)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
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
    float2 viewport;
    float ipd;
    float screenToLens;
    float k1;
    float k2;
    float pxPerMM;
    float lensSepMM;
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

fragment float4 fs(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
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

    // 8 compass pillars; the one straight ahead after recentering is red
    float az = atan2(rd.x, -rd.z);
    float step45 = M_PI_F / 4.0;
    float k = round(az / step45);
    if (abs(az - k * step45) < 0.012 && abs(rd.y) < 0.4) {
        float3 pc = (k == 0.0) ? float3(1.0, 0.2, 0.2) : float3(0.9);
        col = mix(col, pc, 0.9);
    }

    col *= smoothstep(1.4, 1.0, length(t));
    return float4(col, 1.0);
}
"""
