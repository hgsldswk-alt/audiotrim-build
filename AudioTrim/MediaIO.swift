import AVFoundation
import CoreMedia
import Foundation

enum MediaIO {
    struct Decoded {
        let rate: Int
        let channels: Int
        let frames: Int64
        let track: Int
        let wave: WavePeaks
    }

    static func decode(_ url: URL, to destination: URL) async throws -> Decoded {
        let asset = AVURLAsset(url: url)
        do {
            if try await asset.load(.hasProtectedContent) { throw ClipFailure.protected }
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            if tracks.isEmpty {
                let videos = try await asset.loadTracks(withMediaType: .video)
                throw videos.isEmpty ? ClipFailure.unsupported : ClipFailure.noAudio
            }
            var issue = ClipFailure.unsupported
            for (index, track) in tracks.enumerated() {
                do {
                    let formatDescriptions = try await track.load(.formatDescriptions)
                    guard let description = formatDescriptions.first,
                          let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                        continue
                    }
                    let channels = Int(basic.mChannelsPerFrame)
                    guard (1...2).contains(channels) else { issue = .channels; continue }
                    let range = try await track.load(.timeRange)
                    let segments = try? await track.load(.segments)
                    try Task.checkCancellation()
                    let mediaStart = segments?.first { !$0.isEmpty }?.timeMapping.target.start
                    let start = max(range.start, mediaStart ?? range.start)
                    return try decodeTrack(asset, track: track, index: index, start: start,
                                           rate: basic.mSampleRate, channels: channels, to: destination)
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    try Task.checkCancellation()
                    let mapped = map(error, fallback: .damaged)
                    if mapped == .storage { throw mapped }
                    issue = mapped
                }
            }
            throw issue
        } catch {
            try Task.checkCancellation()
            throw map(error, fallback: .damaged)
        }
    }

    private static func decodeTrack(_ asset: AVAsset, track: AVAssetTrack, index: Int, start: CMTime,
                                    rate: Double, channels: Int, to destination: URL) throws -> Decoded {
        guard rate.isFinite, (1000...384000).contains(rate),
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate,
                                              channels: AVAudioChannelCount(channels), interleaved: true) else {
            throw ClipFailure.unsupported
        }
        let outputRate = rate == 44100 ? 44100 : 48000
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(outputRate),
                                         channels: AVAudioChannelCount(channels), interleaved: true) else {
            throw ClipFailure.unsupported
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ClipFailure.unsupported }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ClipFailure.damaged }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let file = try AVAudioFile(forWriting: destination, settings: format.settings,
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        let converter = rate == Double(outputRate) ? nil : AVAudioConverter(from: inputFormat, to: format)
        if rate != Double(outputRate) && converter == nil { throw ClipFailure.unsupported }
        let peaks = PeakCollector(rate: outputRate)
        var inputPosition: Int64 = 0

        func emit(_ buffer: AVAudioPCMBuffer) throws {
            guard buffer.frameLength > 0 else { return }
            try file.write(from: buffer)
            peaks.add(buffer)
        }

        func feed(_ buffer: AVAudioPCMBuffer?) throws {
            guard let converter else {
                if let buffer { try emit(buffer) }
                return
            }
            let frames = Double(buffer?.frameLength ?? 0)
            let capacity = AVAudioFrameCount(ceil(frames * Double(outputRate) / rate) + 4096)
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw ClipFailure.damaged
            }
            var provided = false
            repeat {
                var conversionError: NSError?
                let status = converter.convert(to: converted, error: &conversionError) { _, state in
                    if let buffer, !provided {
                        provided = true
                        state.pointee = .haveData
                        return buffer
                    }
                    state.pointee = buffer == nil ? .endOfStream : .noDataNow
                    return nil
                }
                if status == .error { throw conversionError ?? ClipFailure.damaged }
                try emit(converted)
                if status != .haveData || converted.frameLength == 0 { return }
                converted.frameLength = 0
            } while true
        }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let length = CMSampleBufferGetNumSamples(sample)
            guard length > 0 else { continue }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw ClipFailure.damaged }
            let delta = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), start).seconds
            let position = delta.isFinite && abs(delta) < 1e9 ? Int64((delta * rate).rounded()) : inputPosition
            while position > inputPosition {
                try Task.checkCancellation()
                let count = Int(min(position - inputPosition, 8192))
                guard let silence = pcmBuffer(inputFormat, frames: count),
                      let pointer = silence.mutableAudioBufferList.pointee.mBuffers.mData else { throw ClipFailure.damaged }
                pointer.initializeMemory(as: UInt8.self, repeating: 0, count: count * channels * 2)
                try feed(silence)
                inputPosition += Int64(count)
            }
            let offset = Int(min(Int64(length), max(0, inputPosition - position)))
            let count = length - offset
            guard count > 0 else { continue }
            guard let buffer = pcmBuffer(inputFormat, frames: count),
                  let pointer = buffer.mutableAudioBufferList.pointee.mBuffers.mData,
                  CMBlockBufferCopyDataBytes(block, atOffset: offset * channels * 2,
                                             dataLength: count * channels * 2, destination: pointer) == noErr else {
                throw ClipFailure.damaged
            }
            try feed(buffer)
            inputPosition += Int64(count)
        }
        guard reader.status == .completed else { throw reader.error ?? ClipFailure.damaged }
        try feed(nil)
        guard file.framePosition > 0 else { throw ClipFailure.noAudio }
        return Decoded(rate: outputRate, channels: channels, frames: file.framePosition, track: index, wave: peaks.finish())
    }

    static func wave(for url: URL, rate: Int) throws -> WavePeaks {
        let source = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let peaks = PeakCollector(rate: rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8192) else {
            throw ClipFailure.damaged
        }
        while source.framePosition < source.length {
            try Task.checkCancellation()
            try source.read(into: buffer)
            guard buffer.frameLength > 0 else { throw ClipFailure.damaged }
            peaks.add(buffer)
        }
        return peaks.finish()
    }

    static func export(_ spec: ExportSpec, source asset: SourceAsset, from url: URL, to destination: URL) async throws {
        guard spec.selection.isValid(total: asset.frames, rate: asset.rate) else { throw ClipFailure.data }
        let source = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard source.length >= spec.selection.end else { throw ClipFailure.damaged }
        source.framePosition = spec.selection.start
        let format = source.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw ClipFailure.export }
        var remaining = spec.selection.count
        if spec.format == .wav {
            let file = try AVAudioFile(forWriting: destination, settings: format.settings,
                                       commonFormat: .pcmFormatInt16, interleaved: true)
            while remaining > 0 {
                try Task.checkCancellation()
                try source.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 8192)))
                guard buffer.frameLength > 0 else { throw ClipFailure.damaged }
                try file.write(from: buffer)
                remaining -= Int64(buffer.frameLength)
            }
            return
        }

        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: asset.rate,
            AVNumberOfChannelsKey: asset.channels, AVEncoderBitRateKey: asset.channels == 1 ? 96000 : 128000
        ], sourceFormatHint: format.formatDescription)
        guard writer.canAdd(input) else { throw ClipFailure.export }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ClipFailure.export }
        writer.startSession(atSourceTime: .zero)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        while remaining > 0 {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? ClipFailure.export }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try source.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 8192)))
            guard buffer.frameLength > 0 else { throw ClipFailure.damaged }
            let timestamp = CMTime(value: spec.selection.count - remaining, timescale: Int32(asset.rate))
            let sample = try makeSample(buffer, timestamp: timestamp, rate: asset.rate, channels: asset.channels)
            guard input.append(sample) else { throw writer.error ?? ClipFailure.export }
            remaining -= Int64(buffer.frameLength)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ClipFailure.export }
    }

    private static func makeSample(_ pcm: AVAudioPCMBuffer, timestamp: CMTime, rate: Int, channels: Int) throws -> CMSampleBuffer {
        let frames = Int(pcm.frameLength)
        var sampleSize = channels * 2
        let bytes = frames * sampleSize
        var data: CMBlockBuffer?
        guard let pointer = pcm.audioBufferList.pointee.mBuffers.mData,
              CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &data) == noErr,
              let data, CMBlockBufferReplaceDataBytes(with: pointer, blockBuffer: data, offsetIntoDestination: 0,
                                                     dataLength: bytes) == noErr else { throw ClipFailure.export }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                                        presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
                                        formatDescription: pcm.format.formatDescription, sampleCount: frames,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
              let sample else { throw ClipFailure.export }
        return sample
    }

    static func pcmBuffer(_ format: AVAudioFormat, frames: Int) -> AVAudioPCMBuffer? {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        buffer?.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    static func map(_ error: Error, fallback: ClipFailure) -> ClipFailure {
        if let failure = error as? ClipFailure { return failure }
        if error is CancellationError { return .paused }
        let failure = error as NSError
        if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteOutOfSpaceError)
            || (failure.domain == NSPOSIXErrorDomain && failure.code == Int(POSIXErrorCode.ENOSPC.rawValue)) {
            return .storage
        }
        if failure.domain == AVFoundationErrorDomain {
            if failure.code == AVError.Code.diskFull.rawValue { return .storage }
            if failure.code == AVError.Code.contentIsProtected.rawValue { return .protected }
            if failure.code == AVError.Code.fileFormatNotRecognized.rawValue { return .unsupported }
        }
        return fallback
    }
}

private final class PeakCollector {
    private let window: Int
    private var values: [UInt16] = []
    private var position = 0
    private var peak: UInt16 = 0

    init(rate: Int) { window = max(1, rate / 200) }

    func add(_ pcm: AVAudioPCMBuffer) {
        let channels = Int(pcm.format.channelCount)
        guard let raw = pcm.audioBufferList.pointee.mBuffers.mData else { return }
        let samples = raw.assumingMemoryBound(to: Int16.self)
        for frame in 0..<Int(pcm.frameLength) {
            for channel in 0..<channels {
                peak = max(peak, samples[frame * channels + channel].magnitude)
            }
            position += 1
            if position == window {
                values.append(peak)
                peak = 0
                position = 0
            }
        }
    }

    func finish() -> WavePeaks {
        if position > 0 { values.append(peak) }
        return WavePeaks(framesPerPeak: window, peaks: values)
    }
}
