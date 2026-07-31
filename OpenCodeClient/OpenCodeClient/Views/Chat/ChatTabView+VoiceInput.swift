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
/// GPT Live accumulated snapshots render in the composer while recording.
/// GPT Realtime remains finalize-only.

/// Thread-safe buffer for the latest partial transcript. Used to recover
/// a salvageable string when `commitAndStop` fails after partials
/// already streamed in.
final class SpeechPartialTranscriptBuffer: Sendable {
    private struct State: Sendable {
        var transcript = ""
        var acceptsUpdates = true
    }

    private let storage = OSAllocatedUnfairLock(initialState: State())

    @discardableResult
    nonisolated func update(_ newValue: String) -> Bool {
        storage.withLock {
            guard $0.acceptsUpdates else { return false }
            $0.transcript = newValue
            return true
        }
    }

    nonisolated func current() -> String {
        storage.withLock { $0.transcript }
    }

    nonisolated func close() {
        storage.withLock { $0.acceptsUpdates = false }
    }
}

enum ChatSpeechOwner: Hashable {
    case session(String)
    case noSession

    init(sessionID: String?) {
        if let sessionID {
            self = .session(sessionID)
        } else {
            self = .noSession
        }
    }
}

enum PendingChatSpeechAudio {
    case file(URL, strategy: VoiceFlowRecordingStrategy, prefix: String)
    case preserved(VoiceFlowPreservedAudio, prefix: String)

    var prefix: String {
        switch self {
        case .file(_, _, let prefix), .preserved(_, let prefix): prefix
        }
    }
}

extension ChatTabView {
    static let speechHeartbeatIntervalSeconds: UInt64 = 12

    static func mergedSpeechInput(prefix: String, transcript: String) -> String {
        ChatSpeechRouting.mergedInput(prefix: prefix, transcript: transcript)
    }

    static func speechFailureInput(prefix: String, lastPartialTranscript: String) -> String {
        mergedSpeechInput(prefix: prefix, transcript: lastPartialTranscript)
    }

