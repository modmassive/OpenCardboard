import ARKit
import simd

/// Optional head POSITION from the phone's rear camera (ARKit). Orientation still comes from the gyro.
/// ARKit's world has an arbitrary yaw, so its heading is continuously compared with the gyro heading
/// and positions are rotated into the gyro's frame.
final class PositionTracker: NSObject, ARSessionDelegate {
    private let session = ARSession()
    private let lock = NSLock()
    private var running = false
    private var posAR = SIMD3<Float>(repeating: 0)
    private var originAR = SIMD3<Float>(repeating: 0)
    private var haveOrigin = false
    private var yawA: Float = 0
    private var haveYaw = false
    private var state = "off"

    /// Supplies the gyro-based head forward direction.
    var headForward: (() -> SIMD3<Float>)?

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = DispatchQueue(label: "opencardboard.ar")
    }

    var statusText: String { lock.lock(); defer { lock.unlock() }; return state }

    func setEnabled(_ on: Bool) {
        lock.lock(); let r = running; lock.unlock()
        if on && !r { start() } else if !on && r { stop() }
    }

    private func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            lock.lock(); state = "not supported"; lock.unlock()
            return
        }
        let c = ARWorldTrackingConfiguration()
        c.worldAlignment = .gravity
        c.isLightEstimationEnabled = false
        session.run(c, options: [.resetTracking, .removeExistingAnchors])
        lock.lock()
        running = true
        haveOrigin = false
        haveYaw = false
        state = "starting"
        lock.unlock()
    }

    private func stop() {
        session.pause()
        lock.lock()
        running = false
        haveOrigin = false
        haveYaw = false
        state = "off"
        lock.unlock()
    }

    /// Call when the user recenters: the current spot becomes the origin.
    func resetOrigin() {
        lock.lock(); haveOrigin = false; haveYaw = false; lock.unlock()
    }

    /// Head position in the gyro's render space, relative to the origin (metres).
    func position() -> SIMD3<Float> {
        lock.lock(); defer { lock.unlock() }
        guard running, haveOrigin else { return SIMD3<Float>(repeating: 0) }
        let d = posAR - originAR
        let c = cos(yawA), s = sin(yawA)
        return SIMD3(d.x * c + d.z * s, d.y, -d.x * s + d.z * c)
    }

    private func wrap(_ a: Float) -> Float { atan2(sin(a), cos(a)) }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t = frame.camera.transform
        let p = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let fAR = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        var st = "tracking"
        var good = false
        switch frame.camera.trackingState {
        case .normal: good = true
        case .limited: st = "limited"
        case .notAvailable: st = "not available"
        }
        let fCM = headForward?()

        lock.lock()
        state = st
        if good {
            if !haveOrigin { originAR = p; haveOrigin = true }
            posAR = p
            if let f = fCM, hypotf(fAR.x, fAR.z) > 0.3, hypotf(f.x, f.z) > 0.3 {
                let hAR = atan2(fAR.x, -fAR.z)
                let hCM = atan2(f.x, -f.z)
                let target = hAR - hCM
                if !haveYaw { yawA = target; haveYaw = true }
                else { yawA += wrap(target - yawA) * 0.03 }
            }
        }
        lock.unlock()
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        lock.lock(); state = "error"; lock.unlock()
    }
}
