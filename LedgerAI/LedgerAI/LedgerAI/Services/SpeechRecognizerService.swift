import AVFoundation
import Combine
import Foundation
import Network
import Speech

enum SpeechRecognizerServiceError: Error, LocalizedError {
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "语音识别服务当前不可用。"
        }
    }
}

@MainActor
final class SpeechRecognizerService: ObservableObject {
    @Published var transcript: String = ""
    @Published var isRecording: Bool = false

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "speech.network.monitor")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isNetworkReachable = true
    private var isStoppingGracefully = false

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isNetworkReachable = (path.status == .satisfied)
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func startRecording() throws {
        forceResetSession(clearTranscript: true)
        guard speechRecognizer?.isAvailable == true else {
            throw SpeechRecognizerServiceError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        self.request = request
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = !isNetworkReachable
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

#if canImport(UIKit)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
#endif

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
        isStoppingGracefully = false

        task = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.transcript = result.bestTranscription.formattedString
                if result.isFinal {
                    self.finishTaskCleanup(cancelTask: false)
                    return
                }
            }
            if error != nil {
                self.finishTaskCleanup(cancelTask: true)
            }
        }
    }

    func stopRecording() {
        guard isRecording || request != nil else { return }
        isStoppingGracefully = true
        stopAudioEngine()
        request?.endAudio()
        isRecording = false

        // Wait briefly for final callback; hard-stop if upstream never returns final.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self else { return }
            if self.isStoppingGracefully {
                self.finishTaskCleanup(cancelTask: true)
            }
        }
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func finishTaskCleanup(cancelTask: Bool) {
        stopAudioEngine()
        if cancelTask {
            task?.cancel()
        }
        request = nil
        task = nil
        isStoppingGracefully = false
        isRecording = false
#if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }

    private func forceResetSession(clearTranscript: Bool) {
        stopAudioEngine()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isStoppingGracefully = false
        isRecording = false
        if clearTranscript {
            transcript = ""
        }
#if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }
}
