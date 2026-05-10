import AudioToolbox
import AVFoundation
import Foundation
import Speech

enum DictationEngineError: LocalizedError {
    case speechUnavailable
    case recognitionDenied
    case microphoneDenied
    case noInputAvailable
    case onDeviceRecognitionUnavailable
    case localWhisperUnavailable
    case localWhisperFailed(String)

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
        case .onDeviceRecognitionUnavailable:
            return "On-device Speech Recognition is not available for the current macOS language."
        case .localWhisperUnavailable:
            return "Local Whisper is not installed. Install whisper.cpp or the whisper CLI, or switch back to Apple on-device Speech."
        case .localWhisperFailed(let message):
            return message.isEmpty ? "Local Whisper transcription failed." : message
        }
    }
}

final class DictationEngine {
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recordingFile: AVAudioFile?
    private var recordingFileURL: URL?
    private var localWhisperProcess: Process?
    private var localWhisperServerProcess: Process?
    private var localWhisperServerLogHandle: FileHandle?
    private var localWhisperServerModelURL: URL?
    private var localWhisperServerLanguageCode: String?
    private var localWhisperRequestTask: URLSessionTask?
    private static let localWhisperServerPort = 18131
    private var transcriptAccumulator = TranscriptAccumulator()
    private var lastPartialText = ""
    private var didFinish = false
    private var shouldCommitOnFinish = true
    private var sessionID: UInt64 = 0
    private var activeSpeechModel: SpeechModel = .appleOnDevice
    private var activeLanguageIdentifier = Locale.current.identifier
    private var activeMicrophoneUniqueID: String?

    var onPartial: ((String) -> Void)?
    var onComplete: ((Result<String, Error>) -> Void)?

    var isRunning: Bool {
        audioEngine?.isRunning == true
    }

    var usesDelayedExternalTranscription: Bool {
        activeSpeechModel == .localWhisper
    }

    func requestPermissions(model: SpeechModel, completion: @escaping (Result<Void, Error>) -> Void) {
        if model == .localWhisper {
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                DispatchQueue.main.async {
                    allowed ? completion(.success(())) : completion(.failure(DictationEngineError.microphoneDenied))
                }
            }
            return
        }

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

    func start(
        model: SpeechModel,
        contextualStrings: [String],
        languageIdentifier: String = Locale.current.identifier,
        microphoneUniqueID: String? = nil
    ) throws {
        resetRecognition(keepCallbacks: true)
        sessionID &+= 1
        let sessionID = sessionID
        activeSpeechModel = model
        activeLanguageIdentifier = languageIdentifier
        activeMicrophoneUniqueID = microphoneUniqueID

        switch model {
        case .appleOnDevice:
            try startAppleSpeech(contextualStrings: contextualStrings, languageIdentifier: languageIdentifier, sessionID: sessionID)
        case .localWhisper:
            try startLocalWhisperRecording(sessionID: sessionID)
        }
    }

    func transcribeFile(sourceURL: URL, languageIdentifier: String = Locale.current.identifier) throws {
        guard Self.localWhisperBackend(languageIdentifier: languageIdentifier) != nil else {
            throw DictationEngineError.localWhisperUnavailable
        }

        resetRecognition(keepCallbacks: true)
        sessionID &+= 1
        let sessionID = sessionID
        activeSpeechModel = .localWhisper
        activeLanguageIdentifier = languageIdentifier
        activeMicrophoneUniqueID = nil
        transcriptAccumulator.reset()
        lastPartialText = ""
        didFinish = false
        shouldCommitOnFinish = true

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WispryWhisper", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let extensionPart = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension
        let temporaryURL = directory
            .appendingPathComponent("file-\(UUID().uuidString)")
            .appendingPathExtension(extensionPart)
        try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)

