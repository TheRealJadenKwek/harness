import Foundation
import Speech
import AVFoundation

/// Hold-to-talk dictation. Prefers on-device recognition (no audio leaves the phone) when the
/// locale model is available. @Published updates are marshalled to main; audio/recognition
/// callbacks run off-main, so this is a plain ObservableObject (not @MainActor).
final class SpeechRecognizer: ObservableObject {
    enum Status: Equatable { case idle, recording, denied, unavailable }

    @Published var transcript = ""
    @Published var isRecording = false
    @Published var status: Status = .idle

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let engine = AVAudioEngine()
    private var wantsToRecord = false        // set synchronously so a fast release cancels a pending start

    func start() {
        wantsToRecord = true
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            guard let self else { return }
            guard auth == .authorized else { self.setStatus(.denied); return }
            self.requestMic { granted in
                guard granted else { self.setStatus(.denied); return }
                DispatchQueue.main.async { self.begin() }
            }
        }
    }

    private func requestMic(_ cb: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission(completionHandler: cb)
    }

    private func begin() {
        guard wantsToRecord else { return }                   // user already released -> don't start
        guard let recognizer, recognizer.isAvailable else { setStatus(.unavailable); return }
        teardown()                                            // clean slate

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { setStatus(.unavailable); return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let node = engine.inputNode
        let fmt = node.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { teardown(); setStatus(.unavailable); return }
        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak req] buf, _ in
            req?.append(buf)
        }
        engine.prepare()
        do { try engine.start() } catch { teardown(); setStatus(.unavailable); return }

        DispatchQueue.main.async { self.isRecording = true; self.status = .recording; self.transcript = "" }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.transcript = text }
            }
            if error != nil || (result?.isFinal ?? false) {
                DispatchQueue.main.async { self.stop() }       // teardown touches engine -> keep on main
            }
        }
    }

    func stop() {
        wantsToRecord = false
        teardown()
        if Thread.isMainThread {
            if isRecording { isRecording = false }
            if status == .recording { status = .idle }
        } else {
            DispatchQueue.main.async {
                if self.isRecording { self.isRecording = false }
                if self.status == .recording { self.status = .idle }
            }
        }
    }

    /// Tear down audio graph + session unconditionally (safe to call when nothing is running).
    private func teardown() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)          // safe even if no tap installed
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func setStatus(_ s: Status) {
        DispatchQueue.main.async { self.status = s; self.isRecording = false }
    }
}
