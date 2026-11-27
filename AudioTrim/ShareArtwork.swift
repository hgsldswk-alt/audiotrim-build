import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
struct ShareArtwork {
    let record: ExportRecord
    let source: SourceAsset
    let peaks: [Double]
    let milestone: Milestone?
    private static let context = CIContext()

    static var storeURL: URL? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String,
              !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(id)")
    }

    var topic: String {
        let seconds = max(1, Int(duration.rounded()))
        return milestone.map { L.f("card.milestoneTopic", $0.count, seconds) } ?? L.f("card.topicText", seconds)
    }
    private var duration: Double { milestone?.seconds ?? Double(record.spec.selection.count) / Double(source.rate) }

    var preview: some View {
        GeometryReader { proxy in
            layout(width: proxy.size.width)
        }
        .aspectRatio(4 / 5.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .accessibilityElement(children: .contain)
    }

    func png() -> Data? {
        let renderer = ImageRenderer(content: layout(width: 360).environment(\.colorScheme, .light))
        renderer.scale = 3
        return renderer.uiImage?.pngData()
    }

    private func layout(width: CGFloat) -> some View {
        let unit = width / 360
        let header = milestone.map { L.f("card.achievement", $0.count) } ?? L.t("card.headline")
        return VStack(alignment: .leading, spacing: 14 * unit) {
            Text(record.spec.format.codec)
                .font(.system(size: 13 * unit, weight: .semibold, design: .monospaced))
                .foregroundStyle(ClipTheme.lavender)
            Text(header)
                .font(.system(size: 30 * unit, weight: .bold))
                .lineLimit(2).minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 7 * unit) {
                Text(L.number(duration, decimals: milestone == nil ? 2 : 0))
                    .font(.system(size: 58 * unit, weight: .heavy, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.45)
                Text(L.t("duration.unit")).font(.system(size: 17 * unit, weight: .medium))
            }
            Rectangle().fill(ClipTheme.lavender.opacity(0.26)).frame(height: unit)
            GeometryReader { proxy in
                WaveBars(values: peaks, tint: ClipTheme.lavender)
                    .frame(height: min(96 * unit, proxy.size.height))
                    .frame(maxHeight: .infinity)
            }
            Rectangle().fill(ClipTheme.lavender.opacity(0.26)).frame(height: unit)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5 * unit) {
                    Text(L.t("app.name")).font(.system(size: 17 * unit, weight: .bold))
                    Text(L.t(Self.storeURL == nil ? "card.storePending" : "card.scan"))
                        .font(.system(size: 11 * unit)).foregroundStyle(ClipTheme.lavender)
                }
                Spacer(minLength: 5)
                qrSide.frame(width: 75 * unit, height: 75 * unit)
            }
        }
        .padding(20 * unit)
        .frame(width: width, height: width * 1.25)
        .foregroundStyle(Color.white)
        .background(ClipTheme.card)
    }

    @ViewBuilder private var qrSide: some View {
        if let url = Self.storeURL, let qr = Self.qr(url) {
            Image(decorative: qr, scale: 1, orientation: .up)
                .interpolation(.none).resizable().scaledToFit().padding(6)
                .background(Color.white)
                .accessibilityLabel(L.t("card.scan"))
        } else {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(ClipTheme.lavender.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .overlay { Image(systemName: "app.dashed").foregroundStyle(ClipTheme.lavender) }
                .accessibilityHidden(true)
        }
    }

    private static func qr(_ url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}
