import AppIntents
import StoreKit
import SwiftUI

@main
@MainActor
struct FanSoundApp: App {
    @StateObject private var model = FanModel.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if Launch.testArguments.contains("-large-text") {
                    PlayerView(model: model).dynamicTypeSize(.accessibility3)
                } else {
                    PlayerView(model: model)
                }
            }
            .preferredColorScheme(.dark)
            .tint(Design.accent)
        }
    }
}

@MainActor
extension FanModel {
    static let shared = FanModel()
}

struct PlayLastFanPreset: AppIntent {
    static let title: LocalizedStringResource = "shortcut.title"
    static let description = IntentDescription("shortcut.description")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = FanModel.shared
        model.connect()
        let played = model.playFromShortcut()
        let key = played ? "shortcut.playing" : (model.hasPro ? "shortcut.failed" : "shortcut.locked")
        return .result(dialog: IntentDialog(stringLiteral: L.t(key)))
    }
}

@MainActor
struct PlayerView: View {
    @ObservedObject var model: FanModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var focusSize = 64.0
    @State private var installed = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    header
                    hero
                    Button(model.actionTitle) { model.primaryAction() }
                        .buttonStyle(FanButtonStyle(highlighted: model.session?.isPlaying != true))
                        .accessibilityIdentifier("home.play")
                    if model.session?.pause != nil {
                        Button(L.t("home.stop")) { model.cancelPausedSession() }
                            .buttonStyle(QuietButtonStyle())
                            .accessibilityIdentifier("home.stopPaused")
                    }