        DispatchQueue.main.async { [onPartial] in
            onPartial?("Transcribing file locally with Whisper...")
        }
        transcribeWithLocalWhisper(audioURL: temporaryURL, sessionID: sessionID)
    }

    private func startAppleSpeech(contextualStrings: [String], languageIdentifier: String, sessionID: UInt64) throws {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageIdentifier))
        guard let recognizer, recognizer.isAvailable else {
            throw DictationEngineError.speechUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw DictationEngineError.onDeviceRecognitionUnavailable
        }

        let audioEngine = AVAudioEngine()
        try Self.applyInputDevice(activeMicrophoneUniqueID, to: audioEngine)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
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

        transcriptAccumulator.reset()
        lastPartialText = ""
        didFinish = false
        shouldCommitOnFinish = true
        recognitionRequest = request
        self.audioEngine = audioEngine

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, sessionID == self.sessionID else { return }

            if let result {
                let transcription = result.bestTranscription
                let text = self.transcriptAccumulator.ingest(
                    transcription.formattedString,
                    firstSegmentTimestamp: transcription.segments.first?.timestamp
                )
                self.lastPartialText = text
                DispatchQueue.main.async { self.onPartial?(text) }

                if result.isFinal {
                    self.finish(.success(text), sessionID: sessionID)
                }
            }

            if let error {
                if self.shouldCommitOnFinish, !self.lastPartialText.isEmpty {
                    self.finish(.success(self.lastPartialText), sessionID: sessionID)
                } else {
                    self.finish(.failure(error), sessionID: sessionID)
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func startLocalWhisperRecording(sessionID: UInt64) throws {
        guard Self.localWhisperBackend(languageIdentifier: activeLanguageIdentifier) != nil else {
            throw DictationEngineError.localWhisperUnavailable
        }

        let audioEngine = AVAudioEngine()
        try Self.applyInputDevice(activeMicrophoneUniqueID, to: audioEngine)
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw DictationEngineError.noInputAvailable
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WispryWhisper", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let audioURL = directory.appendingPathComponent("recording-\(UUID().uuidString).caf")
        let audioFile = try AVAudioFile(forWriting: audioURL, settings: inputFormat.settings)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self, sessionID == self.sessionID else { return }
            do {
                try self.recordingFile?.write(from: buffer)
            } catch {
                self.finish(.failure(error), sessionID: sessionID)
            }
        }

        transcriptAccumulator.reset()
        lastPartialText = ""
        didFinish = false
        shouldCommitOnFinish = true
        recordingFile = audioFile
        recordingFileURL = audioURL
        self.audioEngine = audioEngine

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stopAndCommit() {
        let sessionID = sessionID
        guard isRunning else {
            finish(.success(lastPartialText), sessionID: sessionID)
            return
        }

        shouldCommitOnFinish = true
        let snapshot = lastPartialText
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)

        if activeSpeechModel == .localWhisper {
            let audioURL = recordingFileURL
            recordingFile = nil
            recordingFileURL = nil
            DispatchQueue.main.async { [onPartial] in
                onPartial?("Transcribing locally with Whisper...")
            }
            transcribeWithLocalWhisper(audioURL: audioURL, sessionID: sessionID)
            return
        }

        recognitionRequest?.endAudio()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, sessionID == self.sessionID, !self.didFinish else { return }
            self.finish(.success(self.lastPartialText.isEmpty ? snapshot : self.lastPartialText), sessionID: sessionID)
        }
    }

    func cancel() {
        sessionID &+= 1
        let sessionID = sessionID
        shouldCommitOnFinish = false
        localWhisperRequestTask?.cancel()
        localWhisperRequestTask = nil
        localWhisperProcess?.terminate()
        localWhisperProcess = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        finish(.success(""), sessionID: sessionID)
    }

    func shutdown() {
        cancel()
        localWhisperServerProcess?.terminate()
        localWhisperServerProcess = nil
        localWhisperServerModelURL = nil
        localWhisperServerLanguageCode = nil
        try? localWhisperServerLogHandle?.close()
        localWhisperServerLogHandle = nil
    }

    private func finish(_ result: Result<String, Error>, sessionID: UInt64) {
        guard sessionID == self.sessionID else { return }
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
        recordingFile = nil
        recordingFileURL = nil
        transcriptAccumulator.reset()

        if !keepCallbacks {
            onPartial = nil
            onComplete = nil
        }
    }

    private func transcribeWithLocalWhisper(audioURL: URL?, sessionID: UInt64) {
        guard let audioURL, let backend = Self.localWhisperBackend(languageIdentifier: activeLanguageIdentifier) else {
            finish(.failure(DictationEngineError.localWhisperUnavailable), sessionID: sessionID)
            return
        }

        switch backend {
        case .whisperCppServer(let serverURL, let modelURL):
            transcribeWithWhisperCpp(
                audioURL: audioURL,
                executableURL: nil,
                serverURL: serverURL,
                modelURL: modelURL,
                sessionID: sessionID
            )
        case .whisperCppCli(let executableURL, let modelURL):
            transcribeWithWhisperCpp(
                audioURL: audioURL,
                executableURL: executableURL,
                serverURL: nil,
                modelURL: modelURL,
                sessionID: sessionID
            )
        case .pythonWhisper(let executableURL):
            transcribeWithPythonWhisper(
                audioURL: audioURL,
                executableURL: executableURL,
                sessionID: sessionID
            )
        }
    }

    private func transcribeWithPythonWhisper(audioURL: URL, executableURL: URL, sessionID: UInt64) {
        let outputDirectory = audioURL.deletingLastPathComponent()
        let outputURL = outputDirectory
            .appendingPathComponent(audioURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("txt")
        try? FileManager.default.removeItem(at: outputURL)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = whisperArguments(audioURL: audioURL, outputDirectory: outputDirectory)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            "\(NSHomeDirectory())/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")
        process.environment = environment

        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = outputPipe
        localWhisperProcess = process

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard sessionID == self.sessionID else { return }
                self.localWhisperProcess = nil
                if process.terminationStatus == 0 {
                    let text = (try? String(contentsOf: outputURL, encoding: .utf8))
                        ?? stdout
                    self.finish(.success(Self.normalizeWhisperOutput(text)), sessionID: sessionID)
                } else {
                    let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.finish(.failure(DictationEngineError.localWhisperFailed(message)), sessionID: sessionID)
                }
                try? FileManager.default.removeItem(at: audioURL)
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        do {
            try process.run()
        } catch {
            localWhisperProcess = nil
            finish(.failure(error), sessionID: sessionID)
        }
    }

    private func transcribeWithWhisperCpp(audioURL: URL, executableURL: URL?, serverURL: URL?, modelURL: URL, sessionID: UInt64) {
        guard let ffmpegURL = Self.ffmpegExecutableURL() else {
            finish(.failure(DictationEngineError.localWhisperFailed("ffmpeg is required for Local Whisper fast mode.")), sessionID: sessionID)
            return
        }

        let outputDirectory = audioURL.deletingLastPathComponent()
        let wavURL = outputDirectory
            .appendingPathComponent(audioURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("wav")
        let outputBaseURL = outputDirectory
            .appendingPathComponent("\(audioURL.deletingPathExtension().lastPathComponent)-cpp")
        let outputTextURL = outputBaseURL.appendingPathExtension("txt")
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: outputTextURL)

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-y",
            "-loglevel", "error",
            "-i", audioURL.path,
            "-ar", "16000",
            "-ac", "1",
            "-c:a", "pcm_s16le",
            wavURL.path
        ]
        process.environment = Self.processEnvironment()

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        localWhisperProcess = process

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard sessionID == self.sessionID else { return }
                self.localWhisperProcess = nil
                guard process.terminationStatus == 0 else {
                    self.finish(
                        .failure(DictationEngineError.localWhisperFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))),
                        sessionID: sessionID
                    )
                    try? FileManager.default.removeItem(at: audioURL)
                    try? FileManager.default.removeItem(at: wavURL)
                    return
                }
                if let serverURL {
                    self.runWhisperCppServer(
                        serverURL: serverURL,
                        modelURL: modelURL,
                        audioURL: audioURL,
                        wavURL: wavURL,
                        outputTextURL: outputTextURL,
                        sessionID: sessionID
                    )
                } else if let executableURL {
                    self.runWhisperCpp(
                        executableURL: executableURL,
                        modelURL: modelURL,
                        audioURL: audioURL,
                        wavURL: wavURL,
                        outputBaseURL: outputBaseURL,
                        outputTextURL: outputTextURL,
                        sessionID: sessionID
                    )
                } else {
                    self.finish(.failure(DictationEngineError.localWhisperUnavailable), sessionID: sessionID)
                    try? FileManager.default.removeItem(at: audioURL)
                    try? FileManager.default.removeItem(at: wavURL)
                }
            }
        }

        do {
            try process.run()
        } catch {
            localWhisperProcess = nil
            finish(.failure(error), sessionID: sessionID)
        }
    }

    private func runWhisperCpp(
        executableURL: URL,
        modelURL: URL,
        audioURL: URL,
        wavURL: URL,
        outputBaseURL: URL,
        outputTextURL: URL,
        sessionID: UInt64
    ) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = whisperCppArguments(
            wavURL: wavURL,
            modelURL: modelURL,
            outputBaseURL: outputBaseURL
        )
        process.environment = Self.processEnvironment()

        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = outputPipe
        localWhisperProcess = process

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard sessionID == self.sessionID else { return }
                self.localWhisperProcess = nil
                if process.terminationStatus == 0 {
                    let text = (try? String(contentsOf: outputTextURL, encoding: .utf8)) ?? stdout
                    self.finish(.success(Self.normalizeWhisperOutput(text)), sessionID: sessionID)
                } else {
                    let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.finish(.failure(DictationEngineError.localWhisperFailed(message)), sessionID: sessionID)
                }
                try? FileManager.default.removeItem(at: audioURL)
                try? FileManager.default.removeItem(at: wavURL)
                try? FileManager.default.removeItem(at: outputTextURL)
            }
        }

        do {
            try process.run()
        } catch {
            localWhisperProcess = nil
            finish(.failure(error), sessionID: sessionID)
        }
    }

    private func runWhisperCppServer(
        serverURL: URL,
        modelURL: URL,
        audioURL: URL,
        wavURL: URL,
        outputTextURL: URL,
        sessionID: UInt64
    ) {
        let languageCode = Self.whisperLanguageCode(for: activeLanguageIdentifier) ?? "auto"
        ensureWarmWhisperServer(serverURL: serverURL, modelURL: modelURL, languageCode: languageCode) { [weak self] result in
            guard let self else { return }
            guard sessionID == self.sessionID else {
                Self.removeLocalWhisperFiles(audioURL: audioURL, wavURL: wavURL, outputTextURL: outputTextURL)
                return
            }

            switch result {
            case .success:
                self.postWavToWhisperServer(serverURL: serverURL, wavURL: wavURL) { [weak self] result in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        self.localWhisperRequestTask = nil
                        guard sessionID == self.sessionID else {
                            Self.removeLocalWhisperFiles(audioURL: audioURL, wavURL: wavURL, outputTextURL: outputTextURL)
                            return
                        }

                        switch result {
                        case .success(let text):
                            self.finish(.success(Self.normalizeWhisperOutput(text)), sessionID: sessionID)
                        case .failure(let error):
                            self.finish(.failure(error), sessionID: sessionID)
                        }
                        Self.removeLocalWhisperFiles(audioURL: audioURL, wavURL: wavURL, outputTextURL: outputTextURL)
                    }
                }
            case .failure(let error):
                self.finish(.failure(error), sessionID: sessionID)
                Self.removeLocalWhisperFiles(audioURL: audioURL, wavURL: wavURL, outputTextURL: outputTextURL)
            }
        }
    }

    private func ensureWarmWhisperServer(
        serverURL: URL,
        modelURL: URL,
        languageCode: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if let process = localWhisperServerProcess,
           process.isRunning,
           localWhisperServerModelURL == modelURL,
           localWhisperServerLanguageCode == languageCode {
            DispatchQueue.global(qos: .userInitiated).async {
                let ready = Self.whisperServerResponds(serverURL: serverURL)
                DispatchQueue.main.async {
                    ready
                        ? completion(.success(()))
                        : self.startWarmWhisperServer(
                            serverURL: serverURL,
                            modelURL: modelURL,
                            languageCode: languageCode,
                            completion: completion
                        )
                }
            }
            return
        }

        startWarmWhisperServer(serverURL: serverURL, modelURL: modelURL, languageCode: languageCode, completion: completion)
    }

    private func startWarmWhisperServer(
        serverURL: URL,
        modelURL: URL,
        languageCode: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        localWhisperServerProcess?.terminate()
        localWhisperServerProcess = nil
        localWhisperServerModelURL = nil
        localWhisperServerLanguageCode = nil
        try? localWhisperServerLogHandle?.close()
        localWhisperServerLogHandle = nil

        guard let serverExecutableURL = Self.whisperServerExecutableURL() else {
            completion(.failure(DictationEngineError.localWhisperUnavailable))
            return
        }

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WispryWhisper", isDirectory: true)
            .appendingPathComponent("whisper-server.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        localWhisperServerLogHandle = try? FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = serverExecutableURL
        process.arguments = [
            "-m", modelURL.path,
            "--host", "127.0.0.1",
            "--port", "\(Self.localWhisperServerPort)",
            "-t", "\(Self.whisperCppThreadCount())",
            "-bo", "1",
            "-bs", "1",
            "-nt",
            "-l", languageCode
        ]
        process.environment = Self.processEnvironment()
        if let logHandle = localWhisperServerLogHandle {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        do {
            try process.run()
        } catch {
            completion(.failure(error))
            return
        }

        localWhisperServerProcess = process
        localWhisperServerModelURL = modelURL
        localWhisperServerLanguageCode = languageCode

        DispatchQueue.global(qos: .userInitiated).async {
            var ready = false
            for _ in 0..<48 {
                if !process.isRunning { break }
                if Self.whisperServerResponds(serverURL: serverURL) {
                    ready = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.125)
            }

            DispatchQueue.main.async {
                if ready {
                    completion(.success(()))
                } else {
                    let message = process.isRunning
                        ? "Local Whisper server did not become ready."
                        : "Local Whisper server exited before it was ready."
                    completion(.failure(DictationEngineError.localWhisperFailed(message)))
                }
            }
        }
    }

    private func postWavToWhisperServer(
        serverURL: URL,
        wavURL: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let boundary = "WispryBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: serverURL.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("", forHTTPHeaderField: "Expect")

        do {
            let body = try Self.multipartWhisperBody(wavURL: wavURL, boundary: boundary)
            let task = URLSession.shared.uploadTask(with: request, from: body) { data, response, error in
                if let error {
                    completion(.failure(DictationEngineError.localWhisperFailed(error.localizedDescription)))
                    return
                }

                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard (200..<300).contains(statusCode) else {
                    completion(.failure(DictationEngineError.localWhisperFailed(bodyText)))
                    return
                }

                if let data,
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = object["text"] as? String {
                    completion(.success(text))
                } else {
                    completion(.success(bodyText))
                }
            }
            localWhisperRequestTask = task
            task.resume()
        } catch {
            completion(.failure(error))
        }
    }

    private func whisperArguments(audioURL: URL, outputDirectory: URL) -> [String] {
        var arguments = [
            audioURL.path,
            "--model", Self.defaultWhisperModelName(languageIdentifier: activeLanguageIdentifier),
            "--output_format", "txt",
            "--output_dir", outputDirectory.path,
            "--verbose", "False",
            "--condition_on_previous_text", "False",
            "--fp16", "False"
        ]

        if let code = Self.whisperLanguageCode(for: activeLanguageIdentifier) {
            arguments.append(contentsOf: ["--language", code])
        }

        return arguments
    }

    private func whisperCppArguments(wavURL: URL, modelURL: URL, outputBaseURL: URL) -> [String] {
        var arguments = [
            "-m", modelURL.path,
            "-f", wavURL.path,
            "-t", "\(Self.whisperCppThreadCount())",
            "-bo", "1",
            "-bs", "1",
            "-otxt",
            "-of", outputBaseURL.path,
            "-np",
            "-nt"
        ]

        if let code = Self.whisperLanguageCode(for: activeLanguageIdentifier) {
            arguments.append(contentsOf: ["-l", code])
        }

        return arguments
    }

    private static func whisperCppThreadCount() -> Int {
        max(4, min(8, ProcessInfo.processInfo.processorCount - 2))
    }

    private static func normalizeWhisperOutput(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"(?i)(?:\s|^)(?:\[\s*blank[_ ]audio\s*\]|\(\s*blank[_ ]audio\s*\)|<\|nospeech\|>)(?=\s|$)"#, with: " ", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func localWhisperExecutableURL() -> URL? {
        whisperServerExecutableURL() ?? whisperCppExecutableURL() ?? pythonWhisperExecutableURL()
    }

    static func localWhisperStatus(languageIdentifier: String = Locale.current.identifier) -> (detail: String, ready: Bool) {
        switch localWhisperBackend(languageIdentifier: languageIdentifier) {
        case .whisperCppServer(_, let modelURL):
            return ("Warm whisper.cpp server will use \(modelURL.lastPathComponent).", true)
        case .whisperCppCli(_, let modelURL):
            return ("whisper.cpp CLI is ready with \(modelURL.lastPathComponent).", true)
        case .pythonWhisper:
            return ("Local Whisper is ready through the Python CLI fallback.", true)
        case nil:
            return ("Install whisper.cpp with a local model, or choose Apple on-device.", false)
        }
    }

    private enum LocalWhisperBackend {
        case whisperCppServer(serverURL: URL, modelURL: URL)
        case whisperCppCli(executableURL: URL, modelURL: URL)
        case pythonWhisper(executableURL: URL)
    }

    private static func localWhisperBackend(languageIdentifier: String) -> LocalWhisperBackend? {
        if let modelURL = whisperCppModelURL(languageIdentifier: languageIdentifier),
           ffmpegExecutableURL() != nil {
            if whisperServerExecutableURL() != nil,
               let serverURL = whisperServerBaseURL() {
                return .whisperCppServer(serverURL: serverURL, modelURL: modelURL)
            }
            if let executableURL = whisperCppExecutableURL() {
                return .whisperCppCli(executableURL: executableURL, modelURL: modelURL)
            }
        }
        if let executableURL = pythonWhisperExecutableURL() {
            return .pythonWhisper(executableURL: executableURL)
        }
        return nil
    }

    private static func whisperServerBaseURL() -> URL? {
        URL(string: "http://127.0.0.1:\(localWhisperServerPort)/")
    }

    private static func whisperServerExecutableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server"
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func whisperCppExecutableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli"
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func whisperCppModelURL(languageIdentifier: String) -> URL? {
        let cacheDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/whisper.cpp", isDirectory: true)
        let languageCode = Locale(identifier: languageIdentifier).language.languageCode?.identifier
        let candidates = languageCode == "en"
            ? ["ggml-base.en.bin", "ggml-tiny.en.bin", "ggml-base.bin", "ggml-tiny.bin"]
            : ["ggml-base.bin", "ggml-tiny.bin"]
        return candidates
            .map { cacheDirectory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func pythonWhisperExecutableURL() -> URL? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/whisper",
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper"
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func ffmpegExecutableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            "\(NSHomeDirectory())/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")
        return environment
    }

    private static func applyInputDevice(_ uniqueID: String?, to audioEngine: AVAudioEngine) throws {
        guard let uniqueID, !uniqueID.isEmpty else { return }
        guard var deviceID = audioDeviceID(forUniqueID: uniqueID) else { return }
        guard let audioUnit = audioEngine.inputNode.audioUnit else {
            throw DictationEngineError.noInputAvailable
        }

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw DictationEngineError.noInputAvailable
        }
    }

    private static func audioDeviceID(forUniqueID uniqueID: String) -> AudioDeviceID? {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize,
            &devices
        ) == noErr else {
            return nil
        }

        for deviceID in devices {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString?
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            let status = withUnsafeMutablePointer(to: &uid) { uidPointer in
                uidPointer.withMemoryRebound(to: UInt8.self, capacity: Int(uidSize)) { rawPointer in
                    AudioObjectGetPropertyData(
                        deviceID,
                        &uidAddress,
                        0,
                        nil,
                        &uidSize,
                        rawPointer
                    )
                }
            }
            if status == noErr, (uid as String?) == uniqueID {
                return deviceID
            }
        }

        return nil
    }

    private static func whisperServerResponds(serverURL: URL) -> Bool {
        var request = URLRequest(url: serverURL)
        request.timeoutInterval = 0.35

        let semaphore = DispatchSemaphore(value: 0)
        var didRespond = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let response = response as? HTTPURLResponse {
                didRespond = (200..<500).contains(response.statusCode)
            }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 0.5) == .timedOut {
            task.cancel()
        }
        return didRespond
    }

    private static func multipartWhisperBody(wavURL: URL, boundary: String) throws -> Data {
        var body = Data()
        appendMultipartField(name: "response_format", value: "json", boundary: boundary, to: &body)
        appendMultipartField(name: "temperature", value: "0", boundary: boundary, to: &body)
        appendString("--\(boundary)\r\n", to: &body)
        appendString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n", to: &body)
        appendString("Content-Type: audio/wav\r\n\r\n", to: &body)
        body.append(try Data(contentsOf: wavURL))
        appendString("\r\n--\(boundary)--\r\n", to: &body)
        return body
    }

    private static func appendMultipartField(name: String, value: String, boundary: String, to body: inout Data) {
        appendString("--\(boundary)\r\n", to: &body)
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n", to: &body)
        appendString("\(value)\r\n", to: &body)
    }

    private static func appendString(_ string: String, to data: inout Data) {
        data.append(Data(string.utf8))
    }

    private static func removeLocalWhisperFiles(audioURL: URL, wavURL: URL, outputTextURL: URL) {
        try? FileManager.default.removeItem(at: audioURL)
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: outputTextURL)
    }

    private static func defaultWhisperModelName(languageIdentifier: String) -> String {
        let cacheDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/whisper", isDirectory: true)
        let languageCode = Locale(identifier: languageIdentifier).language.languageCode?.identifier
        let preferredModels = languageCode == "en"
            ? ["tiny.en", "tiny", "base", "small"]
            : ["tiny", "base", "small"]
        for model in preferredModels {
            let modelURL = cacheDirectory.appendingPathComponent("\(model).pt")
            if FileManager.default.fileExists(atPath: modelURL.path) {
                return model
            }
        }
        return languageCode == "en" ? "tiny.en" : "tiny"
    }

    private static func whisperLanguageCode(for identifier: String) -> String? {
        let rawLanguageCode = Locale(identifier: identifier).language.languageCode?.identifier
        let languageCode = rawLanguageCode == "nb" ? "no" : rawLanguageCode
        let supported = Set([
            "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr",
            "pl", "ca", "nl", "ar", "sv", "it", "id", "hi", "fi", "vi",
            "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no",
            "th", "ur", "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk",
            "te", "fa", "lv", "bn", "sr", "az", "sl", "kn", "et", "mk",
            "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw",
            "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc",
            "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo",
            "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl",
            "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su", "yue"
        ])
        guard let languageCode, supported.contains(languageCode) else { return nil }
        return languageCode
    }
}
