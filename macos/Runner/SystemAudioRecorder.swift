import Cocoa
import FlutterMacOS
import ScreenCaptureKit
import AVFoundation
import CoreGraphics
import os.log

private let log = OSLog(subsystem: "com.pixelio.voxa", category: "SystemAudio")

/// Records system (output) audio via ScreenCaptureKit and writes it to an
/// .m4a file. Requires macOS 13+ and Screen Recording permission.
@available(macOS 13.0, *)
class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
  private var stream: SCStream?
  private var assetWriter: AVAssetWriter?
  private var audioInput: AVAssetWriterInput?
  private var sessionStarted = false
  private let queue = DispatchQueue(label: "voxa.system_audio.queue")
  private var sampleBufferCount = 0

  /// Latest peak amplitude (0...1) from the captured system audio, updated
  /// on every sample buffer. Polled by Dart for a live level meter.
  private(set) var currentLevel: Double = 0

  func start(path: String, completion: @escaping (Result<Void, Error>) -> Void) {
    os_log("start() path=%{public}@", log: log, type: .info, path)
    Task {
      do {
        os_log("requesting shareable content", log: log, type: .debug)
        let content = try await SCShareableContent.excludingDesktopWindows(
          false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
          os_log("no display found for capture", log: log, type: .error)
          throw NSError(
            domain: "voxa", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No display found for capture"])
        }
        os_log(
          "using display id=%d %dx%d", log: log, type: .debug, display.displayID, display.width,
          display.height)

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // Minimal video to satisfy the stream (audio-only capture still
        // requires a video track configuration); keep it tiny/cheap.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let audioSettings: [String: Any] = [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: 48000,
          AVNumberOfChannelsKey: 2,
          AVEncoderBitRateKey: 128000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        self.assetWriter = writer
        self.audioInput = input
        self.sessionStarted = false
        self.sampleBufferCount = 0

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
        os_log("starting SCStream capture", log: log, type: .debug)
        try await stream.startCapture()
        self.stream = stream
        os_log("SCStream capture started", log: log, type: .info)

        completion(.success(()))
      } catch {
        os_log(
          "start() failed: %{public}@", log: log, type: .error,
          error.localizedDescription)
        completion(.failure(error))
      }
    }
  }

  func stop(completion: @escaping (Result<Void, Error>) -> Void) {
    os_log(
      "stop() called, received %d sample buffers total", log: log, type: .info,
      sampleBufferCount)
    Task {
      do {
        try await self.stream?.stopCapture()
        self.stream = nil
        self.audioInput?.markAsFinished()
        await self.assetWriter?.finishWriting()
        os_log(
          "asset writer finished, status=%d", log: log, type: .info,
          self.assetWriter?.status.rawValue ?? -1)
        self.assetWriter = nil
        self.audioInput = nil
        self.sessionStarted = false
        completion(.success(()))
      } catch {
        os_log(
          "stop() failed: %{public}@", log: log, type: .error, error.localizedDescription)
        completion(.failure(error))
      }
    }
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .audio, sampleBuffer.isValid else { return }
    guard let writer = assetWriter, let input = audioInput else { return }

    sampleBufferCount += 1
    if sampleBufferCount == 1 || sampleBufferCount % 500 == 0 {
      os_log(
        "system audio buffer #%d, level=%.3f", log: log, type: .debug, sampleBufferCount,
        currentLevel)
    }

    updateLevel(from: sampleBuffer)

    if !sessionStarted {
      writer.startWriting()
      writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
      sessionStarted = true
      os_log("asset writer session started", log: log, type: .debug)
    }

    if input.isReadyForMoreMediaData {
      input.append(sampleBuffer)
    } else {
      os_log("system audio input not ready, dropped a buffer", log: log, type: .default)
    }
  }

  private func updateLevel(from sampleBuffer: CMSampleBuffer) {
    guard
      let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
    else { return }
    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard
      CMBlockBufferGetDataPointer(
        blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
        totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
      let dataPointer
    else { return }

    let sampleCount = totalLength / MemoryLayout<Float32>.size
    guard sampleCount > 0 else { return }
    dataPointer.withMemoryRebound(to: Float32.self, capacity: sampleCount) { floats in
      var peak: Float32 = 0
      for i in 0..<sampleCount {
        peak = max(peak, abs(floats[i]))
      }
      currentLevel = Double(min(peak, 1.0))
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    os_log(
      "SCStream stopped with error: %{public}@", log: log, type: .error,
      error.localizedDescription)
  }
}

class SystemAudioRecorderPlugin: NSObject, FlutterPlugin {
  private var recorder: Any?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "voxa/system_audio", binaryMessenger: registrar.messenger)
    let instance = SystemAudioRecorderPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      if #available(macOS 13.0, *) {
        result(true)
      } else {
        result(false)
      }
    case "checkScreenRecordingPermission":
      let granted = CGPreflightScreenCaptureAccess()
      os_log("checkScreenRecordingPermission -> %{public}@", log: log, type: .info, granted ? "granted" : "not granted")
      result(granted)
    case "requestScreenRecordingPermission":
      // Already granted: nothing to prompt for.
      if CGPreflightScreenCaptureAccess() {
        result(true)
        return
      }
      os_log("requesting screen recording permission", log: log, type: .info)
      // Not yet determined (or previously denied): this triggers the
      // system permission alert. It does not block for the user's
      // answer, so poll briefly for the TCC decision to land.
      CGRequestScreenCaptureAccess()
      SystemAudioRecorderPlugin.pollScreenRecordingPermission(attemptsLeft: 20) { granted in
        os_log(
          "requestScreenRecordingPermission resolved -> %{public}@", log: log, type: .info,
          granted ? "granted" : "denied/timeout")
        result(granted)
      }
    case "start":
      guard #available(macOS 13.0, *) else {
        result(
          FlutterError(
            code: "UNSUPPORTED", message: "Requires macOS 13.0+", details: nil))
        return
      }
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String
      else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing path", details: nil))
        return
      }
      let r = SystemAudioRecorder()
      self.recorder = r
      r.start(path: path) { outcome in
        switch outcome {
        case .success:
          result(nil)
        case .failure(let error):
          result(
            FlutterError(
              code: "START_FAILED", message: error.localizedDescription, details: nil))
        }
      }
    case "stop":
      guard #available(macOS 13.0, *), let r = self.recorder as? SystemAudioRecorder else {
        result(nil)
        return
      }
      r.stop { outcome in
        switch outcome {
        case .success:
          result(nil)
        case .failure(let error):
          result(
            FlutterError(
              code: "STOP_FAILED", message: error.localizedDescription, details: nil))
        }
      }
      self.recorder = nil
    case "currentSystemLevel":
      if #available(macOS 13.0, *), let r = self.recorder as? SystemAudioRecorder {
        result(r.currentLevel)
      } else {
        result(0.0)
      }
    case "mixDown":
      guard let args = call.arguments as? [String: Any],
        let micPath = args["micPath"] as? String,
        let outputPath = args["outputPath"] as? String
      else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing micPath/outputPath", details: nil))
        return
      }
      let systemPath = args["systemPath"] as? String
      os_log(
        "mixDown mic=%{public}@ system=%{public}@ out=%{public}@", log: log, type: .info,
        micPath, systemPath ?? "nil", outputPath)
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try AudioMixer.mixDown(
            micPath: micPath, systemPath: systemPath, outputPath: outputPath)
          os_log("mixDown finished OK", log: log, type: .info)
          DispatchQueue.main.async { result(nil) }
        } catch {
          os_log(
            "mixDown failed: %{public}@", log: log, type: .error, error.localizedDescription)
          DispatchQueue.main.async {
            result(
              FlutterError(
                code: "MIX_FAILED", message: error.localizedDescription, details: nil))
          }
        }
      }
    case "extractWaveform":
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String
      else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing path", details: nil))
        return
      }
      let buckets = (args["buckets"] as? Int) ?? 120
      DispatchQueue.global(qos: .utility).async {
        do {
          let waveform = try AudioMixer.extractWaveform(path: path, buckets: buckets)
          DispatchQueue.main.async { result(waveform) }
        } catch {
          os_log(
            "extractWaveform failed: %{public}@", log: log, type: .error,
            error.localizedDescription)
          DispatchQueue.main.async {
            result(
              FlutterError(
                code: "WAVEFORM_FAILED", message: error.localizedDescription, details: nil))
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Polls the TCC decision after CGRequestScreenCaptureAccess() since that
  /// call does not block until the user answers the system prompt.
  static func pollScreenRecordingPermission(
    attemptsLeft: Int, completion: @escaping (Bool) -> Void
  ) {
    if CGPreflightScreenCaptureAccess() {
      completion(true)
      return
    }
    if attemptsLeft <= 0 {
      completion(false)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      pollScreenRecordingPermission(attemptsLeft: attemptsLeft - 1, completion: completion)
    }
  }
}