                    controls.padding(.top, 24)
                    Spacer(minLength: 16)
                    if model.showMilestone { milestone }
                    Divider().overlay(Design.line)
                    Button(L.t("share.title")) { model.sheet = .share }
                        .buttonStyle(QuietButtonStyle(fullWidth: true))
                        .accessibilityIdentifier("home.share")
                }
                .padding(.horizontal, geometry.size.width < 355 ? 16 : 24)
                .padding(.bottom, 8)
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: 540)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Design.ink.ignoresSafeArea())
        .foregroundStyle(Design.text)
        .onAppear {
            if !installed {
                installed = true
                model.connect()
                model.installScreenshotState()
            }
            model.sceneActive(scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in model.sceneActive(phase == .active) }
        .reviewAfterCoreAction(when: installed && model.session == nil && model.sheet == nil && model.result != .failed && !model.showMilestone,
                               alreadyRequested: model.reviewedThisVersion) {
            requestReview()
            model.markReviewRequested()
        }
        .task(id: ReviewState(active: scenePhase == .active, idle: model.session == nil,
                              sheetClosed: model.sheet == nil, failed: model.result == .failed)) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            model.offerReview { requestReview() }
        }
        .sheet(isPresented: Binding(get: { model.sheet != nil }, set: { if !$0 { model.sheet = nil } })) {
            if let destination = model.sheet {
                sheet(for: destination)
                    .presentationDetents(detents(for: destination))
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Design.panel)
            }
        }
    }

    private struct ReviewState: Equatable {
        let active: Bool
        let idle: Bool
        let sheetClosed: Bool
        let failed: Bool
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L.t("home.title"))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            Button(L.t("settings.title")) { model.sheet = .settings }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("home.settings")
        }
    }

    private var hero: some View {
        VStack(spacing: 11) {
            HStack(spacing: 7) {
                if model.session?.isPlaying == true {
                    Circle().fill(Design.accent).frame(width: 6, height: 6).accessibilityHidden(true)
                }
                Text(statusTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(model.session?.isPlaying == true ? Design.accent : Design.muted)
                    .accessibilityIdentifier("home.status")
            }
            Text(focusTitle)
                .font(.system(size: min(focusSize, 104), weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .accessibilityLabel(Text(focusAccessibility))
                .accessibilityIdentifier("home.focus")
            Text(detailTitle)
                .font(.subheadline)
                .foregroundStyle(Design.muted)
                .accessibilityIdentifier("home.detail")
            if model.fallback {
                Text(L.t("home.fallback"))
                    .font(.footnote)
                    .foregroundStyle(Design.muted)
                    .accessibilityIdentifier("home.fallback")
            }
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 175 : 239)
    }

    private var statusTitle: String {
        if let session = model.session {
            switch session.pause {
            case nil:
                return model.fading ? L.t("home.fading") : L.f("home.playing", session.preset.sound.name)
            case .routeLost: return L.t("home.routeLost")
            case .failure: return L.t("home.failure")
            case .interruption: return L.t("home.interrupted")
            case .manual: return L.t("home.paused")
            }
        }
        switch model.result {
        case .ready: return L.t("home.ready")
        case .ended: return L.t("home.ended")
        case .failed: return L.t("home.failure")
        }
    }

    private var focusTitle: String {
        guard let remaining = model.remaining else { return model.shownPreset.sound.name }
        let seconds = Int(ceil(remaining))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var focusAccessibility: String {
        guard let remaining = model.remaining else { return focusTitle }
        let seconds = Int(ceil(remaining))
        return L.f("home.timeAccessibility", seconds / 60, seconds % 60)
    }

    private var detailTitle: String {
        if model.remaining != nil { return L.t("home.remaining") }
        if model.shownPreset.timer == .overnight { return L.t("home.overnightDetail") }
        return L.f("home.timerDetail", model.shownPreset.timer.name)
    }

    private var controls: some View {
        VStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 6) {
                controlLabel(L.t("home.sounds"))
                choices {
                    ForEach(FanSound.allCases, id: \.self) { sound in
                        choice(sound.name, id: "sound." + sound.rawValue,
                               selected: model.shownPreset.sound == sound,
                               locked: !model.hasPro && sound.isPro) { model.selectSound(sound) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    controlLabel(L.t("home.timers"))
                    Spacer()
                    Button(L.t("timer.more")) { model.sheet = .more }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityLabel(Text(L.t("timer.moreTitle")))
                        .accessibilityIdentifier("timer.more")
                }
                choices {
                    ForEach(FanTimer.basic, id: \.self) { timer in
                        choice(timer.shortName, id: "timer.\(timer.rawValue)",
                               selected: model.shownPreset.timer == timer,
                               accessibilityName: timer.name) { model.selectTimer(timer) }
                    }
                }
                if model.shownPreset.timer.isPro {
                    Text(model.shownPreset.timer.name).font(.footnote)
                        .foregroundStyle(Design.accent)
                        .accessibilityIdentifier("timer.advancedSelected")
                        .padding(.top, 4)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    controlLabel(L.t("home.gain"))
                    Spacer()
                    Text(model.shownPreset.gain.formatted(.percent.precision(.fractionLength(0))))
                        .foregroundStyle(Design.muted)
                        .font(.subheadline.monospacedDigit())
                        .accessibilityHidden(true)
                }
                Slider(value: Binding(get: { model.shownPreset.gain }, set: model.changeGain))
                    .frame(minHeight: 44)
                    .accessibilityLabel(Text(L.t("home.gain")))
                    .accessibilityIdentifier("home.gain")
            }
        }
    }

    private func controlLabel(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }

    private func choices<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        return layout { content() }
    }

    private func choice(_ title: String, id: String, selected: Bool, locked: Bool = false,
                        accessibilityName: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).minimumScaleFactor(0.8)
                if locked && !selected {
                    Image(systemName: "lock").font(.caption2).accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(FanButtonStyle(highlighted: selected, compact: true))
        .accessibilityLabel(Text(accessibilityName ?? title))
        .accessibilityHint(Text(locked && !selected ? L.t("paywall.title") : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private var milestone: some View {
        HStack {
            Button(L.t("milestone.invite")) { model.sheet = .milestone }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("milestone.share")
            Spacer()
            Button { model.dismissMilestone() } label: { Image(systemName: "xmark") }
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel(Text(L.t("common.dismiss")))
                .accessibilityIdentifier("milestone.dismiss")
        }
        .foregroundStyle(Design.accent)
    }

    private func detents(for sheet: FanModel.Sheet) -> Set<PresentationDetent> {
        if typeSize.isAccessibilitySize { return [.large] }
        switch sheet {
        case .share, .milestone: return [.fraction(0.70), .large]
        case .settings, .importCode, .more: return [.medium, .large]
        case .paywall, .privacy: return [.large]
        }
    }

    @ViewBuilder private func sheet(for destination: FanModel.Sheet) -> some View {
        switch destination {
        case .settings: SettingsSheet(model: model)
        case .more: MoreTimersSheet(model: model)
        case .share, .milestone:
            ShareCardSheet(preset: model.sharePreset, milestone: destination == .milestone) { model.sheet = nil }
        case .importCode: ImportSheet(model: model)
        case .paywall: PaywallSheet(model: model, purchases: model.purchases)
        case .privacy: PrivacySheet { model.sheet = .settings }
        }
    }
}
