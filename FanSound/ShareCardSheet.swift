import SwiftUI
import UIKit

struct ShareItems: Identifiable {
    let id = UUID()
    let values: [Any]
}

struct SystemShareView: UIViewControllerRepresentable {
    let items: ShareItems
    let finished: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items.values, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in finished() }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

@MainActor
struct ShareCardSheet: View {
    let preset: FanPreset
    let milestone: Bool
    let close: () -> Void
    @State private var qr: CGImage? = nil
    @State private var outgoing: ShareItems? = nil
    @State private var feedback: Feedback? = nil

    enum Feedback {
        case shared, copied, failed

        var title: String {
            switch self {
            case .shared: return L.t("share.prepared")
            case .copied: return L.t("share.copied")
            case .failed: return L.t("share.failed")
            }
        }

        var identifier: String {
            switch self {
            case .shared: return "share.requested"
            case .copied: return "share.copied"
            case .failed: return "share.failed"
            }
        }
    }

    private var copy: String {
        if preset.timer == .overnight { return L.f("share.textOvernight", preset.sound.name) }
        return L.f("share.textTimed", preset.sound.name, preset.timer.name)
    }

    var body: some View {
        SheetScaffold(title: L.t(milestone ? "milestone.title" : "share.title"),
                      titleID: "share.title", close: close) {
            artwork
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("share.preview")
            VStack(alignment: .leading, spacing: 4) {
                Text(copy).foregroundStyle(Design.muted)
                Text(L.t("share.tags")).foregroundStyle(Design.accent)
            }
            .font(.footnote)
            Button(L.t("share.image"), action: shareImage)
                .buttonStyle(FanButtonStyle())
                .accessibilityIdentifier("share.image")
                .disabled(qr == nil)
            HStack {
                Button(L.t("share.code")) {
                    if let code = PresetCode(preset).encode() { copyToClipboard(code) }
                }
                .buttonStyle(QuietButtonStyle(fullWidth: true))
                .accessibilityIdentifier("share.code")
                Button(L.t("share.text")) { copyToClipboard(copy + "\n" + L.t("share.tags")) }
                    .buttonStyle(QuietButtonStyle(fullWidth: true))
                    .accessibilityIdentifier("share.text")
            }
            if let feedback {
                Text(feedback.title)
                    .font(.footnote)
                    .foregroundStyle(Design.muted)
                    .accessibilityIdentifier(feedback.identifier)
            }
        }
        .task { if qr == nil { qr = DownloadQR.image(for: Launch.downloadURL) } }
        .sheet(item: $outgoing) { items in SystemShareView(items: items) { outgoing = nil } }
    }

    private var artwork: ShareArtwork { ShareArtwork(preset: preset, milestone: milestone, qr: qr) }

    private func shareImage() {
        let renderer = ImageRenderer(content: artwork)
        renderer.proposedSize = ProposedViewSize(width: 240, height: 300)
        renderer.scale = 4.5
        renderer.isOpaque = true
        guard let image = renderer.uiImage, image.cgImage?.width == 1080, image.cgImage?.height == 1350 else {
            feedback = .failed
            return
        }
        if Launch.isUITesting {
            feedback = .shared
        } else {
            outgoing = ShareItems(values: [image])
        }
    }

    private func copyToClipboard(_ string: String) {
        UIPasteboard.general.string = string
        feedback = .copied
    }
}

private struct ShareArtwork: View {
    let preset: FanPreset
    let milestone: Bool
    let qr: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.t(milestone ? "milestone.card" : "share.card"))
                .font(.system(size: 12))
                .foregroundStyle(Design.muted)
            Text(preset.sound.name)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Design.text)
                .padding(.top, 16)
            Text(preset.timer.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Design.accent)
            Text(L.t(preset.timer == .overnight ? "share.continuous" : "share.fade"))
                .font(.system(size: 12))
                .foregroundStyle(Design.muted)
                .padding(.top, 4)
            Spacer(minLength: 8)
            Text(L.t("share.tags"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Design.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Divider().overlay(Design.line).padding(.bottom, 6)
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("share.appName")).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Design.text)
                    Text(L.t("share.scan")).font(.system(size: 10))
                        .foregroundStyle(Design.muted)
                }
                Spacer(minLength: 0)
                if let qr {
                    Image(decorative: qr, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 64, height: 64)
                        .accessibilityIdentifier("share.qr")
                } else {
                    Color.white.opacity(0.08).frame(width: 64, height: 64).accessibilityHidden(true)
                }
            }
        }
        .padding(18)
        .frame(width: 240, height: 300, alignment: .topLeading)
        .background(Design.ink)
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Design.line, lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }
}
