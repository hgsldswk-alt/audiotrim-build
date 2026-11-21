import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class LocalAudio: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var position: TimeInterval?
    @Published private(set) var playing: String?
    @Published private(set) var interrupted = false
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var updates: Task<Void, Never>?
    private var pausedPosition: (key: String, seconds: Double)?
    private(set) var recordingURL: URL?

    func startRecording(at url: URL, simulated: Bool) async throws {
        let allowed: Bool
        if simulated {
            allowed = true
        } else {
            allowed = await AVAudioApplication.requestRecordPermission()
        }
        guard allowed else { throw ClipFailure.microphone }
        stopPlayback()
        elapsed = 0
        if !simulated {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            do {
                let next = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
                ])
                guard next.record() else { throw ClipFailure.recording }
                recorder = next
            } catch {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                throw error
            }
        }
        recordingURL = url
        recording = true
        let start = Date()
        updates = Task { [weak self] in
            while !Task.isCancelled, let self {
                self.elapsed = simulated ? Date().timeIntervalSince(start) : (self.recorder?.currentTime ?? 0)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func stopRecording(simulated: Bool) -> URL? {
        guard recording else { return nil }
        updates?.cancel()
        recorder?.stop()
        recorder = nil
        recording = false
        let url = recordingURL
        recordingURL = nil
        if !simulated { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        return url
    }

    func toggle(_ url: URL, key: String, start: Double = 0, end: Double? = nil) throws {
        if playing == key {
            pausePlayback()
            return
        }
        let resume = pausedPosition?.key == key ? pausedPosition?.seconds : nil
        stopPlayback()
        let next = try AVAudioPlayer(contentsOf: url)
        let stop = min(end ?? next.duration, next.duration)
        let first = resume.map { $0 >= start && $0 < stop ? $0 : start } ?? start
        guard first < stop else { throw ClipFailure.playback }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        next.currentTime = first
        guard next.play() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw ClipFailure.playback
        }
        player = next
        playing = key
        position = first
        updates = Task { [weak self] in
            while !Task.isCancelled, let self, let player = self.player {
                guard player.isPlaying, player.currentTime < stop else { self.stopPlayback(); break }
                self.position = player.currentTime
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    func pausePlayback() {
        guard let key = playing, let player else { return }
        let seconds = player.currentTime
        stopPlayback()
        pausedPosition = (key, seconds)
        position = seconds
    }

    func stopPlayback() {
        if player != nil {
            updates?.cancel()
            player?.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        player = nil
        playing = nil
        position = nil
        pausedPosition = nil
    }

    func sessionInterrupted(_ value: Bool) {
        interrupted = value
        if value { pausePlayback() }
    }
}

enum RecordingRecovery {
    static func isPlayable(_ url: URL) -> Bool {
        if let audio = try? AVAudioFile(forReading: url), audio.length > 0 { return true }
        guard repairWAV(url), let audio = try? AVAudioFile(forReading: url) else { return false }
        return audio.length > 0
    }

    private static func repairWAV(_ url: URL) -> Bool {
        do {
            let file = try FileHandle(forUpdating: url)
            defer { try? file.close() }
            let size = try file.seekToEnd()
            guard size > 44, size - 8 <= UInt64(UInt32.max) else { return false }
            try file.seek(toOffset: 0)
            guard let header = try file.read(upToCount: 65_536), header.count > 44,
                  header.prefix(4) == Data("RIFF".utf8), header[8..<12] == Data("WAVE".utf8) else { return false }
            var offset = 12
            var alignment: UInt64 = 0
            while offset + 8 <= header.count {
                let name = header[offset..<(offset + 4)]
                let length = Int(readLittleEndian(header, at: offset + 4))
                if name == Data("fmt ".utf8), length >= 16, offset + 24 <= header.count {
                    let codec = readLittleEndian(header, at: offset + 8) & 0xffff
                    let bitsAndAlignment = readLittleEndian(header, at: offset + 20)
                    guard codec == 1, bitsAndAlignment == 0x00100002 else { return false }
                    alignment = 2
                }
                if name == Data("data".utf8) {
                    guard alignment > 0 else { return false }
                    let sampleBytes = size - UInt64(offset + 8)
                    let complete = sampleBytes - sampleBytes % alignment
                    guard complete > 0 else { return false }
                    try writeLittleEndian(UInt32(complete), at: UInt64(offset + 4), using: file)
                    try writeLittleEndian(UInt32(UInt64(offset) + complete), at: 4, using: file)
                    try file.truncate(atOffset: UInt64(offset + 8) + complete)
                    try file.synchronize()
                    return true
                }
                offset += 8 + length + length % 2
            }
        } catch { return false }
        return false
    }

    private static func readLittleEndian(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func writeLittleEndian(_ value: UInt32, at offset: UInt64, using file: FileHandle) throws {
        var word = value.littleEndian
        let data = withUnsafeBytes(of: &word) { Data($0) }
        try file.seek(toOffset: offset)
        try file.write(contentsOf: data)
    }
}
