import ReplayKit
import AVFoundation
import os.log

class SampleHandler: RPBroadcastSampleHandler {

    private let log = OSLog(subsystem: "com.dujing.translator.broadcast", category: "SampleHandler")
    private let appGroupDefaults = UserDefaults(suiteName: "group.com.dujing.translator")
    private var audioConverter: AVAudioConverter?
    private let targetSampleRate: Double = 16000

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        os_log("Broadcast started", log: log, type: .info)
    }

    override func broadcastPaused() {
        os_log("Broadcast paused", log: log, type: .info)
    }

    override func broadcastResumed() {
        os_log("Broadcast resumed", log: log, type: .info)
    }

    override func broadcastFinished() {
        os_log("Broadcast finished", log: log, type: .info)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .audioApp:
            sendAudioSample(sampleBuffer, type: "audioApp")
        case .audioMic:
            sendAudioSample(sampleBuffer, type: "audioMic")
        case .video:
            break
        @unknown default:
            break
        }
    }

    private func sendAudioSample(_ sampleBuffer: CMSampleBuffer, type: String) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }

        let sampleRate = asbd.pointee.mSampleRate
        let channels = Int(asbd.pointee.mChannelsPerFrame)
        let isPlanar = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        var audioData: [Float] = []

        if isPlanar {
            // Planar format: use AudioBufferList for correct channel access
            var blockBuffer: CMBlockBuffer?
            var audioBufferList = AudioBufferList.allocate(maximumBuffers: channels)
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: audioBufferList.unsafeMutablePointer,
                bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channels),
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard status == noErr else { return }

            // Take first channel only (for mono output)
            let buffer = audioBufferList.unsafePointer.pointee.mBuffers
            if let data = buffer.mData {
                let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                data.withMemoryRebound(to: Float.self, capacity: frameCount) { ptr in
                    audioData = Array(UnsafeBufferPointer(start: ptr, count: frameCount))
                }
            }
        } else {
            // Interleaved format: use CMBlockBufferGetDataPointer
            var lengthAtOffset = Int(0)
            var totalLength = Int(0)
            var dataPointer: UnsafeMutablePointer<CChar>?

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
                  CMBlockBufferGetDataPointer(
                      blockBuffer,
                      atOffset: 0,
                      lengthAtOffsetOut: &lengthAtOffset,
                      totalLengthOut: &totalLength,
                      dataPointerOut: &dataPointer
                  ) == kCMBlockBufferNoErr,
                  let pointer = dataPointer, totalLength > 0 else {
                return
            }

            let floatCount = totalLength / MemoryLayout<Float>.size
            audioData = pointer.withMemoryRebound(to: Float.self, capacity: floatCount) { ptr in
                Array(UnsafeBufferPointer(start: ptr, count: floatCount))
            }

            // Convert stereo to mono by averaging channels
            if channels == 2 {
                var mono: [Float] = []
                mono.reserveCapacity(audioData.count / 2)
                for i in stride(from: 0, to: audioData.count - 1, by: 2) {
                    mono.append((audioData[i] + audioData[i + 1]) / 2.0)
                }
                audioData = mono
            }
        }

        guard !audioData.isEmpty else { return }

        // Resample to 16kHz if needed
        if sampleRate != targetSampleRate {
            let ratio = targetSampleRate / sampleRate
            let newCount = Int(Double(audioData.count) * ratio)
            var resampled = [Float](repeating: 0, count: newCount)
            for i in 0..<newCount {
                let srcIdx = Double(i) / ratio
                let idx = Int(srcIdx)
                let frac = Float(srcIdx - Double(idx))
                if idx + 1 < audioData.count {
                    resampled[i] = audioData[idx] * (1.0 - frac) + audioData[idx + 1] * frac
                } else if idx < audioData.count {
                    resampled[i] = audioData[idx]
                }
            }
            audioData = resampled
        }

        // Send as raw Float data via App Group
        let data = Data(bytes: audioData, count: audioData.count * MemoryLayout<Float>.size)
        let key = "broadcast_\(type)_data"
        appGroupDefaults?.set(data, forKey: key)

        // Notify main app
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = "com.dujing.translator.broadcast.\(type)" as CFString
        CFNotificationCenterPostNotification(center, CFNotificationName(name), nil, nil, true)
    }
}
