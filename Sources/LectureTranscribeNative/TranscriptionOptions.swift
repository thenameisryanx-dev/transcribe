import Foundation

enum TranscriptionModel: String, CaseIterable, Identifiable, Sendable {
    case gptTranscribe = "gpt-transcribe"
    case gpt4oTranscribe = "gpt-4o-transcribe"
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gptTranscribe:
            return "GPT Transcribe"
        case .gpt4oTranscribe:
            return "GPT-4o Transcribe"
        case .gpt4oMiniTranscribe:
            return "GPT-4o Mini Transcribe"
        }
    }

    var hoverDescription: String {
        switch self {
        case .gptTranscribe:
            return "Experimental. Uses the spoken language you pick (English if auto-detect). Supports speaker diarization. In testing it sometimes skipped quiet or whispered speech."
        case .gpt4oTranscribe:
            return "Accurate and supports speaker diarization."
        case .gpt4oMiniTranscribe:
            return "As accurate as GPT-4o Transcribe in testing, at half the price. Speaker diarization is unavailable."
        }
    }

    // Short subtitle shown under the model name in the toolbar menu.
    // Prices are OpenAI per-minute rates for file transcription; update if they change.
    var menuSubtitle: String {
        switch self {
        case .gptTranscribe:
            return "Experimental · $0.0045/min"
        case .gpt4oTranscribe:
            return "Supports speaker labels · $0.006/min"
        case .gpt4oMiniTranscribe:
            return "Half the price, no speaker labels · $0.003/min"
        }
    }

    // Diarized runs always use gpt-4o-transcribe-diarize; this only gates the toggle.
    var supportsDiarization: Bool {
        self != .gpt4oMiniTranscribe
    }

    /// Carrying the previous chunk's excerpt helped GPT Transcribe in testing, but made the GPT-4o models
    /// loop or invent text at chunk ends.
    var supportsConsistencyMode: Bool {
        self == .gptTranscribe
    }

    /// Only GPT Transcribe accepts keyword hints.
    var supportsKeywords: Bool {
        self == .gptTranscribe
    }

    /// GPT Transcribe drops speech without a language list, so it falls back to English when none is set.
    /// The other models auto-detect when no language is set.
    var requiresSpokenLanguages: Bool {
        self == .gptTranscribe
    }
}

/// How much audio goes into each API request. Cuts still move to the nearest pause.
enum ChunkLength: Int, CaseIterable, Identifiable, Sendable {
    case fiveMinutes = 300
    case tenMinutes = 600

    /// Used until the user picks one. 5-minute chunks dropped fewer words than 10-minute ones in testing.
    static let standard: ChunkLength = .fiveMinutes

    var id: Int { rawValue }
    var seconds: Int { rawValue }

    var displayName: String {
        "\(rawValue / 60) min"
    }
}

struct SpokenLanguage: Identifiable, Hashable {
    /// ISO-639-1 code sent with a run; empty means auto-detect.
    let code: String

    var id: String { code }

    var displayName: String {
        if code.isEmpty { return "Auto-detect" }
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    static let autoDetect = SpokenLanguage(code: "")
    /// GPT Transcribe drops speech without a language, so it falls back to this when auto-detect is chosen.
    static let fallbackCode = "en"

    /// Auto-detect first, then languages sorted by name.
    static let all: [SpokenLanguage] = [autoDetect] + [
        "ar", "zh", "cs", "da", "nl", "en", "fi", "fr", "de", "el", "he", "hi", "hu", "id", "it", "ja",
        "ko", "ms", "no", "fa", "pl", "pt", "ro", "ru", "es", "sv", "tl", "th", "tr", "uk", "ur", "vi",
    ]
    .map(SpokenLanguage.init(code:))
    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

    /// Maps a stored setting (possibly an older comma-separated list) to a supported code, or "" for auto-detect.
    static func normalizedCode(_ stored: String?) -> String {
        let first = stored?
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .first
            .map { $0.lowercased() } ?? ""
        return all.contains { $0.code == first } ? first : ""
    }

    /// Codes sent with a run for `model`.
    static func backendCodes(for code: String, model: TranscriptionModel) -> [String] {
        if !code.isEmpty { return [code] }
        return model.requiresSpokenLanguages ? [fallbackCode] : []
    }
}

/// One audio track in the selected file, as `MediaTools.audioTracks` lists it.
/// Videos often carry one track per language (e.g. Italian first, English second).
struct AudioTrack: Identifiable, Equatable, Sendable, Decodable {
    /// Position among the file's audio tracks, from 0 (ffmpeg's `0:a:N`).
    let index: Int
    /// The file's language tag, usually three letters ("eng"); empty when untagged.
    let language: String
    let title: String
    let codec: String
    let channels: Int?
    let `default`: Bool

