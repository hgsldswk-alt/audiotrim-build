import SwiftUI

@MainActor
struct MergeScreen: View {
    @ObservedObject var model: ClipController
    @ObservedObject var audio: LocalAudio
    let clips: [ClipController.MergeClip]
    @State private var editing: EditMode = .inactive

    private var total: String {
        let seconds = model.mergeGap.duration(of: clips.map(\.source))
        return ClipClock.display(Int64((seconds * 100).rounded()), rate: 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { model.home() } label: {
                    Image(systemName: "chevron.backward").frame(width: 44, height: 44)
                }
                .accessibilityLabel(L.t("app.name"))
                .accessibilityIdentifier("merge.home")
                Spacer()
                if clips.count > 1 || editing.isEditing {
                    EditButton().frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("merge.reorder")
                }
                Button { model.select(.merge) } label: {
                    Label(L.t("merge.add"), systemImage: "plus")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("merge.add")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)

            Text(L.t("merge.title"))
                .font(.largeTitle.weight(.heavy))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("merge.title")
                .padding(.horizontal, 21)
                .padding(.bottom, 15)

            List {
                ForEach(clips) { clip in
                    row(clip)
                        .listRowBackground(ClipTheme.paper)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { model.removeMergeClip(clip) } label: {
                                Label(L.t("common.delete"), systemImage: "trash")
                            }
                        }
                }
                .onMove(perform: model.moveMergeClips)
                if clips.count < 2 {
                    Text(L.t("merge.minimum"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(ClipTheme.paper)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("merge.interval")).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Picker(L.t("merge.interval"), selection: $model.mergeGap) {
                    ForEach(MergeGap.allCases, id: \.self) { gap in
                        Text(L.number(gap.seconds, decimals: gap == .half ? 1 : 0)).tag(gap)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("merge.interval")
                HStack {
                    Text(L.t("merge.total")).foregroundStyle(.secondary)
                    Spacer()
                    Text(total).monospacedDigit().accessibilityIdentifier("merge.duration")
                }
                .font(.subheadline.weight(.semibold))
                ClipButton(key: "merge.export", icon: "square.and.arrow.up", id: "merge.export", primary: true) {
                    model.exportMerge()
                }
                .disabled(clips.count < 2)
                .opacity(clips.count < 2 ? 0.5 : 1)
            }
            .padding(.horizontal, 21)
            .padding(.vertical, 12)
            .background(ClipTheme.paper)
        }
        .environment(\.editMode, $editing)
    }

    private func row(_ clip: ClipController.MergeClip) -> some View {
        let playing = audio.playing == clip.id.uuidString
        return HStack(spacing: 12) {
            Button { model.preview(clip) } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ClipTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(ClipTheme.selected, in: RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.f(playing ? "merge.pause" : "merge.preview", clip.name))
            .accessibilityIdentifier("merge.preview.\(clip.id)")
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(ClipClock.display(clip.source.frames, rate: clip.source.rate))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}
