import CoreImage
import Foundation
import XCTest

final class FanSynthTests: XCTestCase {
    func testSynthGeneratesDifferentNonSilentBoundedSignalsForAllGears() {
        var output: [[Float]] = []
        for gear in FanSound.allCases {
            var synth = FanSynth(sampleRate: 48_000, sound: gear)
            let profile = FanSynth.Profile(gear)
            let initial = synth.sample(profile: profile, gain: 1, fade: 1)
            let samples = (0..<24_000).map { _ in synth.sample(profile: profile, gain: 1, fade: 1) }
            XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) < 1 })
            let rms = sqrt(samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(samples.count))
            XCTAssertGreaterThan(rms, 0.01, gear.rawValue)
            XCTAssertLessThan(abs(initial), 0.01)
            XCTAssertEqual(synth.sample(profile: profile, gain: 1, fade: 0), 0)
            output.append(samples)
        }
        XCTAssertNotEqual(output[0], output[1])
        XCTAssertNotEqual(output[1], output[2])
    }

    func testSwitchAndVolumeRiseDoNotJumpAtSampleBoundary() {
        let low = FanSynth.Profile(.low)
        let high = FanSynth.Profile(.high)
        var before = FanSynth(sampleRate: 44_100)
        for _ in 0..<4000 { _ = before.sample(profile: low, gain: 0.35, fade: 1) }
        var unchanged = before
        XCTAssertEqual(before.sample(profile: high, gain: 1, fade: 1),
                       unchanged.sample(profile: low, gain: 0.35, fade: 1), accuracy: 0.001)
    }
}

final class PlaybackSessionTests: XCTestCase {
    func testTimerCountsElapsedAndFadesDuringFinalTenSeconds() {
        let start: TimeInterval = 3_000_000
        let session = PlaybackSession(preset: FanPreset(timer: .minutes30), now: start)
        let deadline = start + 1800
        XCTAssertEqual(session.deadline, deadline)
        XCTAssertEqual(session.remaining(at: deadline - 11), 11)
        XCTAssertEqual(PlaybackSession.fadeMultiplier(deadline: deadline, now: deadline - 10), 1)
        XCTAssertEqual(PlaybackSession.fadeMultiplier(deadline: deadline, now: deadline - 4), 0.4, accuracy: 0.001)
        XCTAssertEqual(PlaybackSession.fadeMultiplier(deadline: deadline, now: deadline), 0)
        XCTAssertTrue(session.hasEnded(at: deadline))
        XCTAssertEqual(session.remaining(at: deadline + 60), 0)
    }

    func testChangingGearLeavesDeadlineWhileTimerChangeResetsOrCancelsFade() {
        var session = PlaybackSession(preset: FanPreset(timer: .minutes30), now: 0)
        session.preset.sound = .high
        XCTAssertEqual(session.deadline, 1800)
        session.changeTimer(.minutes60, at: 1799)
        XCTAssertEqual(session.remaining(at: 1799), 3600)
        XCTAssertEqual(PlaybackSession.fadeMultiplier(deadline: session.deadline, now: 1799), 1)
        session.changeTimer(.overnight, at: 1799)
        XCTAssertNil(session.deadline)
        XCTAssertFalse(session.hasEnded(at: 500_000))
        XCTAssertEqual(PlaybackSession.fadeMultiplier(deadline: nil, now: 1800), 1)
    }

    func testPausedClockAndInterruptionRecoveryHonorSessionAndOutput() {
        var session = PlaybackSession(preset: FanPreset(timer: .minutes30), now: 0)
        session.suspend(.interruption(output: ["headphones"]))
        XCTAssertTrue(session.canResumeAfterInterruption(id: session.id, allowed: true, output: ["headphones"], now: 120))
        XCTAssertFalse(session.canResumeAfterInterruption(id: UUID(), allowed: true, output: ["headphones"], now: 120))
        XCTAssertFalse(session.canResumeAfterInterruption(id: session.id, allowed: false, output: ["headphones"], now: 120))
        XCTAssertFalse(session.canResumeAfterInterruption(id: session.id, allowed: true, output: ["speaker"], now: 120))
        XCTAssertFalse(session.canResumeAfterInterruption(id: session.id, allowed: true, output: ["headphones"], now: 1800))
        XCTAssertEqual(session.remaining(at: 1792), 8)
        XCTAssertFalse(session.resume(at: 1800))
        session.suspend(.routeLost)
        session.suspend(.interruption(output: ["speaker"]))
        XCTAssertEqual(session.pause, .routeLost)
        XCTAssertFalse(session.canResumeAfterInterruption(id: session.id, allowed: true, output: ["speaker"], now: 120))
        XCTAssertTrue(session.resume(at: 120))
        XCTAssertTrue(session.isPlaying)
        XCTAssertFalse(session.resume(at: 121))
    }
}

