import Foundation

struct Entitlement: Codable, Equatable {
    static let trialDuration: TimeInterval = 30 * 24 * 60 * 60

    var firstOpen = Date()
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false
    var latestProSignedAt: Date?

    init(firstOpen: Date = Date(), proStartedAt: Date? = nil) {
        self.firstOpen = firstOpen
        self.proStartedAt = proStartedAt
    }

    private enum CodingKeys: String, CodingKey {
        case firstOpen, proStartedAt, trialClaimedAt, purchasedPro, latestProSignedAt
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        proStartedAt = try? fields.decode(Date.self, forKey: .proStartedAt)
        trialClaimedAt = try? fields.decode(Date.self, forKey: .trialClaimedAt)
        firstOpen = (try? fields.decode(Date.self, forKey: .firstOpen)) ?? proStartedAt ?? trialClaimedAt ?? Date()
        purchasedPro = (try? fields.decode(Bool.self, forKey: .purchasedPro)) ?? false
        latestProSignedAt = try? fields.decode(Date.self, forKey: .latestProSignedAt)
    }

    var trialStart: Date {
        let localStart = proStartedAt ?? firstOpen
        return min(localStart, trialClaimedAt ?? localStart)
    }

    var trialEnd: Date { trialStart.addingTimeInterval(Self.trialDuration) }

    mutating func beginPaidPeriod(at date: Date) {
        if proStartedAt == nil { proStartedAt = date }
    }

    mutating func recordTrial(originalPurchaseDate date: Date) {
        trialClaimedAt = min(trialClaimedAt ?? date, date)
    }

    mutating func recordPro(revoked: Bool, signedAt: Date) {
        if let latestProSignedAt, signedAt < latestProSignedAt { return }
        latestProSignedAt = signedAt
        purchasedPro = !revoked
    }

    func hasPro(at date: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || (date >= trialStart && date < trialEnd)
    }

    func trialDaysRemaining(at date: Date) -> Int {
        let remaining = trialEnd.timeIntervalSince(date)
        guard remaining.isFinite else { return 0 }
        return Int(ceil(max(0, min(Self.trialDuration, remaining)) / 86_400))
    }
}
