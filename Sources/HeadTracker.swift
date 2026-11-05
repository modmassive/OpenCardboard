import CoreMotion
import simd

/// Reads phone orientation and returns a 3x3 matrix whose columns are the
/// headset's right / up / back axes in a y-up render space.
final class HeadTracker {
    private let mm = CMMotionManager()
    private var yawOffset: Float = 0
    private var wantsRecenter = true

    /// If turning your head moves the world the wrong way, flip this.
    var useTranspose = true

    func start() {
        guard mm.isDeviceMotionAvailable else { return }
        mm.deviceMotionUpdateInterval = 1.0 / 200.0
        mm.startDeviceMotionUpdates(using: .xArbitraryZVertical)
    }

    func recenter() { wantsRecenter = true }

    func viewMatrix() -> simd_float3x3 {
        guard let m = mm.deviceMotion?.attitude.rotationMatrix else {
            return matrix_identity_float3x3
        }
        let transpose = useTranspose

        func toRender(_ d: SIMD3<Double>) -> SIMD3<Float> {
            let r: SIMD3<Double>
            if transpose {
                r = SIMD3(m.m11 * d.x + m.m21 * d.y + m.m31 * d.z,
                          m.m12 * d.x + m.m22 * d.y + m.m32 * d.z,
                          m.m13 * d.x + m.m23 * d.y + m.m33 * d.z)
            } else {
                r = SIMD3(m.m11 * d.x + m.m12 * d.y + m.m13 * d.z,
                          m.m21 * d.x + m.m22 * d.y + m.m23 * d.z,
                          m.m31 * d.x + m.m32 * d.y + m.m33 * d.z)
            }
            // reference frame is z-up; render space is y-up
            return SIMD3(Float(r.x), Float(r.z), Float(-r.y))
        }

        // Phone locked to landscapeRight: viewer right = device -Y,
        // viewer up = device +X, viewer back = device +Z.
        let right = toRender(SIMD3(0, -1, 0))
        let up    = toRender(SIMD3(1, 0, 0))
        let back  = toRender(SIMD3(0, 0, 1))

        if wantsRecenter {
            let f = -back
            yawOffset = atan2(f.x, -f.z)
            wantsRecenter = false
        }
        let c = cos(yawOffset), s = sin(yawOffset)
        func rot(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)
        }
        return simd_float3x3(columns: (rot(right), rot(up), rot(back)))
    }
}
