import AVFoundation
import Combine
import Foundation
import MediaPlayer
import StoreKit

@MainActor
final class FanModel: ObservableObject {
    enum Sheet: Equatable { case settings, more, share, milestone, importCode, paywall, privacy }
    enum Result: Equatable { case ready, ended, failed }

    @Published private(set) var state: LocalState
    @Published private(set) var session: PlaybackSession?
    @Published private(set) var clock = PlaybackClock.now
    @Published private(set) var result = Result.ready
    @Published private(set) var showMilestone = false
    @Published private(set) var permissionDate: Date
    @Published var sheet: Sheet?

    let purchases = Purchases()
    private let audio = FanAudio()
    private let notifications = NotificationCenter.default
    private let defaults: UserDefaults
    private static let stateKey = "fan.localState"
    private var observers: [NSObjectProtocol] = []
    private var ticker: Task<Void, Never>?
    private var listeningSince: TimeInterval?
    private var interruptionID: UUID?
    private var lastOutput: [String] = []
    private var remoteTokens: [(MPRemoteCommand, Any)] = []
    private var offeredThisVisit = false
    private var active = false

    init() {
        let args = Launch.testArguments
        let defaults = Launch.isUITesting ? UserDefaults(suiteName: "com.hgsldswk.fansound.ui")! : .standard
        self.defaults = defaults
        if args.contains("-reset") { defaults.removeObject(forKey: Self.stateKey) }

        let now = Date()
        var loaded = defaults.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(LocalState.self, from: $0) } ?? LocalState()
        if !Launch.isFree { loaded.entitlement.beginPaidPeriod(at: now) }
        if args.contains("-expired") {
            loaded.entitlement = Entitlement(firstOpen: now, proStartedAt: now.addingTimeInterval(-31 * 86_400))
            loaded.preset = FanPreset(sound: .high, timer: .minutes90)
            loaded.lastPlayed = loaded.preset
            loaded.lastPlayedAt = now
        }
        if Launch.value("-shot") == "resume" {
            loaded.lastPlayed = loaded.preset
            loaded.lastPlayedAt = Calendar.current.date(byAdding: .day, value: -1, to: now)
        }
        if args.contains("-milestone") {
            for day in 1...7 { loaded.habits.record(1800, night: String(format: "2026-11-%02d", day)) }
        }
        state = loaded
        permissionDate = now
        if args.contains("-paywall") && !Launch.isFree { sheet = .paywall }
        save()
    }

    deinit {
        ticker?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for (command, token) in remoteTokens { command.removeTarget(token) }
    }

    var hasPro: Bool { state.entitlement.hasPro(at: permissionDate) }
    var purchaseStatus: String {
        if state.entitlement.purchasedPro { return L.t("paywall.unlocked") }
        if hasPro {
            let days = state.entitlement.trialDaysRemaining(at: permissionDate)
            return days == 1 ? L.t("paywall.oneDay") : L.f("paywall.days", days)
        }
        return L.t("paywall.expired")
    }

    var fallback: Bool { session == nil && state.preset != allowedPreset }
    var shownPreset: FanPreset { session?.preset ?? allowedPreset }
    var sharePreset: FanPreset { session == nil ? state.preset : state.lastPlayed ?? state.preset }
    var remaining: TimeInterval? { session?.remaining(at: clock) }
    var fading: Bool { session?.isPlaying == true && remaining.map { $0 <= PlaybackSession.fadeDuration } == true }

    var actionTitle: String {
        if let session {
            switch session.pause {
            case nil: return L.t("home.stop")
            case .failure: return L.t("home.retry")
            default: return L.t("home.resume")
            }
        }
        if result == .failed { return L.t("home.retry") }
        if !fallback, state.lastPlayed == state.preset, let date = state.lastPlayedAt {
            return Calendar.current.isDateInYesterday(date) ? L.t("home.yesterday") : L.t("home.last")
        }
        return L.t("home.play")
    }

    private var allowedPreset: FanPreset { state.preset.allowed(hasPro: hasPro) }

    func connect() {
        guard !Launch.isUITesting, observers.isEmpty else { return }
        observe(AVAudioSession.interruptionNotification) { [weak self] in self?.handleInterruption($0) }
        observe(AVAudioSession.routeChangeNotification) { [weak self] in self?.handleRouteChange($0) }
        observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
            guard let self, self.session != nil else { return }
            self.pause(.failure)
        }
        observe(.AVAudioEngineConfigurationChange) { [weak self] note in self?.handleEngineChange(note) }
        purchases.observe(deliver: { [weak self] in self?.applyTransaction($0) },
                          onRefresh: { [weak self] in self?.permissionDate = Date() })
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor (Notification) -> Void) {
        let token = notifications.addObserver(forName: name, object: nil, queue: nil) { note in
            Task { @MainActor in action(note) }
        }
        observers.append(token)
    }

    func sceneActive(_ isActive: Bool) {
        if isActive && !active { offeredThisVisit = showMilestone }
        active = isActive
        tick()
        if !isActive { save() }
    }

    private var reviewVersion: String {
        L.bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
    }

    var reviewedThisVersion: Bool {
        guard let previous = state.habits.reviewedMajorVersion else { return false }
        return previous == reviewVersion || previous == String(reviewVersion.split(separator: ".").first ?? "1")
    }

    func markReviewRequested(at now: Date = Date()) {
        state.habits.recordReview(at: now, majorVersion: reviewVersion)
        save()
    }

    func offerReview(now: Date = Date(), request: () -> Void) {
        guard active, session == nil, result != .failed, sheet == nil,
              Habits.isDaytime(now) || Launch.testArguments.contains("-milestone")
        else { return }

        if state.habits.canOfferMilestone {
            offeredThisVisit = true
            showMilestone = true
            state.habits.milestoneOffered = true
            save()
            return
        }

        let major = String(reviewVersion.split(separator: ".").first ?? "1")
        guard !Launch.isUITesting, !offeredThisVisit,
              state.habits.canRequestReview(at: now, majorVersion: major), CoreReview.shared.attempt(request) else { return }
        markReviewRequested(at: now)
    }

    func dismissMilestone() { showMilestone = false }

    func primaryAction() {
        tick()
        if session?.isPlaying == true {
            stop()
        } else if session != nil {
            resume()
        } else {
            start(state.preset)
        }
    }

    func cancelPausedSession() {
        guard session?.pause != nil else { return }
        stop()
    }

    func playFromShortcut() -> Bool {
        permissionDate = Date()
        guard hasPro else {
            sheet = .paywall
            return false
        }
        tick()
        if session?.isPlaying == true { return true }
        if session != nil {
            resume()
        } else {
            start(state.lastPlayed ?? FanPreset(), applyToPending: true)
        }
        return session?.isPlaying == true
    }

    func installScreenshotState() {
        guard let shot = Launch.value("-shot"), session == nil else { return }
        switch shot {
        case "timer":
            state.preset.timer = .minutes60
            start(state.preset, elapsed: 18)
        case "overnight":
            start(state.preset)
        case "gears":
            state.preset.sound = .medium
        case "share":
            state.preset.timer = .minutes60
            sheet = .share
        default:
            break
        }
    }

    private func start(_ desired: FanPreset, applyToPending: Bool = false, elapsed: TimeInterval = 0) {
        let now = PlaybackClock.now
        let date = Date()
        permissionDate = date
        let actual = desired.allowed(hasPro: hasPro)
        let testShort = Launch.testArguments.contains("-short-timer") && actual.timer == .minutes30
        let started = now - (testShort ? 1793 : elapsed)
        let new = PlaybackSession(preset: actual, now: started, night: Habits.nightKey(at: date))
        do {
            if !Launch.isUITesting { try audio.start(new) }
            session = new
            result = .ready
            clock = now
            if applyToPending { state.preset = desired }
            state.lastPlayed = desired
            state.lastPlayedAt = date
            listeningSince = audible(new) ? now : nil
            corePlaybackStarted = audible(new) ? now : nil
            lastOutput = outputSignature
            save()
            updateSystemPlayback(install: true)
            startTicker()
        } catch {
            result = .failed
        }
    }

    private func resume(expectedOutput: [String]? = nil) {
        guard var current = session else { return }
        let now = PlaybackClock.now
        if current.hasEnded(at: now) {
            stop(ended: true, now: now)
            return
        }
        guard current.resume(at: now) else { return }
        interruptionID = nil
        do {
            if !Launch.isUITesting { try audio.start(current, expectedOutput: expectedOutput) }
            session = current
            listeningSince = audible(current) ? now : nil
            corePlaybackStarted = audible(current) ? now : nil
            lastOutput = outputSignature
            result = .ready
            clock = now
            updateSystemPlayback(install: true)
            startTicker()
        } catch FanAudio.AudioFailure.outputChanged {
            pause(.routeLost)
        } catch {
            pause(.failure)
        }
    }

    private func pause(_ reason: PlaybackSession.Pause, deactivate: Bool = true) {
        guard var current = session else { return }
        let now = PlaybackClock.now
        if current.hasEnded(at: now) {
            stop(ended: true, now: now)
            return
        }
        accountListening(at: now)
        current.suspend(reason)
        corePlaybackStarted = nil
        session = current
        listeningSince = nil
        clock = now
        if case .interruption = current.pause {} else { interruptionID = nil }
        audio.stop(deactivate: deactivate)
        save()
        updateSystemPlayback()
        startTicker()
    }

    private var corePlaybackStarted: TimeInterval?

    private func stop(ended: Bool = false, now: TimeInterval = PlaybackClock.now) {
        let played = (corePlaybackStarted.map { now - $0 >= 30 } ?? false) && session?.isPlaying == true
        corePlaybackStarted = nil
        accountListening(at: now)
        audio.stop()
        session = nil
        listeningSince = nil
        interruptionID = nil
        result = ended ? .ended : .ready
        clock = now
        ticker?.cancel()
        ticker = nil
        save()
        if played && session == nil { CoreReview.shared.record() }
        updateSystemPlayback()
    }

    func selectSound(_ sound: FanSound) {
        tick()
        let staysOnCurrent = session?.preset.sound == sound
        guard !sound.isPro || hasPro else {
            if !staysOnCurrent { sheet = .paywall }
            return
        }
        edit(\.sound, to: sound, updatesTrack: true)
    }

    func selectTimer(_ timer: FanTimer) {
        tick()
        guard !timer.isPro || hasPro else {
            if session?.preset.timer != timer { sheet = .paywall }
            return
        }
        edit(\.timer, to: timer, resetTimer: timer)
        sheet = nil
    }

    func changeGain(_ gain: Double) {
        tick()
        edit(\.gain, to: FanPreset.validGain(gain))
    }

    private func edit<Value>(_ key: WritableKeyPath<FanPreset, Value>, to value: Value,
                             resetTimer: FanTimer? = nil, updatesTrack: Bool = false) {
        state.preset[keyPath: key] = value
        if var current = session {
            let now = PlaybackClock.now
            accountListening(at: now)
            current.preset[keyPath: key] = value
            if let resetTimer { current.changeTimer(resetTimer, at: now) }
            session = current
            listeningSince = audible(current) ? now : nil
            state.lastPlayed?[keyPath: key] = value
            audio.update(current)
            clock = now
            if updatesTrack { updateSystemPlayback() }
            startTicker()
        } else {
            result = .ready
        }
        save()
    }

    @discardableResult
    func importCode(_ text: String) -> Bool {
        guard let code = PresetCode.decode(text) else { return false }
        state.preset = code.applying(to: state.preset)
        if session == nil { result = .ready }
        save()
        sheet = nil
        return true
    }

    private func audible(_ session: PlaybackSession) -> Bool {
        session.isPlaying && session.preset.gain > 0 && session.night != nil
    }

    private func accountListening(at now: TimeInterval) {
        guard let beginning = listeningSince, let current = session, let night = current.night else { return }
        let end = min(now, current.deadline ?? now)
        state.habits.record(end - beginning, night: night)
        listeningSince = end
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let now = PlaybackClock.now
        let date = Date()
        if abs(date.timeIntervalSince(permissionDate)) >= 1 { permissionDate = date }
        guard let current = session else { return }
        if current.hasEnded(at: now) {
            stop(ended: true, now: now)
            return
        }
        if abs(now - clock) >= 1 && current.deadline != nil { clock = now }
        if let started = listeningSince, now - started >= 30 {
            accountListening(at: now)
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.stateKey)
        }
    }

    private func applyTransaction(_ transaction: StoreKit.Transaction) {
        if transaction.productID == purchases.proID {
            state.entitlement.recordPro(
                revoked: transaction.revocationDate != nil, signedAt: transaction.signedDate
            )
        } else if transaction.productID == purchases.trialID, transaction.revocationDate == nil {
            state.entitlement.recordTrial(originalPurchaseDate: transaction.originalPurchaseDate)
        } else {
            return
        }
        permissionDate = Date()
        save()
    }
}

