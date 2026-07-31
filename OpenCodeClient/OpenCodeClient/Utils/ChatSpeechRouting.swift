import Foundation

nonisolated enum SpeechAttemptGate {
    static func owns(_ attemptID: UUID, activeAttemptID: UUID?) -> Bool {
        attemptID == activeAttemptID
    }

    static func accepts(
        _ attemptID: UUID,
        activeAttemptID: UUID?,
        originatingSessionID: String?,
        currentSessionID: String?
    ) -> Bool {
        owns(attemptID, activeAttemptID: activeAttemptID)
            && originatingSessionID == currentSessionID
    }
}

struct ChatSpeechDraftRoute: Equatable {
    let sourceSessionID: String?
    let sourceDraftText: String
    let currentComposerText: String?
}

enum ChatSpeechNavigationDisposition: Equatable {
    case detachFinalization
    case cancelAndPreserve
}

nonisolated enum ChatSpeechRouting {
    static func mergedInput(prefix: String, transcript: String) -> String {
        let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTranscript.isEmpty else { return prefix }
        guard !prefix.isEmpty else { return cleanedTranscript }
        return prefix + " " + cleanedTranscript
    }

    static func draftRoute(
        prefix: String,
        transcript: String,
        sourceSessionID: String?,
        currentSessionID: String?
    ) -> ChatSpeechDraftRoute {
        let text = mergedInput(prefix: prefix, transcript: transcript)
        return ChatSpeechDraftRoute(
            sourceSessionID: sourceSessionID,
            sourceDraftText: text,
            currentComposerText: sourceSessionID == currentSessionID ? text : nil
        )
    }

    static func navigationDisposition(
        detachFinalizationOnSessionSwitch: Bool,
        finalizationID: UUID?,
        sourceSessionID: String?,
        currentSessionID: String?
    ) -> ChatSpeechNavigationDisposition {
        if detachFinalizationOnSessionSwitch,
           finalizationID != nil,
           sourceSessionID != currentSessionID {
            return .detachFinalization
        }
        return .cancelAndPreserve
    }
}
