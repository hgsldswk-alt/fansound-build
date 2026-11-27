import Foundation

struct Habits: Codable, Equatable {
    private(set) var qualifiedNights: [String] = []
    private(set) var listening: [String: TimeInterval] = [:]
    var milestoneOffered = false
    private(set) var reviewedMajorVersion: String?
    private(set) var lastReviewDate: Date?

    static func nightKey(at date: Date, calendar: Calendar = .current) -> String? {
        let hour = calendar.component(.hour, from: date)
        guard hour >= 18 || hour < 10 else { return nil }
        let day = calendar.startOfDay(for: date)
        let night = hour < 10 ? (calendar.date(byAdding: .day, value: -1, to: day) ?? day) : day
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: night)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func isDaytime(_ date: Date, calendar: Calendar = .current) -> Bool {
        (10..<18).contains(calendar.component(.hour, from: date))
    }

    mutating func record(_ seconds: TimeInterval, night: String) {
        guard seconds > 0, seconds.isFinite, !qualifiedNights.contains(night) else { return }
        listening[night, default: 0] += seconds
        if listening[night, default: 0] >= 30 * 60 {
            listening[night] = nil
            qualifiedNights = Array((qualifiedNights + [night]).sorted().suffix(7))
        }
        for key in listening.keys.sorted().dropLast(7) { listening[key] = nil }
    }

    var canOfferMilestone: Bool { qualifiedNights.count == 7 && !milestoneOffered }

    func canRequestReview(at now: Date, majorVersion: String) -> Bool {
        let recordedMajor = reviewedMajorVersion?.split(separator: ".").first.map(String.init)
        return qualifiedNights.count >= 3 && recordedMajor != majorVersion &&
        (lastReviewDate.map { now.timeIntervalSince($0) >= 90 * 86_400 } ?? true)
    }

    mutating func recordReview(at date: Date, majorVersion: String) {
        reviewedMajorVersion = majorVersion
        lastReviewDate = date
    }
}

struct LocalState: Codable {
    var preset = FanPreset()
    var lastPlayed: FanPreset?
    var lastPlayedAt: Date?
    var habits = Habits()
    var entitlement = Entitlement()

    private enum CodingKeys: String, CodingKey { case version, preset, lastPlayed, lastPlayedAt, habits, entitlement }

    init() {}

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        preset = (try? fields.decode(FanPreset.self, forKey: .preset)) ?? FanPreset()
        lastPlayed = try? fields.decode(FanPreset.self, forKey: .lastPlayed)
        lastPlayedAt = try? fields.decode(Date.self, forKey: .lastPlayedAt)
        habits = (try? fields.decode(Habits.self, forKey: .habits)) ?? Habits()
        entitlement = (try? fields.decode(Entitlement.self, forKey: .entitlement)) ?? Entitlement()
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(1, forKey: .version)
        try fields.encode(preset, forKey: .preset)
        try fields.encodeIfPresent(lastPlayed, forKey: .lastPlayed)
        try fields.encodeIfPresent(lastPlayedAt, forKey: .lastPlayedAt)
        try fields.encode(habits, forKey: .habits)
        try fields.encode(entitlement, forKey: .entitlement)
    }
}