private extension FanModel {
    var outputSignature: [String] {
        guard !Launch.isUITesting else { return [] }
        return FanAudio.signature(AVAudioSession.sharedInstance().currentRoute)
    }

    func handleInterruption(_ note: Notification) {
        guard let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        tick()
        guard let current = session else { return }
        switch type {
        case .began:
            guard current.isPlaying else { return }
            interruptionID = current.id
            pause(.interruption(output: lastOutput), deactivate: false)
        case .ended:
            let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let allowed = AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)
            let output = outputSignature
            if current.canResumeAfterInterruption(id: interruptionID, allowed: allowed,
                                                  output: output, now: PlaybackClock.now) {
                resume(expectedOutput: output)
            } else if case .interruption(let previous) = current.pause {
                pause(output == previous ? .manual : .routeLost)
            }
        @unknown default:
            break
        }
    }

    func handleRouteChange(_ note: Notification) {
        guard let current = session,
              let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        let output = outputSignature
        if reason == .oldDeviceUnavailable {
            let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            if previous == nil || previous.map({ FanAudio.signature($0) }) == lastOutput || output != lastOutput {
                pause(.routeLost)
            }
        } else if current.isPlaying, !output.isEmpty {
            lastOutput = output
        }
    }

    func handleEngineChange(_ note: Notification) {
        guard let current = session, current.isPlaying, let engine = note.object as? AVAudioEngine,
              audio.owns(engine) else { return }
        let id = current.id
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            self.tick()
            guard let session = self.session, session.id == id, session.isPlaying, !self.audio.running else { return }
            let output = self.outputSignature
            guard !output.isEmpty, output == self.lastOutput else {
                self.pause(.routeLost)
                return
            }
            do {
                try self.audio.start(session, expectedOutput: output)
            } catch FanAudio.AudioFailure.outputChanged {
                self.pause(.routeLost)
            } catch {
                self.pause(.failure)
            }
        }
    }

    func updateSystemPlayback(install: Bool = false) {
        guard !Launch.isUITesting else { return }
        if install && remoteTokens.isEmpty { installRemoteCommands() }
        guard !remoteTokens.isEmpty else { return }
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = session?.pause != nil
        commands.pauseCommand.isEnabled = session?.isPlaying == true
        commands.togglePlayPauseCommand.isEnabled = session != nil
        if let session {
            center.nowPlayingInfo = [
                MPMediaItemPropertyTitle: session.preset.sound.name,
                MPMediaItemPropertyArtist: L.t("home.title"),
                MPNowPlayingInfoPropertyPlaybackRate: session.isPlaying ? 1.0 : 0.0,
                MPNowPlayingInfoPropertyIsLiveStream: true,
            ]
        } else {
            center.nowPlayingInfo = nil
        }
    }

    func installRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        let actions: [(MPRemoteCommand, Bool?)] = [
            (commands.playCommand, true),
            (commands.pauseCommand, false),
            (commands.togglePlayPauseCommand, nil),
        ]
        for (command, play) in actions {
            let token = command.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.tick()
                    guard let session = self.session else { return }
                    if play ?? !session.isPlaying {
                        if !session.isPlaying { self.resume() }
                    } else if session.isPlaying {
                        self.pause(.manual)
                    }
                }
                return .success
            }
            remoteTokens.append((command, token))
        }
        commands.changePlaybackPositionCommand.isEnabled = false
    }
}