    static func liveSpeechInput(
        strategy: VoiceFlowRecordingStrategy,
        prefix: String,
        transcript: String
    ) -> String? {
        guard strategy == .gptLiveTranscribe else { return nil }
        return mergedSpeechInput(prefix: prefix, transcript: transcript)
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

    func isCurrentSpeechSession(_ session: VoiceFlowSession) -> Bool {
        speechSession === session && speechOriginSessionID == state.currentSessionID
    }

    func ownsSpeechSession(_ session: VoiceFlowSession, sourceSessionID: String?) -> Bool {
        speechSession === session && speechOriginSessionID == sourceSessionID
    }

    func applySpeechDraft(prefix: String, transcript: String, sourceSessionID: String?) {
        let route = ChatSpeechRouting.draftRoute(
            prefix: prefix,
            transcript: transcript,
            sourceSessionID: sourceSessionID,
            currentSessionID: state.currentSessionID
        )
        let owner = ChatSpeechOwner(sessionID: sourceSessionID)
        if sourceSessionID != nil {
            state.setDraftText(route.sourceDraftText, for: sourceSessionID)
        } else {
            completedSpeechDraftByOwner[owner] = route.sourceDraftText
        }
        if let currentComposerText = route.currentComposerText {
            inputText = currentComposerText
        }
    }

    func finishSpeechAudioSender() async {
        let sender = speechAudioSender
        speechAudioSender = nil
        await sender?.finishAndDrain()
    }

    func storePendingSpeechAudio(_ pending: PendingChatSpeechAudio, owner: ChatSpeechOwner) {
        if let existing = pendingSpeechAudioByOwner.removeValue(forKey: owner) {
            discardPendingSpeechAudio(existing)
        }
        pendingSpeechAudioByOwner[owner] = pending
    }

    func discardPendingSpeechAudio(_ pending: PendingChatSpeechAudio) {
        switch pending {
        case .file(let audioURL, _, _):
            try? FileManager.default.removeItem(at: audioURL)
        case .preserved(let preserved, _):
            state.discardPreservedAudio(preserved)
        }
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
                    await MainActor.run {
                        guard isCurrentSpeechSession(session) else { return }
                        speechRecoveryActive = true
                    }
                case .recoveryFailed(let message):
                    Self.logger.error("[SpeechProfile] realtime recovery failed message=\(message, privacy: .public)")
                    await MainActor.run {
                        guard isCurrentSpeechSession(session) else { return }
                        speechRecoveryActive = false
                        speechError = L10n.t(.chatSpeechStreamDisconnected)
                    }
                case .phaseChanged(let phase):
                    if phase == .connected {
                        await MainActor.run {
                            guard isCurrentSpeechSession(session), speechRecoveryActive else { return }
                            speechRecoveryActive = false
                        }
                    }
                case .partialTranscript(let transcript):
                    await MainActor.run {
                        guard isCurrentSpeechSession(session),
                              let liveInput = Self.liveSpeechInput(
                                  strategy: activeSpeechStrategy,
                                  prefix: recordingInputPrefix,
                                  transcript: transcript
                              ) else { return }
                        inputText = liveInput
                    }
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

    func preserveSpeechSession(_ session: VoiceFlowSession) async -> VoiceFlowPreservedAudio? {
        do {
            return try await session.abortPreservingAudio()
        } catch {
            Self.logger.error("[SpeechProfile] realtime audio preservation failed error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func stopSpeechForNavigation() async {
        await stopSpeechForNavigation(detachFinalizationOnSessionSwitch: true)
    }

    private func stopSpeechForNavigation(detachFinalizationOnSessionSwitch: Bool) async {
        let disposition = ChatSpeechRouting.navigationDisposition(
            detachFinalizationOnSessionSwitch: detachFinalizationOnSessionSwitch,
            finalizationID: speechFinalizationID,
            sourceSessionID: speechOriginSessionID,
            currentSessionID: state.currentSessionID
        )
        if disposition == .detachFinalization {
            speechRetryID = nil
            speechRetrySessionID = nil
            stopSpeechHeartbeat()
            stopSpeechEventConsumer()
            stopSpeechAudioLevelConsumer()
            isRecording = false
            isTranscribing = false
            isStartingRecording = false
            isRetryingSpeech = false
            return
        }

        let originSessionID = speechOriginSessionID
        let owner = ChatSpeechOwner(sessionID: originSessionID)
        let prefix = recordingInputPrefix
        let strategy = activeSpeechStrategy
        let hadActiveCapture = isRecording || isStartingRecording || isTranscribing
        speechStartID = nil
        speechFinalizationID = nil
        speechRetryID = nil
        speechRetrySessionID = nil
        stopSpeechHeartbeat()
        stopSpeechEventConsumer()
        stopSpeechAudioLevelConsumer()
        let audioURL = try? await microphone.stop()
        microphone.discard()
        await finishSpeechAudioSender()

        let session = speechSession
        speechSession = nil
        speechOriginSessionID = nil
        isRecording = false
        isTranscribing = false
        isStartingRecording = false
        isRetryingSpeech = false

        guard hadActiveCapture else {
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
            return
        }
        if strategy.usesRealtimeTransport {
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
            if let session, let preserved = await preserveSpeechSession(session) {
                storePendingSpeechAudio(.preserved(preserved, prefix: prefix), owner: owner)
            }
        } else if let audioURL {
            storePendingSpeechAudio(.file(audioURL, strategy: strategy, prefix: prefix), owner: owner)
        }
    }

    func stopSpeechForBackground() async {
        await stopSpeechForNavigation(detachFinalizationOnSessionSwitch: false)
    }

    func toggleRecording() async {
        if isRecording {
            let finalizationID = UUID()
            speechFinalizationID = finalizationID
            let stoppingMicrophone = microphone
            let originSessionID = speechOriginSessionID
            let owner = ChatSpeechOwner(sessionID: originSessionID)
            let prefix = recordingInputPrefix
            let strategy = activeSpeechStrategy
            stopSpeechHeartbeat()
            stopSpeechEventConsumer()
            stopSpeechAudioLevelConsumer()
            let stopStart = ProcessInfo.processInfo.systemUptime
            let audioURL = try? await stoppingMicrophone.stop()
            stoppingMicrophone.discard()
            await finishSpeechAudioSender()
            guard SpeechAttemptGate.owns(finalizationID, activeAttemptID: speechFinalizationID),
                  speechOriginSessionID == originSessionID else {
                if let audioURL, !strategy.usesRealtimeTransport {
                    storePendingSpeechAudio(.file(audioURL, strategy: strategy, prefix: prefix), owner: owner)
                } else if let audioURL {
                    try? FileManager.default.removeItem(at: audioURL)
                }
                await stopSpeechForNavigation(detachFinalizationOnSessionSwitch: false)
                return
            }
            isRecording = false
            Self.logger.notice("[SpeechProfile] realtime capture stopped ms=\(max(0, Int((ProcessInfo.processInfo.systemUptime - stopStart) * 1000)), privacy: .public)")

            isTranscribing = originSessionID == state.currentSessionID

            if !strategy.usesRealtimeTransport {
                guard let audioURL else {
                    isTranscribing = false
                    speechFinalizationID = nil
                    speechOriginSessionID = nil
                    if originSessionID == state.currentSessionID {
                        speechError = L10n.t(.carTranscriptionFailed)
                    }
                    return
                }
                storePendingSpeechAudio(.file(audioURL, strategy: strategy, prefix: prefix), owner: owner)
                do {
                    let transcript = try await state.transcribeAudio(
                        audioFileURL: audioURL,
                        strategy: strategy,
                        surface: .chat
                    )
                    guard SpeechAttemptGate.owns(finalizationID, activeAttemptID: speechFinalizationID),
                          speechOriginSessionID == originSessionID else { return }
                    applySpeechDraft(prefix: prefix, transcript: transcript, sourceSessionID: originSessionID)
                    clearPreservedSpeechAudio(for: owner)
                } catch {
                    guard SpeechAttemptGate.owns(finalizationID, activeAttemptID: speechFinalizationID),
                          speechOriginSessionID == originSessionID else { return }
                    Self.logger.error("[SpeechProfile] chat batch transcribe failed error=\(error.localizedDescription, privacy: .public)")
                    if originSessionID == state.currentSessionID {
                        speechError = error.localizedDescription
                    }
                }
                if speechFinalizationID == finalizationID {
                    speechFinalizationID = nil
                    speechOriginSessionID = nil
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
                speechOriginSessionID = nil
                Self.logger.error("[SpeechProfile] realtime stop failed: missing session")
                if originSessionID == state.currentSessionID {
                    speechError = L10n.t(.carTranscriptionFailed)
                }
                return
            }
            defer {
                if speechSession === session {
                    speechSession = nil
                    speechFinalizationID = nil
                    speechOriginSessionID = nil
                    isTranscribing = false
                }
            }
            let partialTranscriptBuffer = SpeechPartialTranscriptBuffer()
            let transcribeStart = ProcessInfo.processInfo.systemUptime
            do {
                let transcript = try await session.commitAndStop { partial in
                    guard partialTranscriptBuffer.update(partial) else { return }
                    Task { @MainActor in
                        guard SpeechAttemptGate.accepts(
                            finalizationID,
                            activeAttemptID: speechFinalizationID,
                            originatingSessionID: originSessionID,
                            currentSessionID: state.currentSessionID
                        ), ownsSpeechSession(session, sourceSessionID: originSessionID) else { return }
                        inputText = Self.mergedSpeechInput(prefix: prefix, transcript: partial)
                    }
                }
                let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                partialTranscriptBuffer.close()
                guard SpeechAttemptGate.owns(finalizationID, activeAttemptID: speechFinalizationID),
                      ownsSpeechSession(session, sourceSessionID: originSessionID) else { return }
                speechFinalizationID = nil
                Self.logger.notice("[SpeechProfile] chat realtime transcribe done ms=\(max(0, Int((ProcessInfo.processInfo.systemUptime - transcribeStart) * 1000)), privacy: .public) chars=\(cleaned.count, privacy: .public)")
                applySpeechDraft(prefix: prefix, transcript: cleaned, sourceSessionID: originSessionID)
                clearPreservedSpeechAudio(for: owner)
                speechSession = nil
                speechOriginSessionID = nil
                isTranscribing = false
                await terminateSpeechSession(session)
            } catch {
                partialTranscriptBuffer.close()
                guard SpeechAttemptGate.owns(finalizationID, activeAttemptID: speechFinalizationID),
                      ownsSpeechSession(session, sourceSessionID: originSessionID) else { return }
                speechSession = nil
                let preserved = await preserveSpeechSession(session)
                if let preserved {
                    storePendingSpeechAudio(.preserved(preserved, prefix: prefix), owner: owner)
                }
                guard SpeechAttemptGate.owns(finalizationID, activeAttemptID: speechFinalizationID),
                      speechOriginSessionID == originSessionID else { return }
                speechFinalizationID = nil
                speechOriginSessionID = nil
                isTranscribing = false
                Self.logger.error("[SpeechProfile] chat realtime transcribe failed ms=\(max(0, Int((ProcessInfo.processInfo.systemUptime - transcribeStart) * 1000)), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                applySpeechDraft(
                    prefix: prefix,
                    transcript: partialTranscriptBuffer.current(),
                    sourceSessionID: originSessionID
                )
                if originSessionID == state.currentSessionID {
                    speechError = error.localizedDescription
                }
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

            let strategy = state.aiBuilderRecordingStrategy
            let originSessionID = state.currentSessionID
            let startID = UUID()
            speechStartID = startID
            speechOriginSessionID = originSessionID
            isStartingRecording = true
            let permissionStart = ProcessInfo.processInfo.systemUptime
            let allowed = await Self.requestMicrophonePermissionForRecording()
            Self.logger.notice("[SpeechProfile] microphone permission allowed=\(allowed, privacy: .public) ms=\(max(0, Int((ProcessInfo.processInfo.systemUptime - permissionStart) * 1000)), privacy: .public)")
            guard allowed else {
                guard SpeechAttemptGate.accepts(
                    startID,
                    activeAttemptID: speechStartID,
                    originatingSessionID: originSessionID,
                    currentSessionID: state.currentSessionID
                ) else { return }
                speechStartID = nil
                speechOriginSessionID = nil
                isStartingRecording = false
                speechError = L10n.t(.chatMicrophoneDenied)
                return
            }
            guard SpeechAttemptGate.accepts(
                startID,
                activeAttemptID: speechStartID,
                originatingSessionID: originSessionID,
                currentSessionID: state.currentSessionID
            ) else { return }
            let startRecordingStart = ProcessInfo.processInfo.systemUptime
            var startedSession: VoiceFlowSession?
            do {
                speechRetryID = nil
                recordingInputPrefix = inputText
                activeSpeechStrategy = strategy
                startSpeechAudioLevelConsumer()

                if strategy.usesRealtimeTransport {
                    let session = try await state.startRealtimeSpeechSession(strategy: strategy, surface: .chat)
                    startedSession = session
                    guard SpeechAttemptGate.accepts(
                        startID,
                        activeAttemptID: speechStartID,
                        originatingSessionID: originSessionID,
                        currentSessionID: state.currentSessionID
                    ) else {
                        await terminateSpeechSession(session)
                        return
                    }
                    speechSession = session
                    startSpeechEventConsumer(for: session)
                    let sender = OrderedSpeechAudioSender { chunk in
                        await session.sendAudioChunk(chunk)
                    }
                    speechAudioSender = sender
                    try await startingMicrophone.start(strategy: strategy) { chunk in
                        sender.enqueue(chunk)
                    }
                } else {
                    speechSession = nil
                    try await startingMicrophone.start(strategy: strategy)
                }
                guard SpeechAttemptGate.accepts(
                    startID,
                    activeAttemptID: speechStartID,
                    originatingSessionID: originSessionID,
                    currentSessionID: state.currentSessionID
                ) else {
                    let audioURL = try? await startingMicrophone.stop()
                    startingMicrophone.discard()
                    await finishSpeechAudioSender()
                    let owner = ChatSpeechOwner(sessionID: originSessionID)
                    if strategy.usesRealtimeTransport {
                        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
                        if let startedSession, speechSession === startedSession {
                            speechSession = nil
                            if let preserved = await preserveSpeechSession(startedSession) {
                                storePendingSpeechAudio(.preserved(preserved, prefix: recordingInputPrefix), owner: owner)
                            }
                        }
                    } else if let audioURL {
                        storePendingSpeechAudio(.file(audioURL, strategy: strategy, prefix: recordingInputPrefix), owner: owner)
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
                let audioURL = try? await startingMicrophone.stop()
                startingMicrophone.discard()
                await finishSpeechAudioSender()
                let owner = ChatSpeechOwner(sessionID: originSessionID)
                if strategy.usesRealtimeTransport {
                    if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
                    if let startedSession, speechSession === startedSession {
                        speechSession = nil
                        if let preserved = await preserveSpeechSession(startedSession) {
                            storePendingSpeechAudio(.preserved(preserved, prefix: recordingInputPrefix), owner: owner)
                        }
                    }
                } else if let audioURL {
                    storePendingSpeechAudio(.file(audioURL, strategy: strategy, prefix: recordingInputPrefix), owner: owner)
                }
                let shouldReportError = SpeechAttemptGate.accepts(
                    startID,
                    activeAttemptID: speechStartID,
                    originatingSessionID: originSessionID,
                    currentSessionID: state.currentSessionID
                )
                if shouldReportError {
                    stopSpeechHeartbeat()
                    stopSpeechEventConsumer()
                    stopSpeechAudioLevelConsumer()
                    speechStartID = nil
                    speechOriginSessionID = nil
                    isStartingRecording = false
                }
                guard shouldReportError else { return }
                Self.logger.error("[SpeechProfile] realtime capture start failed error=\(error.localizedDescription, privacy: .public)")
                speechError = error.localizedDescription
            }
        }
    }

    func abortSpeechRecognition() async {
        let originSessionID = speechOriginSessionID
        let owner = ChatSpeechOwner(sessionID: originSessionID)
        speechStartID = nil
        speechFinalizationID = nil
        speechRetryID = nil
        speechRetrySessionID = nil
        stopSpeechHeartbeat()
        stopSpeechEventConsumer()
        stopSpeechAudioLevelConsumer()
        let audioURL = try? await microphone.stop()
        microphone.discard()
        await finishSpeechAudioSender()

        let session = speechSession
        let prefix = recordingInputPrefix
        let strategy = activeSpeechStrategy
        speechSession = nil
        speechOriginSessionID = nil
        isRecording = false
        isTranscribing = false
        isStartingRecording = false
        isRetryingSpeech = false

        if !strategy.usesRealtimeTransport {
            if let audioURL {
                storePendingSpeechAudio(.file(audioURL, strategy: strategy, prefix: prefix), owner: owner)
            }
            return
        }
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        guard let session else { return }
        do {
            if let preserved = try await session.abortPreservingAudio() {
                storePendingSpeechAudio(.preserved(preserved, prefix: prefix), owner: owner)
                Self.logger.notice("[SpeechProfile] realtime speech aborted with preserved bytes=\(preserved.byteCount, privacy: .public)")
            }
        } catch {
            Self.logger.error("[SpeechProfile] realtime speech abort failed error=\(error.localizedDescription, privacy: .public)")
            speechError = error.localizedDescription
        }
    }

    func retryPreservedSpeechAudio() async {
        let retrySessionID = state.currentSessionID
        let owner = ChatSpeechOwner(sessionID: retrySessionID)
        guard let pending = pendingSpeechAudioByOwner[owner] else { return }
        let retryID = UUID()
        speechRetryID = retryID
        speechRetrySessionID = retrySessionID
        isRetryingSpeech = true
        defer {
            if speechRetryID == retryID {
                speechRetryID = nil
                speechRetrySessionID = nil
                isRetryingSpeech = false
            }
        }

        let prefix = pending.prefix
        let partialTranscriptBuffer = SpeechPartialTranscriptBuffer()
        do {
            let transcript: String
            switch pending {
            case .file(let audioURL, let strategy, _):
                transcript = try await state.transcribeAudio(
                    audioFileURL: audioURL,
                    strategy: strategy,
                    surface: .chat
                )
            case .preserved(let preserved, _):
                transcript = try await state.transcribePreservedAudio(preserved, surface: .chat) { partial in
                    guard partialTranscriptBuffer.update(partial) else { return }
                    Task { @MainActor in
                        guard SpeechAttemptGate.accepts(
                            retryID,
                            activeAttemptID: speechRetryID,
                            originatingSessionID: retrySessionID,
                            currentSessionID: state.currentSessionID
                        ), speechRetrySessionID == retrySessionID else { return }
                        inputText = Self.mergedSpeechInput(prefix: prefix, transcript: partial)
                    }
                }
            }
            partialTranscriptBuffer.close()
            guard SpeechAttemptGate.accepts(
                retryID,
                activeAttemptID: speechRetryID,
                originatingSessionID: retrySessionID,
                currentSessionID: state.currentSessionID
            ), speechRetrySessionID == retrySessionID else { return }
            speechRetryID = nil
            speechRetrySessionID = nil
            isRetryingSpeech = false
            inputText = Self.mergedSpeechInput(prefix: prefix, transcript: transcript)
            clearPreservedSpeechAudio(for: owner)
        } catch {
            partialTranscriptBuffer.close()
            guard SpeechAttemptGate.accepts(
                retryID,
                activeAttemptID: speechRetryID,
                originatingSessionID: retrySessionID,
                currentSessionID: state.currentSessionID
            ), speechRetrySessionID == retrySessionID else { return }
            Self.logger.error("[SpeechProfile] preserved speech retry failed error=\(error.localizedDescription, privacy: .public)")
            speechError = error.localizedDescription
        }
    }

    func clearPreservedSpeechAudio() {
        clearPreservedSpeechAudio(for: ChatSpeechOwner(sessionID: state.currentSessionID))
    }

    func clearPreservedSpeechAudio(for owner: ChatSpeechOwner) {
        if let pending = pendingSpeechAudioByOwner.removeValue(forKey: owner) {
            discardPendingSpeechAudio(pending)
        }
    }
}
