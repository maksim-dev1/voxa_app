import AVFoundation
import os.log

private let log = OSLog(subsystem: "com.pixelio.voxa", category: "AudioMixer")

/// Mixes a mic recording and an optional system-audio recording into a
/// single .m4a file. Runs after both recorders have stopped (offline, not
/// real-time), which keeps the mixing logic simple and glitch-free at the
/// cost of a short processing step once the user hits stop.
enum AudioMixer {
  enum MixError: Error {
    case noInput
  }

  static let commonFormat = AVAudioFormat(
    standardFormatWithSampleRate: 48000, channels: 2)!

  static func mixDown(micPath: String, systemPath: String?, outputPath: String) throws {
    let micURL = URL(fileURLWithPath: micPath)
    guard FileManager.default.fileExists(atPath: micPath) else {
      os_log("mixDown: mic file missing at %{public}@", log: log, type: .error, micPath)
      throw MixError.noInput
    }

    let micFile = try AVAudioFile(forReading: micURL)
    os_log(
      "mixDown: mic file length=%d frames, format=%{public}@", log: log, type: .debug,
      micFile.length, micFile.processingFormat.description)
    let sysFile: AVAudioFile? = {
      guard let systemPath, FileManager.default.fileExists(atPath: systemPath) else {
        os_log("mixDown: no system track, mic-only mix", log: log, type: .debug)
        return nil
      }
      return try? AVAudioFile(forReading: URL(fileURLWithPath: systemPath))
    }()
    if let sysFile {
      os_log(
        "mixDown: system file length=%d frames, format=%{public}@", log: log, type: .debug,
        sysFile.length, sysFile.processingFormat.description)
    }

    // System audio is usually captured much hotter than the mic input, so
    // a plain sample sum leaves the mic barely audible. Measure each
    // track's peak first and normalize both to a common target level
    // before mixing, so voice and system audio come out comparably loud
    // regardless of source gain differences.
    let targetPeak: Float = 0.85
    let maxGain: Float = 8.0

    let micPeak = try peakAmplitude(of: micFile)
    micFile.framePosition = 0
    let micGain = micPeak > 0.001 ? min(targetPeak / micPeak, maxGain) : 1.0

    var sysGain: Float = 1.0
    if let sysFile {
      let sysPeak = try peakAmplitude(of: sysFile)
      sysFile.framePosition = 0
      sysGain = sysPeak > 0.001 ? min(targetPeak / sysPeak, maxGain) : 1.0
    }
    os_log(
      "mixDown: micPeak=%.3f micGain=%.2f sysGain=%.2f", log: log, type: .info, micPeak, micGain,
      sysGain)

    let outURL = URL(fileURLWithPath: outputPath)
    try? FileManager.default.removeItem(at: outURL)

    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48000,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: 128000,
    ]
    let outputFile = try AVAudioFile(
      forWriting: outURL, settings: outputSettings, commonFormat: .pcmFormatFloat32,
      interleaved: false)

    let micReader = TrackReader(file: micFile, targetFormat: commonFormat)
    let sysReader = sysFile.map { TrackReader(file: $0, targetFormat: commonFormat) }

    let chunkFrames: AVAudioFrameCount = 4096
    var totalFramesWritten: Int64 = 0
    var chunkCount = 0

