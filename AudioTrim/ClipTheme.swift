import SwiftUI
import UIKit

enum ClipTheme {
    static let accent = adaptive(0x3730A3, 0xB3AAFF)
    static let accentFill = Color(red: 0.2157, green: 0.1882, blue: 0.6392)
    static let paper = adaptive(0xFDFDFE, 0x171823)
    static let raised = adaptive(0xF1F2F7, 0x252637)
    static let selected = adaptive(0xECEBFC, 0x363050)
    static let outline = adaptive(0xD8DCE8, 0x434558)
    static let card = Color(red: 0.095, green: 0.09, blue: 0.198)
    static let lavender = Color(red: 0.714, green: 0.682, blue: 0.992)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { style in
            let rgb = style.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

struct ClipButton: View {
    let key: String
    let icon: String?
    let id: String
    var primary = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).accessibilityHidden(true) }
                Text(L.t(key)).multilineTextAlignment(.center)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 9)
            .padding(.vertical, primary ? 4 : 0)
            .foregroundStyle(primary ? Color.white : Color.primary)
            .background(primary ? ClipTheme.accentFill : ClipTheme.raised, in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct ClipChip: View {
    let key: String
    let id: String
    var selected = false
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(L.t(key))
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .foregroundStyle(!enabled ? Color.secondary : selected ? ClipTheme.accent : .primary)
                .background(selected ? ClipTheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ClipTheme.outline) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

@MainActor
struct HomeScreen: View {
    @ObservedObject var model: ClipController
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 44.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Image(systemName: "waveform")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(ClipTheme.accent)
                        .frame(width: 44, height: 44)
                        .background(ClipTheme.selected, in: RoundedRectangle(cornerRadius: 13))
                        .accessibilityHidden(true)
                    Spacer()
                    Button(L.t("settings.title")) { model.show(.settings) }
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("home.settings")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.t("app.name")).font(.system(size: titleSize, weight: .heavy))
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("home.title")
                    Text(L.t("home.subtitle")).font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(spacing: 9) {
                    Button { model.select(.audio) } label: {
                        HStack(spacing: 15) {
                            Image(systemName: "doc")
                                .font(.system(size: 28, weight: .medium))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L.t("home.import")).font(.title2.weight(.bold))
                                Text(L.t("home.files")).font(.subheadline).foregroundStyle(.white.opacity(0.86))
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.right").font(.title3).accessibilityHidden(true)
                        }
                        .foregroundStyle(.white)
                        .padding(19)
                        .frame(minHeight: 132)
                        .background(ClipTheme.accentFill, in: RoundedRectangle(cornerRadius: 23))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.import")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { inputs }
                        VStack(spacing: 8) { inputs }
                    }
                    if Launch.freePeriod {
                        entry("merge.title", icon: "waveform.path", id: "home.merge") { model.select(.merge) }
                    }
                }
                if !model.drafts.isEmpty { recent }
                if !model.state.jobs.isEmpty {
                    ClipButton(key: "jobs.title", icon: "list.bullet", id: "home.jobs") { model.show(.tasks) }
                }
                if !model.drafts.isEmpty {
                    Text(L.t("home.originals")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 21)
            .padding(.vertical, 12)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
    }

    private var inputs: some View {
        Group {
            entry("home.record", icon: "record.circle", id: "home.record") { model.startRecording() }
            entry("home.video", icon: "play.rectangle", id: "home.video") { model.select(.video) }
        }
    }

    private func entry(_ key: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(L.t(key)).fixedSize(horizontal: true, vertical: false)
            } icon: {
                Image(systemName: icon).foregroundStyle(ClipTheme.accent)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 58)
            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(ClipTheme.outline) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L.t("home.recent")).font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if Launch.freePeriod {
                    Button(L.t("home.batch")) { model.show(.batch) }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("home.batch")
                }
            }
            ForEach(model.drafts) { draft in
                if let source = model.state.source(for: draft) {
                    Divider()
                    Button { model.open(draft) } label: {
                        HStack(spacing: 12) {
                            Text(source.label)
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(ClipTheme.accent)
                                .frame(width: 41, height: 41)
                                .background(ClipTheme.selected, in: RoundedRectangle(cornerRadius: 11))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(draft.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 2)
                            Text(ClipClock.display(source.frames, rate: source.rate))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.draft.\(draft.id)")
                }
            }
            Divider()
        }
    }
}
