import AVFoundation
import Testing

extension FixtureTestCase {
    @discardableResult
    func writeVideo(_ name: String = "video.mp4", width: Int = 160, height: Int = 90,
                    frames: Int = 24, rotated: Bool = false, blue: Bool = false,
                    includesVideo: Bool = true, includesAudio: Bool = false, changesToBlueAfter: Int? = nil) async throws -> URL
    {
        let url = fixtureDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        if includesVideo { writer.add(input) }
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ])
        if includesAudio { writer.add(audio) }
        try #require(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        if includesAudio {
            try await waitUntil { audio.isReadyForMoreMediaData || writer.status == .failed }
            try #require(audio.append(try testAudioSample(duration: Double(frames) / 12)))
            audio.markAsFinished()
        }
        if includesVideo {
            for frame in 0..<frames {
                try await waitUntil { input.isReadyForMoreMediaData || writer.status == .failed }
                var pixelBuffer: CVPixelBuffer?
                try #require(CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &pixelBuffer) == kCVReturnSuccess)
                let buffer = try #require(pixelBuffer)
                CVPixelBufferLockBaseAddress(buffer, [])
                let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
                let frameIsBlue = blue || changesToBlueAfter.map { frame >= $0 } == true
                context.setFillColor(CGColor(red: frameIsBlue ? 0.1 : 0.9, green: 0.25, blue: frameIsBlue ? 0.9 : 0.1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.setFillColor(CGColor(gray: 0.95, alpha: 1))
                context.fill(CGRect(x: frame * 5 % max(1, width - 16), y: height / 3, width: 16, height: 16))
                CVPixelBufferUnlockBaseAddress(buffer, [])
                try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)))
            }
            input.markAsFinished()
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 12))
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
        return url.standardizedFileURL
    }
}

private func testAudioSample(duration: Double) throws -> CMSampleBuffer {
    let sampleRate = 44_100.0
    let samples = (0..<Int(duration * sampleRate)).map { Float(sin(Double($0) * 440 * 2 * .pi / sampleRate) * 0.04) }
    var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
        mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    try #require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format) == noErr)
    var block: CMBlockBuffer?
    let bytes = samples.count * MemoryLayout<Float>.size
    try #require(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr)
    let data = try #require(block)
    try samples.withUnsafeBytes { source in
        try #require(CMBlockBufferReplaceDataBytes(with: source.baseAddress!, blockBuffer: data,
            offsetIntoDestination: 0, dataLength: bytes) == noErr)
    }
    var sample: CMSampleBuffer?
    try #require(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
        dataBuffer: data, formatDescription: try #require(format), sampleCount: samples.count,
        presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
}
