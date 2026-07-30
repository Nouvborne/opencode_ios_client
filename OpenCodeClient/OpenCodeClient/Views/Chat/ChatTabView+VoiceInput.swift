import SwiftUI
import os
import os.lock
import VoiceFlowKit
#if os(iOS) || os(visionOS)
@preconcurrency import AVFoundation
#endif

/// Mic-button voice input for the chat composer. Holds the speech
/// session, microphone, heartbeat task, and event consumer task; calls
/// into `AppState.startRealtimeSpeechSession()` to obtain a session
/// from `VoiceFlowKit`. UI states (`isRecording`, `isTranscribing`,
/// `isStartingRecording`, `speechError`, `speechRecoveryActive`) and
/// the session-bearing `@State` fields live on `ChatTabView` itself —
/// SwiftUI requires `@State` on the containing struct — and this
/// extension hosts the lifecycle methods.
///
/// The chat composer intentionally suppresses mid-recording
/// `.partialTranscript` events: OpenCode's UX shows transcript text
/// only after stop. VoiceFlow's recorder shows live partials; see
/// `AppState+LiveSession.swift` in the VoiceFlowKit repo for that flow.

/// Thread-safe buffer for the latest partial transcript. Used to recover
/// a salvageable string when `commitAndStop` fails after partials
/// already streamed in.
final class SpeechPartialTranscriptBuffer: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: "")

    nonisolated func update(_ newValue: String) {
        storage.withLock { $0 = newValue }
    }

    nonisolated func current() -> String {
        storage.withLock { $0 }
    }
}

extension ChatTabView {
    static let speechHeartbeatIntervalSeconds: UInt64 = 12

    static func mergedSpeechInput(prefix: String, transcript: String) -> String {
        let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTranscript.isEmpty else { return prefix }
        guard !prefix.isEmpty else { return cleanedTranscript }
        return prefix + " " + cleanedTranscript
    }

    static func speechFailureInput(prefix: String, lastPartialTranscript: String) -> String {
        mergedSpeechInput(prefix: prefix, transcript: lastPartialTranscript)
    }