final class EntitlementTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstPaidLaunchStartsTrialForExistingFreeUserAndExpiresAtDayThirty() {
        var entitlement = Entitlement(firstOpen: start.addingTimeInterval(-90 * 86_400))
        XCTAssertTrue(entitlement.hasPro(at: start, free: true))
        XCTAssertFalse(entitlement.hasPro(at: start, free: false))
        entitlement.beginPaidPeriod(at: start)
        entitlement.beginPaidPeriod(at: start.addingTimeInterval(86_400))
        XCTAssertEqual(entitlement.trialStart, start)
        XCTAssertTrue(entitlement.hasPro(at: start, free: false))
        XCTAssertTrue(entitlement.hasPro(at: entitlement.trialEnd.addingTimeInterval(-1), free: false))
        XCTAssertFalse(entitlement.hasPro(at: entitlement.trialEnd, free: false))
    }

    func testVerifiedTrialRestoresEarlierStartAndLaterClaimCannotExtendIt() {
        var entitlement = Entitlement(firstOpen: start, proStartedAt: start)
        entitlement.recordTrial(originalPurchaseDate: start.addingTimeInterval(86_400))
        XCTAssertEqual(entitlement.trialStart, start)
        let prior = start.addingTimeInterval(-60 * 86_400)
        entitlement.recordTrial(originalPurchaseDate: prior)
        XCTAssertEqual(entitlement.trialStart, prior)
        XCTAssertFalse(entitlement.hasPro(at: start, free: false))
    }

    func testBuyoutPersistsOfflineAndNewerRevocationWinsOverOldReceipt() throws {
        var entitlement = Entitlement(firstOpen: start)
        entitlement.recordPro(revoked: false, signedAt: start)
        let later = entitlement.trialEnd.addingTimeInterval(86_400)
        let data = try JSONEncoder().encode(entitlement)
        entitlement = try JSONDecoder().decode(Entitlement.self, from: data)
        XCTAssertTrue(entitlement.hasPro(at: later, free: false))
        entitlement.recordPro(revoked: true, signedAt: later)
        entitlement.recordPro(revoked: false, signedAt: start)
        XCTAssertFalse(entitlement.hasPro(at: later, free: false))
    }

    func testExpiryResolvesOnlyFutureSessionsWithoutOverwritingOriginal() {
        let original = FanPreset(sound: .high, timer: .minutes90, gain: 0.4)
        let playing = PlaybackSession(preset: original.allowed(hasPro: true), now: 0)
        let next = original.allowed(hasPro: false)
        XCTAssertEqual(playing.preset, original)
        XCTAssertEqual(next, FanPreset(sound: .low, timer: .minutes60, gain: 0.4))
        XCTAssertEqual(original.allowed(hasPro: true), original)
        XCTAssertEqual(FanTimer.minutes15.freeFallback, .minutes30)
        XCTAssertEqual(FanTimer.minutes45.freeFallback, .minutes30)
    }
}