    while true {
      let micBuffer = try micReader.nextChunk(frameCount: chunkFrames)
      let sysBuffer = try sysReader?.nextChunk(frameCount: chunkFrames)

      if micBuffer == nil && (sysBuffer == nil || sysReader == nil) {
        break
      }

      let mixed = mix(
        a: micBuffer, aGain: micGain, b: sysBuffer, bGain: sysGain, frameCount: chunkFrames,
        format: commonFormat)
      if mixed.frameLength > 0 {
        try outputFile.write(from: mixed)
        totalFramesWritten += Int64(mixed.frameLength)
        chunkCount += 1
      } else {
        break
      }
    }
    os_log(
      "mixDown: wrote %d chunks, %d frames (%.1fs) to %{public}@", log: log, type: .info,
      chunkCount, totalFramesWritten, Double(totalFramesWritten) / 48000.0, outputPath)
  }

  /// Decodes an m4a file and returns `buckets` peak-amplitude samples
  /// (0...1), for a lightweight waveform preview in the UI.
  static func extractWaveform(path: String, buckets: Int) throws -> [Double] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let totalFrames = Int(file.length)
    guard totalFrames > 0, buckets > 0 else { return [] }

    let framesPerBucket = max(1, totalFrames / buckets)
    var result = [Double](repeating: 0, count: buckets)

    let chunkFrames: AVAudioFrameCount = 4096
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: chunkFrames)
    else { return result }

    var framesRead = 0
    var bucketIndex = 0
    var bucketPeak: Float = 0
    var framesInBucket = 0
    let channels = Int(file.processingFormat.channelCount)

    while framesRead < totalFrames {
      buffer.frameLength = 0
      try file.read(into: buffer, frameCount: chunkFrames)
      let n = Int(buffer.frameLength)
      if n == 0 { break }

      for frame in 0..<n {
        var sample: Float = 0
        for ch in 0..<channels {
          if let data = buffer.floatChannelData?[ch] {
            sample = max(sample, abs(data[frame]))
          }
        }
        bucketPeak = max(bucketPeak, sample)
        framesInBucket += 1
        if framesInBucket >= framesPerBucket && bucketIndex < buckets {
          result[bucketIndex] = Double(bucketPeak)
          bucketIndex += 1
          bucketPeak = 0
          framesInBucket = 0
        }
      }
      framesRead += n
    }
    if bucketIndex < buckets {
      result[bucketIndex] = Double(bucketPeak)
    }
    return result
  }

  private static func mix(
    a: AVAudioPCMBuffer?, aGain: Float, b: AVAudioPCMBuffer?, bGain: Float,
    frameCount: AVAudioFrameCount, format: AVAudioFormat
  ) -> AVAudioPCMBuffer {
    let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    let length = max(a?.frameLength ?? 0, b?.frameLength ?? 0)
    out.frameLength = length

    let channels = Int(format.channelCount)
    for ch in 0..<channels {
      guard let outData = out.floatChannelData?[ch] else { continue }
      let aData = a?.floatChannelData?[ch]
      let bData = b?.floatChannelData?[ch]
      for frame in 0..<Int(length) {
        let av = (aData != nil && frame < Int(a!.frameLength)) ? aData![frame] * aGain : 0
        let bv = (bData != nil && frame < Int(b!.frameLength)) ? bData![frame] * bGain : 0
        outData[frame] = max(-1.0, min(1.0, av + bv))
      }
    }
    return out
  }

  /// Scans a whole file and returns its peak absolute sample value
  /// (0...1), used to normalize track loudness before mixing. Leaves the
  /// file's read position at the end — callers must reset it to 0 before
  /// reading again.
  private static func peakAmplitude(of file: AVAudioFile) throws -> Float {
    let chunkFrames: AVAudioFrameCount = 4096
    guard
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames)
    else { return 0 }

    var peak: Float = 0
    let channels = Int(file.processingFormat.channelCount)
    while true {
      buffer.frameLength = 0
      try file.read(into: buffer, frameCount: chunkFrames)
      let n = Int(buffer.frameLength)
      if n == 0 { break }
      for ch in 0..<channels {
        guard let data = buffer.floatChannelData?[ch] else { continue }
        for i in 0..<n {
          peak = max(peak, abs(data[i]))
        }
      }
    }
    return peak
  }
}

/// Reads a file in fixed-size chunks, converting to a common PCM format on
/// the fly. Returns nil once the underlying file is exhausted.
private class TrackReader {
  private let file: AVAudioFile
  private let converter: AVAudioConverter?
  private let sourceFormat: AVAudioFormat
  private var reachedEnd = false

  init(file: AVAudioFile, targetFormat: AVAudioFormat) {
    self.file = file
    self.sourceFormat = file.processingFormat
    self.converter =
      sourceFormat == targetFormat ? nil : AVAudioConverter(from: sourceFormat, to: targetFormat)
  }

  func nextChunk(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
    if reachedEnd { return nil }

    guard
      let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
    else { return nil }
    try file.read(into: sourceBuffer, frameCount: frameCount)

    if sourceBuffer.frameLength == 0 {
      reachedEnd = true
      return nil
    }
    if sourceBuffer.frameLength < frameCount {
      reachedEnd = true
    }

    guard let converter else { return sourceBuffer }

    guard
      let outBuffer = AVAudioPCMBuffer(
        pcmFormat: converter.outputFormat, frameCapacity: frameCount)
    else { return sourceBuffer }

    var delivered = false
    var conversionError: NSError?
    converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
      if delivered {
        outStatus.pointee = .noDataNow
        return nil
      }
      delivered = true
      outStatus.pointee = .haveData
      return sourceBuffer
    }
    return outBuffer
  }
}
