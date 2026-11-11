import CoreMotion
import simd

struct HeadSample {
    var matrix: simd_float3x3      // columns: head right / up / back in a y-up render space
    var omega: SIMD3<Float>        // gyro rate in the same space, rad/s
}

final class HeadTracker {
    private let mm = CMMotionManager()
    private var yawOffset: Float = 0
    private var wantsRecenter = true
    private let lock = NSLock()
    private var lastMatrix = matrix_identity_float3x3

    /// If turning your head moves the world the wrong way, flip this.
    var useTranspose = true

    func start() {
        guard mm.isDeviceMotionAvailable else { return }
        mm.deviceMotionUpdateInterval = 1.0 / 200.0
        mm.startDeviceMotionUpdates(using: .xArbitraryZVertical)
    }

    func recenter() { wantsRecenter = true }

    /// Latest head forward direction (thread-safe, for the camera tracker's yaw alignment).
    func forwardVector() -> SIMD3<Float> {
        lock.lock(); defer { lock.unlock() }
        return -lastMatrix.columns.2
    }

    func sample() -> HeadSample {
        guard let dm = mm.deviceMotion else {
            return HeadSample(matrix: matrix_identity_float3x3, omega: SIMD3<Float>(repeating: 0))
        }
        let m = dm.attitude.rotationMatrix
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

        // Phone locked to landscapeRight: viewer right = device -Y, up = device +X, back = device +Z.
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
        let mat = simd_float3x3(columns: (rot(right), rot(up), rot(back)))
        let rr = dm.rotationRate
        let omega = rot(toRender(SIMD3(rr.x, rr.y, rr.z)))

        lock.lock(); lastMatrix = mat; lock.unlock()
        return HeadSample(matrix: mat, omega: omega)
    }
}
