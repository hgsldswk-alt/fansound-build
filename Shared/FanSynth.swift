import Foundation

struct FanSynth {
    struct Profile {
        var pink: Float
        var brown: Float
        var motor: Float
        var tone: Double
        var drift: Double
        var flutter: Double

        init(_ sound: FanSound) {
            let values: (pink: Float, brown: Float, motor: Float, tone: Double, drift: Double, flutter: Double)
            switch sound {
            case .low:
                values = (0.25, 0.48, 0.041, 45, 0.19, 6.7)
            case .medium:
                values = (0.38, 0.42, 0.044, 51, 0.24, 9.2)
            case .high:
                values = (0.49, 0.36, 0.049, 58, 0.29, 12.4)
            }
            pink = values.pink
            brown = values.brown
            motor = values.motor
            tone = values.tone
            drift = values.drift
            flutter = values.flutter
        }

        mutating func move(toward target: Self, step: Float) {
            pink += (target.pink - pink) * step
            brown += (target.brown - brown) * step
            motor += (target.motor - motor) * step
            let weight = Double(step)
            tone += (target.tone - tone) * weight
            drift += (target.drift - drift) * weight
            flutter += (target.flutter - flutter) * weight
        }
    }

    private let phaseScale: Double
    private let smoothing: Float
    private let brownStep: Float
    private let pinkDecay: (Float, Float, Float)
    private var random: UInt32
    private var profile: Profile
    private var pink0: Float = 0
    private var pink1: Float = 0
    private var pink2: Float = 0
    private var brown: Float = 0
    private var gain: Float = 0
    private var motorPhase: Double = 0
    private var driftPhase: Double = 0
    private var flutterPhase: Double = 0

    init(sampleRate: Double, sound: FanSound = .low, seed: UInt32 = 0x93f6_8ac7) {
        let rate = sampleRate.isFinite && sampleRate >= 8_000 ? sampleRate : 48_000
        random = seed == 0 ? 1 : seed
        profile = Profile(sound)
        phaseScale = 2 * .pi / rate
        smoothing = Float(1 - exp(-1 / (0.045 * rate)))
        brownStep = Float(1 - exp(-2 * .pi * 95 / rate))
        pinkDecay = (Float(pow(0.99765, 48_000 / rate)),
                     Float(pow(0.96300, 48_000 / rate)),
                     Float(pow(0.57000, 48_000 / rate)))
    }

    mutating func sample(profile target: Profile, gain targetGain: Float, fade: Float) -> Float {
        profile.move(toward: target, step: smoothing)
        gain += (targetGain - gain) * smoothing
        random ^= random << 13
        random ^= random >> 17
        random ^= random << 5
        let white = Float(Int32(bitPattern: random)) / 2_147_483_648
        pink0 = pinkDecay.0 * pink0 + (1 - pinkDecay.0) * 42 * white
        pink1 = pinkDecay.1 * pink1 + (1 - pinkDecay.1) * 8 * white
        pink2 = pinkDecay.2 * pink2 + (1 - pinkDecay.2) * 2.4 * white
        let pink = (pink0 + pink1 + pink2 + 0.55 * white) * 0.12
        brown += (white - brown) * brownStep
        let airflow = 1 + 0.075 * Float(sin(driftPhase)) + 0.028 * Float(sin(flutterPhase))
        let motor = profile.motor * Float(sin(motorPhase) + 0.38 * sin(2 * motorPhase))
        motorPhase = Self.advance(motorPhase, by: phaseScale * profile.tone)
        driftPhase = Self.advance(driftPhase, by: phaseScale * profile.drift)
        flutterPhase = Self.advance(flutterPhase, by: phaseScale * profile.flutter)
        let sample = (airflow * (profile.pink * pink + profile.brown * brown) + motor) * gain * fade
        return max(-0.95, min(0.95, sample))
    }

    private static func advance(_ phase: Double, by step: Double) -> Double {
        let next = phase + step
        return next >= 2 * .pi ? next - 2 * .pi : next
    }
}