    static func requestMicrophonePermissionForRecording() async -> Bool {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    session.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            }
        @unknown default:
            return false
        }
        #else
        return true
        #endif
    }

    func startSpeechHeartbeat(for session: VoiceFlowSession) {
        speechHeartbeatTask?.cancel()
        speechHeartbeatTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Self.speechHeartbeatIntervalSeconds))
                } catch {
                    return
                }
                await session.ping()
            }
        }
    }

    func stopSpeechHeartbeat() {
        speechHeartbeatTask?.cancel()
        speechHeartbeatTask = nil
    }

    func startSpeechAudioLevelConsumer() {
        speechAudioLevelTask?.cancel()
        speechAudioLevel = 0
        let levels = microphone.audioLevel
        speechAudioLevelTask = Task {
            for await level in levels {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    speechAudioLevel = level
                }
            }
        }
    }

    func stopSpeechAudioLevelConsumer() {
        speechAudioLevelTask?.cancel()
        speechAudioLevelTask = nil
        speechAudioLevel = 0
    }

    /// Drain `session.events` so the UI sees phase transitions and recovery
    /// state mid-recording. Otherwise a stream blip is invisible until the
    /// user hits stop and `commitAndStop` either succeeds late or fails.
    func startSpeechEventConsumer(for session: VoiceFlowSession) {
        speechEventTask?.cancel()
        speechEventTask = Task {
            let events = await session.events
            for await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case .recoveryStarted:
                    await MainActor.run { speechRecoveryActive = true }
                case .recoveryFailed(let message):
                    Self.logger.error("[SpeechProfile] realtime recovery failed message=\(message, privacy: .public)")
                    await MainActor.run {
                        speechRecoveryActive = false
                        speechError = L10n.t(.chatSpeechStreamDisconnected)
                    }
                case .phaseChanged(let phase):
                    if phase == .connected, speechRecoveryActive {
                        await MainActor.run { speechRecoveryActive = false }
                    }
                case .partialTranscript:
                    // Mid-recording partial transcripts are intentionally
                    // suppressed in OpenCode's chat composer — the user only
                    // sees text after stop. (See VoiceFlow's recording flow
                    // for the opposite UX.)
                    continue
                }
            }
        }
    }

    func stopSpeechEventConsumer() {
        speechEventTask?.cancel()
        speechEventTask = nil
        speechRecoveryActive = false
    }

    func terminateSpeechSession(_ session: VoiceFlowSession) async {
        do {
            if let preserved = try await session.abortPreservingAudio() {
                state.discardPreservedAudio(preserved)
            }
        } catch {
            Self.logger.error("[SpeechProfile] realtime session termination failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func stopSpeechForBackground() async {
        let hadActiveOperation = isRecording || isStartingRecording || isTranscribing || isRetryingSpeech
        speechStartID = nil
        speechFinalizationID = nil
        speechRetryID = nil
        stopSpeechHeartbeat()
        stopSpeechEventConsumer()
        stopSpeechAudioLevelConsumer()
        if let audioURL = try? await microphone.stop() {
            try? FileManager.default.removeItem(at: audioURL)
        }
        microphone.discard()

        let session = speechSession
        speechSession = nil
        isRecording = false
        isTranscribing = false
        isStartingRecording = false
        isRetryingSpeech = false

        if let session {
            await terminateSpeechSession(session)
        }
        if hadActiveOperation {
            clearPreservedSpeechAudio()
        }
    }

    func toggleRecording() async {
        if isRecording {
            let finalizationID = UUID()
            speechFinalizationID = finalizationID
            let stoppingMicrophone = microphone
            stopSpeechHeartbeat()
            stopSpeechEventConsumer()
            stopSpeechAudioLevelConsumer()
            let stopStart = ProcessInfo.processInfo.systemUptime
            let audioURL = try? await stoppingMicrophone.stop()
            stoppingMicrophone.discard()
            guard speechFinalizationID == finalizationID else {
                if let audioURL {
                    try? FileManager.default.removeItem(at: audioURL)
                }
                return
            }
            isRecording = false
            Self.logger.notice("[SpeechProfile] realtime capture stopped ms=\(max(0, Int((ProcessInfo.processInfo.systemUptime - stopStart) * 1000)), privacy: .public)")

            isTranscribing = true
            let prefix = recordingInputPrefix
            let strategy = activeSpeechStrategy

            if !strategy.usesRealtimeTransport {
                guard let audioURL else {
                    isTranscribing = false
                    speechFinalizationID = nil
                    speechError = L10n.t(.carTranscriptionFailed)
                    return
                }
                preservedSpeechFileURL = audioURL
                preservedSpeechStrategy = strategy
                preservedSpeechInputPrefix = prefix
                do {
                    let transcript = try await state.transcribeAudio(audioFileURL: audioURL, strategy: strategy)
                    guard speechFinalizationID == finalizationID else { return }
                    inputText = Self.mergedSpeechInput(prefix: prefix, transcript: transcript)
                    clearPreservedSpeechAudio()
                } catch {
                    guard speechFinalizationID == finalizationID else { return }
                    Self.logger.error("[SpeechProfile] chat batch transcribe failed error=\(error.localizedDescription, privacy: .public)")
                    speechError = error.localizedDescription
                }
                if speechFinalizationID == finalizationID {
                    speechFinalizationID = nil
                    isTranscribing = false
                }
                return
            }

            if let audioURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
            guard let session = speechSession else {
                isTranscribing = false
                speechFinalizationID = nil
                Self.logger.error("[SpeechProfile] realtime stop failed: missing session")
                return
            }
            defer {
                if speechSession === session {
                    speechSession = nil
                    speechFinalizationID = nil
                    isTranscribing = false
                }
            }
            let partialTranscriptBuffer = SpeechPartialTranscriptBuffer()
            let transcribeStart = ProcessInfo.processInfo.systemUptime
            do {
                let transcript = try await session.commitAndStop { partial in
                    partialTranscriptBuffer.update(partial)
                    Task { @MainActor in
                        guard speechFinalizationID == finalizationID else { return }
                        inputText = Self.mergedSpeechInput(prefix: prefix, transcript: partial)
                    }
                }
                let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard speechSession === session else { return }
                Self.logger.notice("[SpeechProfile] chat realtime transcribe done ms=\(max(0, Int((ProcessInfo.processInfo.systemUptime - transcribeStart) * 1000)), privacy: .public) chars=\(cleaned.count, privacy: .public)")
                inputText = Self.mergedSpeechInput(prefix: prefix, transcript: cleaned)
                clearPreservedSpeechAudio()
                await terminateSpeechSession(session)
            } catch {
                await terminateSpeechSession(session)
                guard speechSession === session else { return }
                Self.logger.error("[SpeechProfile] chat realtime transcribe failed ms=\(max(0, Int((ProcessInfo.processInfo.systemUptime - transcribeStart) * 1000)), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                inputText = Self.speechFailureInput(prefix: prefix, lastPartialTranscript: partialTranscriptBuffer.current())
                speechError = error.localizedDescription
            }
        } else {
            guard !isStartingRecording else { return }
            // VoiceFlowMicrophone.audioLevel is tied to the microphone instance's
            // AsyncStream continuation. Recreate it per capture so repeated
            // start/stop cycles keep publishing real levels for the waveform.
            let startingMicrophone = VoiceFlowMicrophone()
            microphone = startingMicrophone
            let token = state.aiBuilderToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                speechError = L10n.t(.chatSpeechTokenMissing)
                return
            }
            if state.isTestingAIBuilderConnection {
                speechError = L10n.t(.chatSpeechTesting)
                return
            }
            guard state.aiBuilderConnectionOK else {
                speechError = L10n.t(.chatSpeechNotPassed)
                return
            }

            let startID = UUID()
            speechStartID = startID
            isStartingRecording = true
            let permissionStart = ProcessInfo.processInfo.systemUptime
            let allowed = await Self.requestMicrophonePermissionForRecording()
            Self.logger.notice("[SpeechProfile] microphone permission allowed=\(allowed, privacy: .public) ms=\(max(0, Int((ProcessInfo.processInfo.systemUptime - permissionStart) * 1000)), privacy: .public)")
            guard allowed else {
                guard speechStartID == startID else { return }
                speechStartID = nil
                isStartingRecording = false
                speechError = L10n.t(.chatMicrophoneDenied)
                return
            }
            guard speechStartID == startID else { return }
            let startRecordingStart = ProcessInfo.processInfo.systemUptime
            var startedSession: VoiceFlowSession?
            do {
                speechRetryID = nil
                clearPreservedSpeechAudio()
                let strategy = state.aiBuilderRecordingStrategy
                recordingInputPrefix = inputText
                activeSpeechStrategy = strategy
                startSpeechAudioLevelConsumer()

                if strategy.usesRealtimeTransport {
                    let session = try await state.startRealtimeSpeechSession()
                    startedSession = session
                    guard speechStartID == startID else {
                        await terminateSpeechSession(session)
                        return
                    }
                    speechSession = session
                    startSpeechEventConsumer(for: session)
                    try await startingMicrophone.start(strategy: strategy) { chunk in
                        Task {
                            await session.sendAudioChunk(chunk)
                        }
                    }
                } else {
                    speechSession = nil
                    try await startingMicrophone.start(strategy: strategy)
                }
                guard speechStartID == startID else {
                    if let audioURL = try? await startingMicrophone.stop() {
                        try? FileManager.default.removeItem(at: audioURL)
                    }
                    startingMicrophone.discard()
                    if let startedSession {
                        await terminateSpeechSession(startedSession)
                        if speechSession === startedSession {
                            self.speechSession = nil
                        }
                    }
                    return
                }
                if let startedSession {
                    startSpeechHeartbeat(for: startedSession)
                }
                isRecording = true
                speechStartID = nil
                isStartingRecording = false
                Self.logger.notice("[SpeechProfile] capture started strategy=\(strategy.rawValue, privacy: .public) ms=\(max(0, Int((ProcessInfo.processInfo.systemUptime - startRecordingStart) * 1000)), privacy: .public)")
            } catch {
                if let audioURL = try? await startingMicrophone.stop() {
                    try? FileManager.default.removeItem(at: audioURL)
                }
                startingMicrophone.discard()
                if let startedSession {
                    await terminateSpeechSession(startedSession)
                    if speechSession === startedSession {
                        speechSession = nil
                    }
                }
                let shouldReportError = speechStartID == startID
                if shouldReportError {
                    stopSpeechHeartbeat()
                    stopSpeechEventConsumer()
                    stopSpeechAudioLevelConsumer()
                    speechStartID = nil
                    isStartingRecording = false
                }
                guard shouldReportError else { return }
                Self.logger.error("[SpeechProfile] realtime capture start failed error=\(error.localizedDescription, privacy: .public)")
                speechError = error.localizedDescription
            }
        }
    }

    func abortSpeechRecognition() async {
        speechStartID = nil
        speechFinalizationID = nil
        speechRetryID = nil
        stopSpeechHeartbeat()
        stopSpeechEventConsumer()
        stopSpeechAudioLevelConsumer()
        let audioURL = try? await microphone.stop()

        let session = speechSession
        let prefix = recordingInputPrefix
        let strategy = activeSpeechStrategy
        speechSession = nil
        isRecording = false
        isTranscribing = false
        isStartingRecording = false

        if !strategy.usesRealtimeTransport {
            if let audioURL {
                clearPreservedSpeechAudio()
                preservedSpeechFileURL = audioURL
                preservedSpeechStrategy = strategy
                preservedSpeechInputPrefix = prefix
            }
            return
        }
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        guard let session else { return }
        do {
            if let preserved = try await session.abortPreservingAudio() {
                clearPreservedSpeechAudio()
                preservedSpeechInputPrefix = prefix
                preservedSpeechAudio = preserved
                Self.logger.notice("[SpeechProfile] realtime speech aborted with preserved bytes=\(preserved.byteCount, privacy: .public)")
            }
        } catch {
            Self.logger.error("[SpeechProfile] realtime speech abort failed error=\(error.localizedDescription, privacy: .public)")
            speechError = error.localizedDescription
        }
    }

    func retryPreservedSpeechAudio() async {
        guard preservedSpeechAudio != nil || preservedSpeechFileURL != nil else { return }
        let retryID = UUID()
        speechRetryID = retryID
        isRetryingSpeech = true
        defer {
            if speechRetryID == retryID {
                speechRetryID = nil
                isRetryingSpeech = false
            }
        }

        let prefix = preservedSpeechInputPrefix
        do {
            let transcript: String
            if let audioURL = preservedSpeechFileURL {
                transcript = try await state.transcribeAudio(
                    audioFileURL: audioURL,
                    strategy: preservedSpeechStrategy
                )
            } else if let preserved = preservedSpeechAudio {
                transcript = try await state.transcribePreservedAudio(preserved) { partial in
                    Task { @MainActor in
                        guard speechRetryID == retryID else { return }
                        inputText = Self.mergedSpeechInput(prefix: prefix, transcript: partial)
                    }
                }
            } else {
                return
            }
            guard speechRetryID == retryID else { return }
            inputText = Self.mergedSpeechInput(prefix: prefix, transcript: transcript)
            clearPreservedSpeechAudio()
        } catch {
            guard speechRetryID == retryID else { return }
            Self.logger.error("[SpeechProfile] preserved speech retry failed error=\(error.localizedDescription, privacy: .public)")
            speechError = error.localizedDescription
        }
    }

    func clearPreservedSpeechAudio() {
        if let preservedSpeechAudio {
            state.discardPreservedAudio(preservedSpeechAudio)
        }
        preservedSpeechAudio = nil
        if let preservedSpeechFileURL {
            try? FileManager.default.removeItem(at: preservedSpeechFileURL)
        }
        preservedSpeechFileURL = nil
        preservedSpeechStrategy = .openAIRealtime
        preservedSpeechInputPrefix = ""
    }
}
