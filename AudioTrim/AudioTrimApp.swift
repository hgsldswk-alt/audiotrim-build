import AVFoundation
import StoreKit
import SwiftUI
import UIKit

@main
struct AudioTrimApp: App {
    var body: some Scene {
        WindowGroup { ClipRoot() }
    }
}

@MainActor
struct ClipRoot: View {
    @StateObject private var model = ClipController()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        ClipWorkspace(model: model, audio: model.audio)
            .tint(ClipTheme.accent)
            .task { await model.boot() }
            .reviewAfterCoreAction(when: model.idleHome, alreadyRequested: model.reviewedThisVersion) {
                requestReview()
                Task { await model.markReviewRequested() }
            }
            .task(id: model.idleHome && scenePhase == .active) {
                guard model.idleHome, scenePhase == .active else { return }
                if await model.considerReview({ requestReview() }) { return }
                do { try await Task.sleep(nanoseconds: 21_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                _ = await model.considerReview { requestReview() }
            }
            .onOpenURL { model.receive($0) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.foreground() }
                if phase == .background {
                    model.flushDraft()
                    model.audio.pausePlayback()
                    if model.audio.recording { model.stopRecording() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let status = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if status == .began { model.stopForInterruption() }
                else { model.audio.sessionInterrupted(false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { note in
                guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
                if model.audio.recording { model.stopRecording() }
                else { model.audio.pausePlayback() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                model.foreground()
            }
    }
}

@MainActor
struct ClipWorkspace: View {
    @ObservedObject var model: ClipController
    @ObservedObject var audio: LocalAudio

    var body: some View {
        ZStack {
            if let clips = model.mergeClips {
                MergeScreen(model: model, audio: audio, clips: clips)
            } else if let draft = model.draft, let source = model.source {
                EditorScreen(model: model, audio: audio, draft: draft, source: source)
            } else {
                HomeScreen(model: model)
            }
        }
        .background(ClipTheme.paper.ignoresSafeArea())
        .disabled(!model.ready || model.unavailable || model.working)
        .overlay {
            if !model.ready || model.working || model.preparingRecording {
                ProgressView()
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
                    .accessibilityIdentifier("operation.progress")
            }
        }
        .overlay {
            if model.unavailable {
                ContentUnavailableView(L.t("error.data"), systemImage: "externaldrive.badge.exclamationmark")
                    .background(ClipTheme.paper.ignoresSafeArea())
            }
        }
        .overlay(alignment: .bottom) {
            if model.panel == nil, let notice = model.notice {
                noticeBar(notice)
            }
        }
        .fileImporter(isPresented: Binding(get: { model.panel == nil && model.pickerShown },
                                           set: { if model.panel == nil { model.pickerShown = $0 } }),
                      allowedContentTypes: model.selectedTypes,
                      allowsMultipleSelection: model.pickerAllowsMultiple, onCompletion: model.picked)
        .sheet(item: $model.panel, onDismiss: model.dismissed) { panel in
            ClipPanel(panel: panel, model: model, audio: audio)
        }
        .modifier(FailureAlert(model: model, presented: model.panel == nil))
        .background(ActivityPresenter(activity: model.activity, completion: model.activityEnded))
    }

    private func noticeBar(_ message: String) -> some View {
        Text(message)
            .font(.footnote.weight(.medium))
            .padding(12)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 75)
            .allowsHitTesting(false)
            .task(id: message) {
                do { try await Task.sleep(nanoseconds: 2_200_000_000) } catch { return }
                if model.notice == message { model.notice = nil }
            }
    }
}

@MainActor
struct FailureAlert: ViewModifier {
    @ObservedObject var model: ClipController
    let presented: Bool
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.alert(L.t("common.notice"), isPresented: Binding(
            get: { presented && model.failure != nil },
            set: { if presented && !$0 { model.failureDismissed() } }
        ), presenting: model.failure) { issue in
            if issue == .microphone {
                Button(L.t("mic.settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.accessibilityIdentifier("record.settings")
            }
            if issue == .storage && model.canRetryImport {
                Button(L.t("jobs.retry")) { model.retryImport() }.accessibilityIdentifier("import.retry")
            }
            Button(L.t("common.ok"), role: .cancel) {}.accessibilityIdentifier("notice.ok")
        } message: { issue in
            Text(L.t(issue.messageKey))
        }
    }
}

@MainActor
private struct ActivityPresenter: UIViewControllerRepresentable {
    let activity: ClipController.Activity?
    let completion: (Bool) -> Void

    final class Coordinator {
        var presented: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let activity, context.coordinator.presented != activity.id else { return }
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard coordinator.presented != activity.id else { return }
            guard var presenter = controller.view.window?.rootViewController else { completion(false); return }
            while let next = presenter.presentedViewController { presenter = next }
            let share = UIActivityViewController(activityItems: [activity.url], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = presenter.view
            share.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                                                       y: presenter.view.bounds.midY, width: 1, height: 1)
            share.completionWithItemsHandler = { _, _, _, _ in
                DispatchQueue.main.async { completion(activity.countsForReview) }
            }
            coordinator.presented = activity.id
            presenter.present(share, animated: true)
        }
    }
}