final class PresetAndSharingTests: XCTestCase {
    func testDefaultAndPartialMigrationKeepValidFields() throws {
        XCTAssertEqual(FanPreset(), FanPreset(sound: .low, timer: .overnight, gain: 0.35))
        let legacy = Data(#"{"preset":{"soundID":"future","timerMinutes":45,"gain":0.42}}"#.utf8)
        let state = try JSONDecoder().decode(LocalState.self, from: legacy)
        XCTAssertEqual(state.preset, FanPreset(sound: .low, timer: .minutes45, gain: 0.42))
        let encoded = try JSONEncoder().encode(state)
        let roundtrip = try JSONDecoder().decode(LocalState.self, from: encoded)
        XCTAssertEqual(roundtrip.preset, state.preset)
    }

    func testPresetCodeRoundTripLeavesReceiverGainAndRejectsInvalidFields() throws {
        let sender = FanPreset(sound: .medium, timer: .minutes45, gain: 0.8)
        let text = try XCTUnwrap(PresetCode(sender).encode())
        let result = try XCTUnwrap(PresetCode.decode("\n" + text + "\n"))
        XCTAssertEqual(result.applying(to: FanPreset(gain: 0.1)), FanPreset(sound: .medium, timer: .minutes45, gain: 0.1))
        XCTAssertNil(PresetCode.decode("FAN1.invalid?"))
        XCTAssertNil(PresetCode.decode("FAN2." + text.dropFirst(5)))
        XCTAssertNil(PresetCode.decode(String(repeating: " ", count: 513) + text))
        for payload in [#"{"version":2,"soundID":"low","timerMinutes":30}"#,
                        #"{"version":1,"soundID":"unknown","timerMinutes":30}"#,
                        #"{"version":1,"soundID":"low","timerMinutes":22}"#] {
            let base64 = Data(payload.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            XCTAssertNil(PresetCode.decode("FAN1." + base64))
        }
    }

    func testQRCodeReadsBackDownloadURL() throws {
        let url = Launch.downloadURL
        let image = try XCTUnwrap(DownloadQR.image(for: url))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let payloads = detector.features(in: CIImage(cgImage: image))
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(payloads, [url.absoluteString])
    }

    func testAllThreeTranslationsShipInSharedResourceBundle() throws {
        for language in ["en", "zh-Hans", "zh-Hant"] {
            let url = try XCTUnwrap(L.bundle.url(forResource: language, withExtension: "lproj"))
            let bundle = try XCTUnwrap(Bundle(url: url))
            let low = NSLocalizedString("sound.low", bundle: bundle, comment: "")
            XCTAssertFalse(low.isEmpty)
            XCTAssertNotEqual(low, "sound.low")
        }
    }
}

final class HabitsTests: XCTestCase {
    func testMidnightBelongsToPriorNightAndNightProgressDeduplicates() throws {
        let formatter = ISO8601DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        let evening = try XCTUnwrap(formatter.date(from: "2026-11-20T21:00:00+09:00"))
        let morning = try XCTUnwrap(formatter.date(from: "2026-11-21T09:59:00+09:00"))
        let daytime = try XCTUnwrap(formatter.date(from: "2026-11-21T10:00:00+09:00"))
        let night = try XCTUnwrap(Habits.nightKey(at: evening, calendar: calendar))
        XCTAssertEqual(night, Habits.nightKey(at: morning, calendar: calendar))
        XCTAssertNil(Habits.nightKey(at: daytime, calendar: calendar))
        var habits = Habits()
        habits.record(1799, night: night)
        XCTAssertTrue(habits.qualifiedNights.isEmpty)
        habits.record(1, night: night)
        habits.record(4500, night: night)
        XCTAssertEqual(habits.qualifiedNights, [night])
    }

    func testCoreReviewRequiresThreeActionsOnTwoLocalDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23)))
        let nextDay = firstDay.addingTimeInterval(2 * 3600)
        let empty = try JSONDecoder().decode(CoreReviewProgress.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isEligible)
        var progress = CoreReviewProgress.recording(empty, at: firstDay, calendar: calendar)
        var twoDays = progress
        twoDays.record(at: nextDay, calendar: calendar)
        XCTAssertFalse(twoDays.isEligible)
        progress.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(progress.isEligible)

        var sameDay = progress
        sameDay.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(sameDay.isEligible)

        let data = try JSONEncoder().encode(progress)
        progress = try JSONDecoder().decode(CoreReviewProgress.self, from: data)
        progress.record(at: nextDay, calendar: calendar)
        XCTAssertTrue(progress.isEligible)
    }

    func testMilestoneAndReviewRequireQualifiedNightsAndCooldown() {
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        var habits = Habits()
        XCTAssertFalse(habits.canRequestReview(at: today, majorVersion: "1"))
        for day in 1...9 {
            habits.record(1800, night: String(format: "2026-11-%02d", day))
        }
        XCTAssertEqual(habits.qualifiedNights.count, 7)
        XCTAssertTrue(habits.canOfferMilestone)
        habits.milestoneOffered = true
        XCTAssertFalse(habits.canOfferMilestone)
        XCTAssertTrue(habits.canRequestReview(at: today, majorVersion: "1"))
        habits.recordReview(at: today, majorVersion: "1")
        XCTAssertFalse(habits.canRequestReview(at: today.addingTimeInterval(90 * 86_400), majorVersion: "1"))
        XCTAssertFalse(habits.canRequestReview(at: today.addingTimeInterval(89 * 86_400), majorVersion: "2"))
        XCTAssertTrue(habits.canRequestReview(at: today.addingTimeInterval(90 * 86_400), majorVersion: "2"))
    }
}
