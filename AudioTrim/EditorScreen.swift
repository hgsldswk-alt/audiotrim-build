import SwiftUI

@MainActor
struct EditorScreen: View {
    @ObservedObject var model: ClipController
    @ObservedObject var audio: LocalAudio
    let draft: Draft
    let source: SourceAsset
    @ScaledMetric(relativeTo: .largeTitle) private var durationSize = 47.0

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    duration
                    WaveEditor(model: model, draft: draft, source: source,
                               playback: audio.position.map { Int64($0 * Double(source.rate)) })
                    HStack(spacing: 8) {
                        endpoint("editor.start", frame: draft.selection.start, id: "editor.start")
                        endpoint("editor.end", frame: draft.selection.end, id: "editor.end")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 7) { actions }
                        VStack(spacing: 7) { actions }
                    }
                    Text(L.t("editor.presets"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 4)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 7) { presets }
                        VStack(alignment: .leading, spacing: 7) { presets }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                ClipButton(key: "export.m4a", icon: "arrow.down.to.line", id: "editor.export", primary: true) {
                    model.export(.m4a)
                }
                Button {
                    model.show(.format)
                } label: {
                    Label(L.t("export.format"), systemImage: "chevron.up.chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 52)
                        .background(ClipTheme.raised, in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("editor.format")
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(.regularMaterial)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Button { model.home() } label: {
                Label(L.t("editor.files"), systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }.accessibilityIdentifier("editor.home")
            VStack(spacing: 2) {
                Text(source.title).font(.headline).lineLimit(1).accessibilityIdentifier("editor.title")
                    .accessibilityAddTraits(.isHeader)
                Text(L.f("editor.source", source.label, ClipClock.display(source.frames, rate: source.rate)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            Menu {
                Button { model.show(.shareSelection) } label: {
                    Label(L.t("code.share"), systemImage: "square.and.arrow.up")
                }.accessibilityIdentifier("editor.shareSelection")
                Button { model.show(.importSelection) } label: {
                    Label(L.t("code.import"), systemImage: "square.and.arrow.down")
                }.accessibilityIdentifier("editor.importSelection")
                if !model.history.isEmpty {
                    Button { model.show(.history) } label: {
                        Label(L.t("history.title"), systemImage: "clock.arrow.circlepath")
                    }.accessibilityIdentifier("editor.history")
                }
                if !model.state.jobs.isEmpty {
                    Button { model.show(.tasks) } label: {
                        Label(L.t("jobs.title"), systemImage: "list.bullet")
                    }.accessibilityIdentifier("editor.jobs")
                }
            } label: {
                Image(systemName: "ellipsis").font(.headline)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(L.t("editor.more"))
            .accessibilityIdentifier("editor.more")
        }
    }

    private var duration: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(L.number(Double(draft.selection.count) / Double(source.rate), decimals: 2))
                        .font(.system(size: durationSize, weight: .heavy, design: .monospaced))
                        .minimumScaleFactor(0.5).lineLimit(1)
                        .accessibilityIdentifier("editor.duration")
                    Text(L.t("duration.unit")).font(.subheadline.weight(.medium))
                }
                Text(L.t("editor.kept")).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 7)
            if model.undo != nil {
                Button(L.t("editor.undo")) { model.undoRange() }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("editor.undo")
            }
        }
    }

    private func endpoint(_ key: String, frame: Int64, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.t(key)).font(.caption).foregroundStyle(.secondary)
            Text(ClipClock.display(frame, rate: source.rate))
                .font(.subheadline.monospaced().weight(.semibold)).accessibilityIdentifier(id)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ClipTheme.outline) }
    }

    private var actions: some View {
        Group {
            ClipButton(key: audio.playing == "selection" ? "play.pause" : "play.selection",
                       icon: audio.playing == "selection" ? "pause.fill" : "play.fill", id: "editor.preview") { model.preview() }
                .fixedSize(horizontal: true, vertical: false)
            ClipButton(key: "time.title", icon: nil, id: "editor.time") { model.show(.time) }
                .fixedSize(horizontal: true, vertical: false)
            ClipButton(key: "split.title", icon: nil, id: "editor.split") { model.requestPro(.split) }
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var presets: some View {
        ForEach(ClipPreset.allCases, id: \.self) { preset in
            ClipChip(key: "preset." + preset.rawValue, id: "editor.preset." + preset.rawValue,
                     selected: draft.preset == preset) { model.preset(preset) }
                .disabled(preset.range(total: source.frames, rate: source.rate) == nil)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

@MainActor
private struct WaveEditor: View {
    @ObservedObject var model: ClipController
    let draft: Draft
    let source: SourceAsset
    var playback: Int64?
    @State private var initialZoom: Double?
    @State private var panStart: Double?
    @State private var startDrag: Int64?
    @State private var endDrag: Int64?

    private var visible: FrameRange {
        let width = max(1, Int64(Double(source.frames) / draft.zoom))
        let left = min(source.frames - width, max(0, Int64(Double(source.frames) * draft.center) - width / 2))
        return FrameRange(start: left, end: left + width)
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 30)
                let left = x(draft.selection.start, width: width)
                let right = x(draft.selection.end, width: width)
                let bars = model.peaks?.values(in: visible, bars: max(10, Int(width / 3.1))) ?? []
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(ClipTheme.selected)
                        .frame(width: max(0, right - left))
                        .offset(x: left)
                    WaveBars(values: bars, tint: ClipTheme.accent, selectedLeft: (left - 15) / width,
                             selectedRight: (right - 15) / width)
                        .frame(width: width, height: 96)
                        .offset(x: 15)
                    ForEach(draft.cuts.filter { visible.start ... visible.end ~= $0 }, id: \.self) { cut in
                        Rectangle().fill(ClipTheme.accent.opacity(0.6)).frame(width: 1, height: 97)
                            .offset(x: x(cut, width: width)).accessibilityHidden(true)
                    }
                    if let cursor = playback ?? model.playhead, visible.start ... visible.end ~= cursor {
                        Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 1.5, height: 106)
                            .offset(x: x(cursor, width: width)).accessibilityHidden(true)
                    }
                    Rectangle().fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if panStart == nil { panStart = draft.center }
                            guard draft.zoom > 1, abs(value.translation.width) > 2 else { return }
                            model.viewport(zoom: draft.zoom, center: (panStart ?? draft.center)
                                           - Double(value.translation.width / width) / draft.zoom)
                        }.onEnded { value in
                            if abs(value.translation.width) <= 2 {
                                model.movePlayhead(frame(at: value.location.x, width: width))
                            }
                            panStart = nil
                        })
                        .accessibilityHidden(true)
                    if visible.start ... visible.end ~= draft.selection.start {
                        handle(start: true, at: left, width: width)
                    }
                    if visible.start ... visible.end ~= draft.selection.end {
                        handle(start: false, at: right, width: width)
                    }
                }
            }
            .frame(height: 112)
            .simultaneousGesture(MagnificationGesture()
                .onChanged { value in
                    if initialZoom == nil { initialZoom = draft.zoom }
                    model.viewport(zoom: (initialZoom ?? draft.zoom) * Double(value), center: draft.center)
                }
                .onEnded { _ in initialZoom = nil })
            HStack {
                Text(ClipClock.display(visible.start, rate: source.rate, fractions: false))
                Spacer()
                if draft.zoom > 1 { Text(L.f("wave.zoom", L.number(draft.zoom, decimals: 1))).accessibilityIdentifier("wave.level") }
                Spacer()
                Text(ClipClock.display(visible.end, rate: source.rate, fractions: false))
            }.font(.caption2.monospaced()).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                zoomButton(increase: false)
                Text(L.t("wave.hint")).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                zoomButton(increase: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.top, 9)
        .background(ClipTheme.raised, in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(ClipTheme.outline).allowsHitTesting(false) }
    }

    private func x(_ frame: Int64, width: CGFloat) -> CGFloat {
        15 + width * CGFloat(min(1, max(0, Double(frame - visible.start) / Double(visible.count))))
    }

    private func frame(at x: CGFloat, width: CGFloat) -> Int64 {
        let fraction = min(1, max(0, Double((x - 15) / width)))
        return visible.start + Int64((fraction * Double(visible.count)).rounded())
    }

    private func handle(start: Bool, at x: CGFloat, width: CGFloat) -> some View {
        let key = start ? "editor.start" : "editor.end"
        let current = start ? draft.selection.start : draft.selection.end
        return RoundedRectangle(cornerRadius: 4)
            .fill(ClipTheme.accent)
            .frame(width: 6, height: 108)
            .frame(width: 44, height: 112)
            .contentShape(Rectangle())
            .offset(x: x - 22)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if (start ? startDrag : endDrag) == nil {
                        model.captureUndo()
                        if start { startDrag = current } else { endDrag = current }
                    }
                    let origin = (start ? startDrag : endDrag) ?? current
                    let delta = Int64((Double(value.translation.width / width) * Double(visible.count)).rounded())
                    adjust(start: start, to: origin + delta, remember: false)
                }
                .onEnded { _ in
                    startDrag = nil
                    endDrag = nil
                    model.flushDraft()
                })
            .accessibilityLabel(L.t(key))
            .accessibilityValue(ClipClock.display(current, rate: source.rate))
            .accessibilityIdentifier(start ? "wave.start" : "wave.end")
            .accessibilityAdjustableAction { direction in
                let step = Int64(source.rate / 100)
                switch direction {
                case .increment: adjust(start: start, to: current + step, remember: true)
                case .decrement: adjust(start: start, to: current - step, remember: true)
                @unknown default: break
                }
            }
    }

    private func adjust(start: Bool, to frame: Int64, remember: Bool) {
        let range = start
            ? draft.selection.movingStart(frame, total: source.frames, rate: source.rate)
            : draft.selection.movingEnd(frame, total: source.frames, rate: source.rate)
        guard range != draft.selection else { return }
        model.setRange(range, remember: remember)
    }

    private func zoomButton(increase: Bool) -> some View {
        Button {
            let focus = Double(model.playhead ?? (draft.selection.start + draft.selection.count / 2)) / Double(source.frames)
            model.viewport(zoom: draft.zoom * (increase ? 2 : 0.5), center: draft.zoom == 1 ? focus : draft.center)
        } label: {
            Image(systemName: increase ? "plus.magnifyingglass" : "minus.magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .disabled(increase ? draft.zoom >= 32 : draft.zoom <= 1)
        .accessibilityLabel(L.t(increase ? "wave.in" : "wave.out"))
        .accessibilityIdentifier(increase ? "wave.zoomIn" : "wave.zoomOut")
    }
}

struct WaveBars: View {
    var values: [Double]
    var tint: Color
    var selectedLeft: CGFloat = 0
    var selectedRight: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let step = size.width / CGFloat(values.count)
            for (index, value) in values.enumerated() {
                let x = (CGFloat(index) + 0.5) * step
                let height = max(2, size.height * CGFloat(value))
                let width = max(1, step * 0.53)
                let rect = CGRect(x: x - width / 2, y: (size.height - height) / 2, width: width, height: height)
                let selected = x >= selectedLeft * size.width && x <= selectedRight * size.width
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(tint.opacity(selected ? 1 : 0.26)))
            }
        }
        .accessibilityHidden(true)
    }
}
