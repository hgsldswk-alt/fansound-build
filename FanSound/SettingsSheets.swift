import StoreKit
import SwiftUI

@MainActor
struct SettingsSheet: View {
    @ObservedObject var model: FanModel
    @Environment(\.requestReview) private var requestReview
    @State private var outgoing: ShareItems? = nil
    @State private var shareRequested = false
    @State private var restoring = false
    @State private var restoreMessage: String? = nil

    var body: some View {
        SheetScaffold(title: L.t("settings.title"), close: { model.sheet = nil }) {
            row("import.title", id: "settings.import") { model.sheet = .importCode }
            row("settings.recommend", id: "settings.recommend") {
                if Launch.isUITesting {
                    shareRequested = !Launch.downloadURL.absoluteString.isEmpty
                } else {
                    outgoing = ShareItems(values: [Launch.downloadURL])
                }
            }
            row("settings.review", id: "settings.review") { requestReview() }
                .disabled(model.session != nil || model.result == .failed)
            row("privacy.title", id: "settings.privacy") { model.sheet = .privacy }
            if !Launch.isFree {
                Divider().overlay(Design.line)
                row("paywall.title", id: "settings.paywall") { model.sheet = .paywall }
                Text(model.purchaseStatus)
                    .font(.footnote)
                    .foregroundStyle(Design.muted)
                    .accessibilityIdentifier("settings.entitlement")
                row("paywall.restore", id: "settings.restore") {
                    restoring = true
                    Task {
                        await model.purchases.restore()
                        restoreMessage = model.purchases.message
                        restoring = false
                    }
                }
                .disabled(restoring || Launch.isUITesting)
            }
            if let restoreMessage { Text(restoreMessage).font(.footnote).foregroundStyle(Design.muted) }
            if shareRequested {
                Text(L.t("share.prepared")).font(.footnote).accessibilityIdentifier("share.requested")
            }
        }
        .sheet(item: $outgoing) { items in SystemShareView(items: items) { outgoing = nil } }
    }

    private func row(_ key: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(L.t(key))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Design.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Design.raised, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

@MainActor
struct MoreTimersSheet: View {
    @ObservedObject var model: FanModel

    var body: some View {
        SheetScaffold(title: L.t("timer.moreTitle"), close: { model.sheet = nil }) {
            ForEach(FanTimer.advanced, id: \.self) { timer in
                let selected = model.shownPreset.timer == timer
                let locked = !model.hasPro && !selected
                Button {
                    model.selectTimer(timer)
                } label: {
                    HStack {
                        Text(timer.name)
                        if locked { Image(systemName: "lock").font(.caption).accessibilityHidden(true) }
                    }
                }
                .buttonStyle(FanButtonStyle(highlighted: selected, compact: true))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint(Text(locked ? L.t("paywall.title") : ""))
                .accessibilityIdentifier("timer.\(timer.rawValue)")
            }
        }
    }
}

@MainActor
struct ImportSheet: View {
    @ObservedObject var model: FanModel
    @State private var entry = ""
    @State private var error: String? = nil

    var body: some View {
        SheetScaffold(title: L.t("import.title"), close: { model.sheet = .settings }) {
            Text(L.t("import.help")).font(.subheadline).foregroundStyle(Design.muted)
            PasteButton(payloadType: String.self) { values in
                if let first = values.first { apply(first) }
            }
            .accessibilityIdentifier("import.paste")
            TextField(L.t("import.placeholder"), text: $entry, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())
                .padding(12)
                .frame(minHeight: 44)
                .background(Design.ink, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("import.field")
                .onChange(of: entry) { _, _ in error = nil }
            Button(L.t("import.apply")) { apply(entry) }
                .buttonStyle(FanButtonStyle())
                .disabled(entry.isEmpty)
                .accessibilityIdentifier("import.apply")
            if let error {
                Text(error).font(.footnote).foregroundStyle(Design.accent).accessibilityIdentifier("import.error")
            }
        }
        .onAppear {
            if Launch.isUITesting { entry = ProcessInfo.processInfo.environment["FAN_TEST_PRESET_CODE"] ?? "" }
        }
    }

    private func apply(_ text: String) {
        if !model.importCode(text) { error = L.t("import.invalid") }
    }
}

@MainActor
struct PaywallSheet: View {
    @ObservedObject var model: FanModel
    @ObservedObject var purchases: Purchases

    var body: some View {
        SheetScaffold(title: L.t("paywall.title"), titleID: "paywall.title", close: { model.sheet = nil }) {
            Text(L.t("paywall.details")).foregroundStyle(Design.muted)
            Text(model.purchaseStatus)
                .font(.headline)
                .foregroundStyle(Design.accent)
                .accessibilityIdentifier("paywall.entitlement")
            if !model.state.entitlement.purchasedPro {
                Button(buyTitle) { Task { await purchases.purchase(purchases.proID) } }
                    .buttonStyle(FanButtonStyle())
                    .disabled(purchases.busy || (purchases.product(purchases.proID) == nil && !Launch.isUITesting))
                    .accessibilityIdentifier("paywall.buy")
                if model.hasPro && model.state.entitlement.trialClaimedAt == nil {
                    Button(L.t("paywall.trial")) { Task { await purchases.purchase(purchases.trialID) } }
                        .buttonStyle(QuietButtonStyle(fullWidth: true))
                        .disabled(purchases.busy || (purchases.product(purchases.trialID) == nil && !Launch.isUITesting))
                        .accessibilityIdentifier("paywall.trial")
                }
                if purchases.product(purchases.proID) == nil && !Launch.isUITesting {
                    Button(L.t("purchase.reload")) { Task { await purchases.load() } }
                        .buttonStyle(QuietButtonStyle(fullWidth: true))
                        .disabled(purchases.busy)
                        .accessibilityIdentifier("paywall.reload")
                }
            }
            Button(L.t("paywall.restore")) { Task { await purchases.restore() } }
                .buttonStyle(QuietButtonStyle(fullWidth: true))
                .disabled(purchases.busy)
                .accessibilityIdentifier("paywall.restore")
            Text(L.t("paywall.terms")).font(.footnote).foregroundStyle(Design.muted)
            if purchases.busy { ProgressView().accessibilityIdentifier("paywall.loading") }
            if let message = purchases.message { Text(message).font(.footnote).foregroundStyle(Design.muted) }
        }
        .task { await purchases.load() }
    }

    private var buyTitle: String {
        if let product = purchases.product(purchases.proID) { return L.f("paywall.buyPrice", product.displayPrice) }
        if Launch.isUITesting { return L.f("paywall.buyPrice", L.t("paywall.testPrice")) }
        return L.t("paywall.buy")
    }
}

struct PrivacySheet: View {
    let close: () -> Void

    var body: some View {
        SheetScaffold(title: L.t("privacy.title"), close: close) {
            Text(L.t("privacy.local")).foregroundStyle(Design.muted)
            Text(L.t("privacy.apple")).foregroundStyle(Design.muted)
            Text(L.t("privacy.sharing")).foregroundStyle(Design.muted)
        }
    }
}
