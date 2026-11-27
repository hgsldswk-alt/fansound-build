import Foundation

enum FanSound: String, CaseIterable, Codable, Hashable {
    case low, medium, high

    var name: String { L.t("sound." + rawValue) }
    var isPro: Bool { self != .low }
}

enum FanTimer: Int, CaseIterable, Codable, Hashable {
    case overnight = 0
    case minutes15 = 15, minutes30 = 30, minutes45 = 45, minutes60 = 60, minutes90 = 90

    static let basic: [Self] = [.overnight, .minutes30, .minutes60]
    static let advanced: [Self] = [.minutes15, .minutes45, .minutes90]

    var isPro: Bool { Self.advanced.contains(self) }
    var seconds: TimeInterval? { self == .overnight ? nil : TimeInterval(rawValue * 60) }
    var name: String { self == .overnight ? L.t("timer.overnight") : L.f("timer.minutes", rawValue) }
    var shortName: String { self == .overnight ? name : L.f("timer.short", rawValue) }

    var freeFallback: Self {
        switch self {
        case .minutes15, .minutes45: return .minutes30
        case .minutes90: return .minutes60
        default: return self
        }
    }
}

struct FanPreset: Equatable, Codable {
    var sound: FanSound = .low
    var timer: FanTimer = .overnight
    var gain: Double = 0.35

    init(sound: FanSound = .low, timer: FanTimer = .overnight, gain: Double = 0.35) {
        self.sound = sound
        self.timer = timer
        self.gain = Self.validGain(gain)
    }

    private enum CodingKeys: String, CodingKey { case soundID, timerMinutes, gain }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        sound = (try? fields.decode(FanSound.self, forKey: .soundID)) ?? .low
        timer = (try? fields.decode(FanTimer.self, forKey: .timerMinutes)) ?? .overnight
        gain = Self.validGain((try? fields.decode(Double.self, forKey: .gain)) ?? 0.35)
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(sound, forKey: .soundID)
        try fields.encode(timer, forKey: .timerMinutes)
        try fields.encode(gain, forKey: .gain)
    }

    func allowed(hasPro: Bool) -> Self {
        hasPro ? self : Self(sound: .low, timer: timer.freeFallback, gain: gain)
    }

    static func validGain(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.35
    }
}

struct PresetCode: Codable, Equatable {
    let version: Int
    let soundID: FanSound
    let timerMinutes: FanTimer

    init(_ preset: FanPreset) {
        version = 1
        soundID = preset.sound
        timerMinutes = preset.timer
    }

    func encode() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return "FAN1." + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Self? {
        guard text.utf8.prefix(513).count <= 512 else { return nil }
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix("FAN1.") else { return nil }
        let payload = code.dropFirst(5)
        let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8
        guard !payload.isEmpty, payload.utf8.allSatisfy(allowed.contains) else { return nil }
        var base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let result = try? JSONDecoder().decode(Self.self, from: data),
              result.version == 1 else { return nil }
        return result
    }

    func applying(to preset: FanPreset) -> FanPreset {
        FanPreset(sound: soundID, timer: timerMinutes, gain: preset.gain)
    }
}
