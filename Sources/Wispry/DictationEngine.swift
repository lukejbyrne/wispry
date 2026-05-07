import AVFoundation
import Foundation
import Speech

enum DictationEngineError: LocalizedError {
    case speechUnavailable
    case recognitionDenied
    case microphoneDenied
    case noInputAvailable

    var errorDescription: String? {
        switch self {
        case .speechUnavailable:
            return "Speech recognition is not available right now."
        case .recognitionDenied:
            return "Speech recognition permission is required."
        case .microphoneDenied:
            return "Microphone permission is required."
        case .noInputAvailable:
            return "No microphone input is available."
        }
    }
}

final class DictationEngine {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Locale.current.identifier))
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastPartialText = ""
    private var didFinish = false
    private var shouldCommitOnFinish = true

    var onPartial: ((String) -> Void)?
    var onComplete: ((Result<String, Error>) -> Void)?

    var isRunning: Bool {
        audioEngine?.isRunning == true
    }

    func requestPermissions(completion: @escaping (Result<Void, Error>) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { completion(.failure(DictationEngineError.recognitionDenied)) }
                return
            }

            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                DispatchQueue.main.async {
                    allowed ? completion(.success(())) : completion(.failure(DictationEngineError.microphoneDenied))
                }
            }
        }
    }

    func start(contextualStrings: [String]) throws {
        resetRecognition(keepCallbacks: true)

        guard let recognizer, recognizer.isAvailable else {
            throw DictationEngineError.speechUnavailable
        }

        let audioEngine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        request.contextualStrings = contextualStrings

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw DictationEngineError.noInputAvailable
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            request.append(buffer)
        }

        lastPartialText = ""
        didFinish = false
        shouldCommitOnFinish = true
        recognitionRequest = request
        self.audioEngine = audioEngine

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                self.lastPartialText = text
                DispatchQueue.main.async { self.onPartial?(text) }

                if result.isFinal {
                    self.finish(.success(text))
                }
            }

            if let error {
                if self.shouldCommitOnFinish, !self.lastPartialText.isEmpty {
                    self.finish(.success(self.lastPartialText))
                } else {
                    self.finish(.failure(error))
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stopAndCommit() {
        guard isRunning else {
            finish(.success(lastPartialText))
            return
        }

        shouldCommitOnFinish = true
        let snapshot = lastPartialText
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.didFinish else { return }
            self.finish(.success(self.lastPartialText.isEmpty ? snapshot : self.lastPartialText))
        }
    }

    func cancel() {
        shouldCommitOnFinish = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        finish(.success(""))
    }

    private func finish(_ result: Result<String, Error>) {
        guard !didFinish else { return }
        didFinish = true
        resetRecognition(keepCallbacks: true)
        DispatchQueue.main.async { [onComplete] in
            onComplete?(result)
        }
    }

    private func resetRecognition(keepCallbacks: Bool = false) {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil

        if !keepCallbacks {
            onPartial = nil
            onComplete = nil
        }
    }
}
