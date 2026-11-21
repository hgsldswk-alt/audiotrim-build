import AVFoundation
import Foundation

enum MediaFixture {
    static func make(_ url: URL, seconds: Double = 48.2) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rate = 48000.0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let raw = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { throw ClipFailure.data }
        let samples = raw.assumingMemoryBound(to: Int16.self)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let count = Int((seconds * rate).rounded())
        for start in stride(from: 0, to: count, by: 8192) {
            buffer.frameLength = AVAudioFrameCount(min(8192, count - start))
            for index in 0..<Int(buffer.frameLength) {
                let time = Double(start + index) / rate
                let phrase = pow(abs(sin(time * 0.93)), 1.3) * (0.36 + 0.58 * abs(sin(time * 2.73)))
                let envelope = min(1, time * 4, (seconds - time) * 4) * (0.035 + phrase * 0.80)
                samples[index] = Int16(24_000 * envelope * sin(2 * .pi * 180 * time))
            }
            try file.write(from: buffer)
        }
    }
}