    var id: Int { index }

    /// Older three-letter tags that `Locale` doesn't map to two-letter codes.
    private static let bibliographicCodes = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh", "cze": "cs", "dut": "nl", "fre": "fr",
        "geo": "ka", "ger": "de", "gre": "el", "ice": "is", "mac": "mk", "may": "ms", "per": "fa", "rum": "ro",
        "slo": "sk", "tib": "bo", "wel": "cy",
    ]

    /// Two-letter code comparable with `SpokenLanguage` codes, or nil when the track has no language tag.
    var languageCode: String? {
        Self.languageCode(forTag: language)
    }

    /// Two-letter code for a file's language tag ("eng" → "en"), or nil when the tag is empty.
    static func languageCode(forTag tag: String) -> String? {
        guard !tag.isEmpty else { return nil }
        if let code = bibliographicCodes[tag] { return code }
        return Locale.Language(identifier: tag).languageCode?.identifier ?? tag
    }

    var languageName: String? {
        languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0)?.capitalized }
    }

    /// e.g. "Track 2: English · 5.1"
    var displayName: String {
        var parts: [String] = []
        let name = languageName ?? (title.isEmpty ? "Unknown language" : title)
        parts.append(name)
        if !title.isEmpty && title.caseInsensitiveCompare(name) != .orderedSame {
            parts.append(title)
        }
        switch channels {
        case 1: parts.append("Mono")
        case 2: parts.append("Stereo")
        case 6: parts.append("5.1")
        case 8: parts.append("7.1")
        case let count?: parts.append("\(count) channels")
        case nil: break
        }
        return "Track \(index + 1): " + parts.joined(separator: " · ")
    }

    /// The track to start on: the one in the spoken language when there is one, else the file's default track.
    static func preferredIndex(in tracks: [AudioTrack], spokenLanguage: String) -> Int {
        if !spokenLanguage.isEmpty, let match = tracks.first(where: { $0.languageCode == spokenLanguage }) {
            return match.index
        }
        return tracks.first(where: \.default)?.index ?? 0
    }
}

/// Keywords typed as one string, separated by commas or new lines.
enum KeywordList {
    /// Characters OpenAI rejects in a keyword (the whole request fails).
    static let rejectedCharacters: Set<Character> = ["<", ">"]

    /// Trimmed keywords with inner whitespace collapsed, dropping blanks and repeats (ignoring case).
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func isRejected(_ keyword: String) -> Bool {
        keyword.contains(where: rejectedCharacters.contains)
    }

    /// One line for the Runs pane and the Recent menu; parses back to the same keywords.
    static func displayText(_ keywords: [String]) -> String {
        keywords.joined(separator: ", ")
    }
}

enum RecentContextPrompts {
    static let limit = 10

    /// Puts `context` first, dropping an identical earlier copy and anything past `limit`.
    static func adding(_ context: String, to recent: [String]) -> [String] {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recent }
        return Array(([trimmed] + recent.filter { $0 != trimmed }).prefix(limit))
    }

    /// A one-line label for the Recent menu.
    static func menuTitle(for context: String, maxLength: Int = 60) -> String {
        let oneLine = context.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard oneLine.count > maxLength else { return oneLine }
        return String(oneLine.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
