import SwiftUI
import os
import VoiceFlowKit

enum PendingCarAudio {
    case file(URL, strategy: VoiceFlowRecordingStrategy)
    case preserved(VoiceFlowPreservedAudio)

    var strategy: VoiceFlowRecordingStrategy {
        switch self {
        case .file(_, let strategy): strategy
        case .preserved(let audio): audio.strategy
        }
    }
}

private enum CarFailureRetry {
    case transcription
    case request
}

enum CarSpeechAttemptGate {
    static func accepts(
        _ attemptID: UUID,
        activeAttemptID: UUID?,
        generation: UUID,
        currentGeneration: UUID
    ) -> Bool {
        attemptID == activeAttemptID && generation == currentGeneration
    }
}

struct CarModeView: View {
    @Bindable var state: AppState
    @State private var microphone = VoiceFlowMicrophone()
    @State private var speechSession: VoiceFlowSession?
    @State private var audioSender: OrderedSpeechAudioSender?
    @State private var speechGeneration = UUID()
    @State private var recordingStartID: UUID?
    @State private var activeRecordingGeneration: UUID?
    @State private var activeRecordingStrategy: VoiceFlowRecordingStrategy = .gptLiveTranscribe
    @State private var pendingAudio: PendingCarAudio?
    @State private var failureRetry: CarFailureRetry?
    @State private var heartbeatTask: Task<Void, Never>?
    @State private var audioLevelTask: Task<Void, Never>?
    @State private var audioLevel: Float = 0
    @State private var isStartingRecording = false
    @State private var speechFinalizationID: UUID?
    @State private var showNewSessionConfirmation = false
    @Environment(\.scenePhase) private var scenePhase

    private var displayPhase: CarModePhase {
        if ProcessInfo.processInfo.arguments.contains("UITEST_CAR_MODE_FIXTURE") {
            return .idle
        }
        return state.carPhase
    }

    private var statusText: String {
        switch displayPhase {
        case .idle: return L10n.t(.carReady)
        case .recording: return L10n.t(.carListening)
        case .finalizing: return L10n.t(.carFinalizing)
        case .waitingReply: return L10n.t(.carWorking)
        case .speaking: return L10n.t(.carSpeaking)
        case .awaitingConfirmation: return L10n.t(.carNeedsConfirmation)
        case .failed: return L10n.t(.carFailed)
        }
    }

    private var primaryLabel: String {
        switch displayPhase {
        case .recording: return L10n.t(.carStopAndSend)
        case .finalizing: return L10n.t(.commonCancel)
        case .waitingReply: return L10n.t(.carStopResponse)
        case .speaking: return L10n.t(.carStopSpeaking)
        case .awaitingConfirmation: return L10n.t(.carSpeakConfirmation)
        case .failed: return L10n.t(.commonRetry)
        case .idle: return L10n.t(.carStartSpeaking)
        }
    }

