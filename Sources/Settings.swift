import Foundation

/// Lens geometry for the phone in its housing. Defaults are approximate Cardboard v1 numbers.
struct LensSettings: Codable, Equatable {
    var ipdMM: Float = 64
    var lensSeparationMM: Float = 60
    var screenToLensMM: Float = 42
    var k1: Float = 0.441
    var k2: Float = 0.156
}

/// Everything else that lives on the phone.
struct DisplaySettings: Codable, Equatable {
    var sharpen: Float = 0.3        // 0 = off
    var blackFrames: Bool = false   // every other refresh is black (less blur, more flicker)
    var brightness: Float = 1.0
    var statusMode: Int = 0         // 0 auto, 1 always, 2 off
    var cameraTracking: Bool = false
}

final class SettingsStore {
    static let shared = SettingsStore()
    private let d = UserDefaults.standard

    var slot: Int {
        get { min(max(d.integer(forKey: "slot"), 0), 2) }
        set { d.set(newValue, forKey: "slot") }
    }

    func load(_ slot: Int) -> LensSettings {
        if let data = d.data(forKey: "preset\(slot)"),
           let s = try? JSONDecoder().decode(LensSettings.self, from: data) { return s }
        return LensSettings()
    }

    func save(_ s: LensSettings, slot: Int) {
        if let data = try? JSONEncoder().encode(s) { d.set(data, forKey: "preset\(slot)") }
    }

    func loadDisplay() -> DisplaySettings {
        if let data = d.data(forKey: "display"),
           let s = try? JSONDecoder().decode(DisplaySettings.self, from: data) { return s }
        return DisplaySettings()
    }

    func saveDisplay(_ s: DisplaySettings) {
        if let data = try? JSONEncoder().encode(s) { d.set(data, forKey: "display") }
    }
}