    private var primaryIcon: String {
        switch displayPhase {
        case .recording: return "stop.fill"
        case .finalizing, .waitingReply, .speaking: return "xmark"
        case .awaitingConfirmation: return "mic.fill"
        case .failed: return "arrow.clockwise"
        case .idle: return "mic.fill"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(uiColor: .systemBackground), DesignColors.Brand.primary.opacity(0.07)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    statusRail
                    Spacer(minLength: DesignSpacing.xl)
                    responseArea
                    Spacer(minLength: DesignSpacing.xl)
                    primaryControl
                    confirmationControls
                }
                .padding(.horizontal, DesignSpacing.xxl)
                .padding(.bottom, DesignSpacing.xxl)
            }
            .navigationTitle(L10n.t(.carTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewSessionConfirmation = true
                    } label: {
                        Image(systemName: "plus.message")
                    }
                    .accessibilityLabel(L10n.t(.carNewSession))
                    .accessibilityIdentifier("car-new-session")
                }
            }
            .confirmationDialog(L10n.t(.carNewSessionPrompt), isPresented: $showNewSessionConfirmation) {
                Button(L10n.t(.carNewSession), role: .destructive) {
                    Task { await startNewCarSession() }
                }
                Button(L10n.t(.commonCancel), role: .cancel) {}
            }
        }
        .accessibilityIdentifier("car-mode-root")
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            Task { await stopForBackground() }
        }
        .onDisappear {
            Task { await stopForBackground() }
        }
    }

    private var statusRail: some View {
        HStack(spacing: DesignSpacing.sm) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText.uppercased())
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let sessionID = state.currentCarSessionID {
                Text(String(sessionID.suffix(6)))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, DesignSpacing.sm)
        .accessibilityIdentifier("car-status")
    }

    private var responseArea: some View {
        VStack(spacing: DesignSpacing.md) {
            if let response = state.carLastResponse {
                Text(response.speech)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .minimumScaleFactor(0.72)
                    .accessibilityIdentifier("car-last-response")
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(DesignColors.Brand.primary)
                Text(L10n.t(.carEmptyPrompt))
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
            }

            if !state.carLastTranscript.isEmpty {
                Text("“\(state.carLastTranscript)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("car-last-transcript")
            }

            if let error = state.carError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(DesignColors.Semantic.error)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("car-error")
            }
        }
        .frame(maxWidth: 620)
    }

    private var primaryControl: some View {
        Button {
            Task { await handlePrimaryAction() }
        } label: {
            ZStack {
                Circle()
                    .fill(primaryColor.gradient)
                    .shadow(color: primaryColor.opacity(0.28), radius: 24, y: 10)
                Circle()
                    .stroke(.white.opacity(0.25), lineWidth: 1)
                    .padding(7)
                VStack(spacing: DesignSpacing.sm) {
                    Image(systemName: primaryIcon)
                        .font(.system(size: 42, weight: .semibold))
                    Text(primaryLabel)
                        .font(.headline)
                }
                .foregroundStyle(.white)
            }
            .frame(width: 190, height: 190)
            .scaleEffect(displayPhase == .recording ? 1 + CGFloat(min(audioLevel, 0.18)) : 1)
            .animation(.easeOut(duration: 0.12), value: audioLevel)
        }
        .buttonStyle(.plain)
        .disabled(isStartingRecording)
        .accessibilityIdentifier("car-primary-action")
        .accessibilityLabel(primaryLabel)
    }

    @ViewBuilder
    private var confirmationControls: some View {
        if displayPhase == .awaitingConfirmation {
            HStack(spacing: DesignSpacing.md) {
                Button(L10n.t(.commonOk)) {
                    Task { await state.submitCarTurn(L10n.t(.carConfirmUtterance)) }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("car-confirm")

                Button(L10n.t(.commonCancel)) {
                    Task { await state.submitCarTurn(L10n.t(.carCancelUtterance)) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("car-decline")
            }
            .padding(.top, DesignSpacing.lg)
        } else {
            Color.clear.frame(height: 52)
        }
    }

    private var statusColor: Color {
        switch displayPhase {
        case .recording: return DesignColors.Semantic.error
        case .finalizing, .waitingReply, .speaking: return DesignColors.Brand.gold
        case .failed: return DesignColors.Semantic.error
        case .awaitingConfirmation: return DesignColors.Semantic.warning
        case .idle: return DesignColors.Semantic.success
        }
    }

    private var primaryColor: Color {
        switch displayPhase {
        case .recording, .finalizing, .waitingReply, .speaking: return DesignColors.Semantic.error
        case .failed: return DesignColors.Semantic.warning
        default: return DesignColors.Brand.primary
        }
    }

    private func finishAudioSender() async {
        let sender = audioSender
        audioSender = nil
        await sender?.finishAndDrain()
    }

    private func replacePendingAudio(_ audio: PendingCarAudio) {
        discardPendingRecording()
        pendingAudio = audio
    }

    private func startNewCarSession() async {
        speechGeneration = UUID()
        await cancelLocalCarSpeech(preserveAudio: false)
        await state.startNewCarSession()
    }

    private func cancelLocalCarSpeech(preserveAudio: Bool) async {
        let strategy = activeRecordingStrategy
        let hadLocalSpeech = isStartingRecording
            || speechSession != nil
            || state.carPhase == .recording
            || state.carPhase == .finalizing
        recordingStartID = nil
        speechFinalizationID = nil
        isStartingRecording = false
        stopHeartbeat()
        stopAudioLevelConsumer()
        let audioURL = try? await microphone.stop()
        microphone.discard()
        await finishAudioSender()

        let session = speechSession
        speechSession = nil
        activeRecordingGeneration = nil

        if preserveAudio, hadLocalSpeech {
            if strategy.usesRealtimeTransport {
                if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
                if let session, let preserved = await preserve(session) {
                    replacePendingAudio(.preserved(preserved))
                }
            } else if let audioURL {
                replacePendingAudio(.file(audioURL, strategy: strategy))
            }
        } else {
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
            if let session { await terminate(session) }
            if !preserveAudio { discardPendingRecording() }
        }

        await state.cancelCarInteraction()
        if preserveAudio, pendingAudio != nil {
            failureRetry = .transcription
            state.carPhase = .failed
        } else {
            failureRetry = nil
        }
    }

    private func handlePrimaryAction() async {
        switch displayPhase {
        case .recording:
            await stopRecordingAndSubmit()
        case .finalizing, .waitingReply, .speaking:
            await cancelLocalCarSpeech(preserveAudio: true)
        case .failed:
            switch failureRetry {
            case .transcription:
                if pendingAudio != nil {
                    await retryPendingRecording()
                } else {
                    await startRecording()
                }
            case .request:
                await state.submitCarTurn(state.carLastTranscript)
                if state.carPhase != .failed {
                    failureRetry = nil
                }
            case nil:
                await startRecording()
            }
        case .idle, .awaitingConfirmation:
            await startRecording()
        }
    }

    private func startRecording() async {
        guard !isStartingRecording else { return }
        let token = state.aiBuilderToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            state.carError = L10n.t(.chatSpeechTokenMissing)
            state.carPhase = .failed
            return
        }
        guard state.aiBuilderConnectionOK else {
            state.carError = L10n.t(.chatSpeechNotPassed)
            state.carPhase = .failed
            return
        }
        let strategy = state.aiBuilderRecordingStrategy
        let generation = speechGeneration
        let startID = UUID()
        recordingStartID = startID
        activeRecordingGeneration = generation
        isStartingRecording = true
        guard await ChatTabView.requestMicrophonePermissionForRecording() else {
            guard CarSpeechAttemptGate.accepts(
                startID,
                activeAttemptID: recordingStartID,
                generation: generation,
                currentGeneration: speechGeneration
            ) else { return }
            recordingStartID = nil
            activeRecordingGeneration = nil
            isStartingRecording = false
            state.carError = L10n.t(.chatMicrophoneDenied)
            state.carPhase = .failed
            return
        }

        guard CarSpeechAttemptGate.accepts(
            startID,
            activeAttemptID: recordingStartID,
            generation: generation,
            currentGeneration: speechGeneration
        ) else { return }
        speechFinalizationID = nil
        discardPendingRecording()
        failureRetry = nil
        state.carSpeechOutput.stop()
        let startingMicrophone = VoiceFlowMicrophone()
        microphone = startingMicrophone
        var startedSession: VoiceFlowSession?
        do {
            activeRecordingStrategy = strategy
            if strategy.usesRealtimeTransport {
                let session = try await state.startRealtimeSpeechSession(strategy: strategy, surface: .car)
                startedSession = session
                guard CarSpeechAttemptGate.accepts(
                    startID,
                    activeAttemptID: recordingStartID,
                    generation: generation,
                    currentGeneration: speechGeneration
                ) else {
                    await terminate(session)
                    return
                }
                speechSession = session
                let sender = OrderedSpeechAudioSender { chunk in
                    await session.sendAudioChunk(chunk)
                }
                audioSender = sender
                try await startingMicrophone.start(strategy: strategy) { chunk in
                    sender.enqueue(chunk)
                }
            } else {
                speechSession = nil
                try await startingMicrophone.start(strategy: strategy)
            }
            guard CarSpeechAttemptGate.accepts(
                startID,
                activeAttemptID: recordingStartID,
                generation: generation,
                currentGeneration: speechGeneration
            ) else {
                let audioURL = try? await startingMicrophone.stop()
                startingMicrophone.discard()
                await finishAudioSender()
                if strategy.usesRealtimeTransport {
                    if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
                    if let startedSession, speechSession === startedSession {
                        speechSession = nil
                        if generation == speechGeneration {
                            if let preserved = await preserve(startedSession) {
                                replacePendingAudio(.preserved(preserved))
                            }
                        } else {
                            await terminate(startedSession)
                        }
                    }
                } else if let audioURL {
                    if generation == speechGeneration {
                        replacePendingAudio(.file(audioURL, strategy: strategy))
                    } else {
                        try? FileManager.default.removeItem(at: audioURL)
                    }
                }
                return
            }
            if let startedSession {
                startHeartbeat(for: startedSession)
            }
            state.carError = nil
            state.carPhase = .recording
            startAudioLevelConsumer()
        } catch {
            let audioURL = try? await startingMicrophone.stop()
            startingMicrophone.discard()
            await finishAudioSender()
            if strategy.usesRealtimeTransport {
                if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
                if let startedSession, speechSession === startedSession {
                    speechSession = nil
                    if generation == speechGeneration {
                        if let preserved = await preserve(startedSession) {
                            replacePendingAudio(.preserved(preserved))
                        }
                    } else {
                        await terminate(startedSession)
                    }
                }
            } else if let audioURL {
                if generation == speechGeneration {
                    replacePendingAudio(.file(audioURL, strategy: strategy))
                } else {
                    try? FileManager.default.removeItem(at: audioURL)
                }
            }
            guard CarSpeechAttemptGate.accepts(
                startID,
                activeAttemptID: recordingStartID,
                generation: generation,
                currentGeneration: speechGeneration
            ) else { return }
            activeRecordingGeneration = nil
            if pendingAudio != nil { failureRetry = .transcription }
            state.carError = error.localizedDescription
            state.carPhase = .failed
        }
        if CarSpeechAttemptGate.accepts(
            startID,
            activeAttemptID: recordingStartID,
            generation: generation,
            currentGeneration: speechGeneration
        ) {
            recordingStartID = nil
            isStartingRecording = false
        }
    }

    private func stopRecordingAndSubmit() async {
        guard let generation = activeRecordingGeneration else { return }
        let finalizationID = UUID()
        speechFinalizationID = finalizationID
        let stoppingMicrophone = microphone
        stopHeartbeat()
        stopAudioLevelConsumer()
        let audioURL = try? await stoppingMicrophone.stop()
        stoppingMicrophone.discard()
        await finishAudioSender()
        guard CarSpeechAttemptGate.accepts(
            finalizationID,
            activeAttemptID: speechFinalizationID,
            generation: generation,
            currentGeneration: speechGeneration
        ) else {
            if let audioURL {
                if activeRecordingStrategy.usesRealtimeTransport || generation != speechGeneration {
                    try? FileManager.default.removeItem(at: audioURL)
                } else {
                    replacePendingAudio(.file(audioURL, strategy: activeRecordingStrategy))
                }
            }
            return
        }
        state.carPhase = .finalizing
        let strategy = activeRecordingStrategy

        if !strategy.usesRealtimeTransport {
            guard let audioURL else {
                speechFinalizationID = nil
                activeRecordingGeneration = nil
                failureRetry = .transcription
                state.carError = L10n.t(.carTranscriptionFailed)
                state.carPhase = .failed
                return
            }
            replacePendingAudio(.file(audioURL, strategy: strategy))
            await transcribePendingRecording(finalizationID: finalizationID, generation: generation)
            return
        }

        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        guard let session = speechSession else {
            speechFinalizationID = nil
            activeRecordingGeneration = nil
            failureRetry = .transcription
            state.carError = L10n.t(.carTranscriptionFailed)
            state.carPhase = .failed
            return
        }

        let partialTranscriptBuffer = SpeechPartialTranscriptBuffer()
        do {
            let transcript = try await session.commitAndStop { partial in
                partialTranscriptBuffer.update(partial)
            }
            partialTranscriptBuffer.close()
            let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw CarModeError.invalidResponse }
            guard CarSpeechAttemptGate.accepts(
                finalizationID,
                activeAttemptID: speechFinalizationID,
                generation: generation,
                currentGeneration: speechGeneration
            ),
                  speechSession === session else {
                await terminate(session)
                return
            }
            await terminate(session)
            guard CarSpeechAttemptGate.accepts(
                finalizationID,
                activeAttemptID: speechFinalizationID,
                generation: generation,
                currentGeneration: speechGeneration
            ),
                  speechSession === session else { return }
            speechSession = nil
            activeRecordingGeneration = nil
            speechFinalizationID = nil
            discardPendingRecording()
            failureRetry = .request
            await state.submitCarTurn(cleaned)
            if state.carPhase != .failed {
                failureRetry = nil
            }
        } catch {
            partialTranscriptBuffer.close()
            guard CarSpeechAttemptGate.accepts(
                finalizationID,
                activeAttemptID: speechFinalizationID,
                generation: generation,
                currentGeneration: speechGeneration
            ), speechSession === session else { return }
            speechSession = nil
            let preserved = await preserve(session)
            guard generation == speechGeneration else {
                if let preserved { state.discardPreservedAudio(preserved) }
                return
            }
            if let preserved {
                replacePendingAudio(.preserved(preserved))
            }
            guard CarSpeechAttemptGate.accepts(
                finalizationID,
                activeAttemptID: speechFinalizationID,
                generation: generation,
                currentGeneration: speechGeneration
            ) else { return }
            activeRecordingGeneration = nil
            speechFinalizationID = nil
            let partial = partialTranscriptBuffer.current().trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                state.carLastTranscript = partial
            }
            failureRetry = .transcription
            state.carError = error.localizedDescription
            state.carPhase = .failed
        }
    }

    private func stopForBackground() async {
        await cancelLocalCarSpeech(preserveAudio: true)
    }

    private func retryPendingRecording() async {
        guard pendingAudio != nil else { return }
        state.carPhase = .finalizing
        let generation = speechGeneration
        let finalizationID = UUID()
        speechFinalizationID = finalizationID
        await transcribePendingRecording(finalizationID: finalizationID, generation: generation)
    }

    private func transcribePendingRecording(finalizationID: UUID, generation: UUID) async {
        guard let pendingAudio else { return }
        do {
            let transcript: String
            switch pendingAudio {
            case .file(let audioURL, let strategy):
                transcript = try await state.transcribeAudio(
                    audioFileURL: audioURL,
                    strategy: strategy,
                    surface: .car
                )
            case .preserved(let preserved):
                transcript = try await state.transcribePreservedAudio(preserved, surface: .car)
            }
            let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw CarModeError.invalidResponse }
            guard CarSpeechAttemptGate.accepts(
                finalizationID,
                activeAttemptID: speechFinalizationID,
                generation: generation,
                currentGeneration: speechGeneration
            ) else { return }
            speechFinalizationID = nil
            activeRecordingGeneration = nil
            discardPendingRecording()
            failureRetry = .request
            await state.submitCarTurn(cleaned)
            if state.carPhase != .failed {
                failureRetry = nil
            }
        } catch {
            guard CarSpeechAttemptGate.accepts(
                finalizationID,
                activeAttemptID: speechFinalizationID,
                generation: generation,
                currentGeneration: speechGeneration
            ) else { return }
            speechFinalizationID = nil
            activeRecordingGeneration = nil
            failureRetry = .transcription
            state.carError = error.localizedDescription
            state.carPhase = .failed
        }
    }

    private func discardPendingRecording() {
        switch pendingAudio {
        case .file(let audioURL, _):
            try? FileManager.default.removeItem(at: audioURL)
        case .preserved(let preserved):
            state.discardPreservedAudio(preserved)
        case nil:
            break
        }
        pendingAudio = nil
    }

    private func terminate(_ session: VoiceFlowSession) async {
        do {
            if let preserved = try await session.abortPreservingAudio() {
                state.discardPreservedAudio(preserved)
            }
        } catch {
            AppState.logger.error("Car speech session termination failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func preserve(_ session: VoiceFlowSession) async -> VoiceFlowPreservedAudio? {
        do {
            return try await session.abortPreservingAudio()
        } catch {
            AppState.logger.error("Car speech audio preservation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func startHeartbeat(for session: VoiceFlowSession) {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(ChatTabView.speechHeartbeatIntervalSeconds))
                guard !Task.isCancelled else { return }
                await session.ping()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func startAudioLevelConsumer() {
        audioLevelTask?.cancel()
        let levels = microphone.audioLevel
        audioLevelTask = Task {
            for await level in levels {
                guard !Task.isCancelled else { return }
                audioLevel = level
            }
        }
    }

    private func stopAudioLevelConsumer() {
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioLevel = 0
    }
}
