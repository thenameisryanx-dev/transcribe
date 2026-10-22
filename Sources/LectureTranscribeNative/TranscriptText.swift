import Foundation

/// Text handling for transcripts, ported from the Python backend (`lecture_transcribe.py`). Each function returns
/// exactly what its Python namesake does; Tests/golden/text_functions.json records those answers.
enum TranscriptText {
    // Repeated-passage check: wording is compared in overlapping phrases of this many words, and only a long
    // run of mostly repeated wording is flagged (short repeats like "Almost there. Almost there." are speech).
    static let repeatPhraseWords = 8
    static let repeatMinWords = 50
    static let repeatMatchShare = 0.7
    /// How much of the previous chunk's transcript is carried into the next chunk's prompt.
    static let contextTailChars = 300
    /// Shortest repeat of that excerpt removed from the start of the next chunk.
    static let echoMinWords = 4
    /// More words per minute than anyone speaks means the model repeated itself.
    static let maxPlausibleWordsPerMinute = 350.0

    /// Words as Python's `str.split()` finds them.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Where one sentence ends and the next begins (`SENTENCE_BREAK`): punctuation followed by a space, or
    /// a missing space ("why not?What if"), but never after a title ("Dr. Doom") or before a lowercase word.
    private static let sentenceBreak = try! NSRegularExpression(
        pattern: #"(?<!\bMr\.)(?<!\bMrs\.)(?<!\bMs\.)(?<!\bDr\.)(?<!\bSt\.)(?<!\bJr\.)(?<!\bProf\.)"#
            + #"(?:(?<=[.!?])\s+(?![a-z])|(?<=[a-z0-9][.!?])(?=[A-Z])|(?<=[a-z0-9]\.\.\.)(?=[A-Z]))"#
    )

    static func sentenceLines(_ text: String) -> [String] {
        let cleaned = words(text).joined(separator: " ")
        guard !cleaned.isEmpty else { return [] }
        let string = cleaned as NSString
        var pieces: [String] = []
        var start = 0
        for match in sentenceBreak.matches(in: cleaned, range: NSRange(location: 0, length: string.length)) {
            // Like Python's re.split, an empty match right where the last piece ended doesn't split again.
            if match.range.length == 0 && match.range.location == start && start > 0 { continue }
            pieces.append(string.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range.location + match.range.length
        }
        pieces.append(string.substring(from: start))
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The last whole sentences of `text` that fit in `maxChars`, or the end of one long sentence.
    static func transcriptTail(_ text: String, maxChars: Int = contextTailChars) -> String {
        var tail: [String] = []
        var length = 0
        for sentence in sentenceLines(text).reversed() {
            if !tail.isEmpty && length + 1 + sentence.count > maxChars { break }
            tail.insert(sentence, at: 0)
            length += sentence.count + (length > 0 ? 1 : 0)
        }
        let joined = tail.joined(separator: " ")
        guard joined.count > maxChars else { return joined }
        // A single sentence longer than the limit: keep its end, starting at a word boundary.
        let cut = String(joined.suffix(maxChars))
        if let space = cut.firstIndex(of: " "), cut.index(after: space) < cut.endIndex {
            return String(cut[cut.index(after: space)...])
        }
        return cut
    }

    /// A word compared without case or punctuation (`_word_key`).
    static func wordKey(_ word: String) -> String {
        let folded = word.folding(options: [.caseInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }))
    }

    /// The previous chunk's closing words removed if the model repeated them at the start of `text`, and how
    /// many words that was. Short overlaps stay, since a speaker can say the same couple of words again.
    static func stripEchoedTail(_ text: String, tail: String) -> (text: String, removed: Int) {
        let textWords = words(text)
        let keys = textWords.map(wordKey)
        let tailKeys = words(tail).map(wordKey)
        var n = min(tailKeys.count, textWords.count)
        while n >= echoMinWords {
            if Array(keys.prefix(n)) == Array(tailKeys.suffix(n)) {
                return (textWords.dropFirst(n).joined(separator: " "), n)
            }
            n -= 1
        }
        return (text, 0)
    }

    /// The longest passage of at least `repeatMinWords` words that mostly repeats earlier wording, as
    /// (approximate length in words, its opening words), or nil.
    static func findRepeatedPassage(_ text: String) -> (length: Int, opening: String)? {
        let textWords = words(text)
        let keys = textWords.map(wordKey)
        let n = repeatPhraseWords
        guard keys.count >= repeatMinWords + n else { return nil }

        // repeated[i]: the phrase starting at word i already appeared earlier, without overlapping itself.
        var firstSeen: [[String]: Int] = [:]
        var repeated = [Bool](repeating: false, count: keys.count)
        for i in 0...(keys.count - n) {
            let phrase = Array(keys[i..<(i + n)])
            let earlier = firstSeen[phrase] ?? i
            if firstSeen[phrase] == nil { firstSeen[phrase] = i }
            if earlier + n <= i { repeated[i] = true }
        }

        // Slide a window and merge windows where enough phrases repeat into passages.
        let window = repeatMinWords
        let needed = repeatMatchShare * Double(window)
        var count = repeated[0..<window].filter { $0 }.count
        var best: (start: Int, end: Int)?
        var start = -1, end = -1
        for i in 0...(keys.count - window) {
            if i > 0 {
                count += (repeated[i + window - 1] ? 1 : 0) - (repeated[i - 1] ? 1 : 0)
            }
            if Double(count) >= needed {
                if i > end { start = i }
                end = i + window
                if best == nil || end - start > best!.end - best!.start { best = (start, end) }
            }
        }
        guard let best, let first = (best.start..<best.end).first(where: { repeated[$0] }) else { return nil }
        return (best.end - first, textWords[first..<min(first + 8, textWords.count)].joined(separator: " "))
    }

    /// The prompt for one chunk: the user's context, then the previous chunk's closing words if any.
    static func chunkPrompt(context: String?, previousTail: String?) -> String? {
        var parts: [String] = []
        if let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(context.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let previousTail, !previousTail.isEmpty {
            parts.append("The recording begins right after this transcript excerpt:\n\"…\(previousTail)\"")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// More words than could be spoken in `durationSeconds` (a 50-word allowance covers very short chunks).
    static func looksRepeated(_ text: String, durationSeconds: Double) -> Bool {
        guard durationSeconds > 0 else { return false }
        return Double(words(text).count) > max(50.0, maxPlausibleWordsPerMinute * durationSeconds / 60.0)
    }

    static func hhmmss(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// The file name without its extension, with anything but letters, digits and `._-` replaced by `_`.
    static func safeStem(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
    }

    /// The lines at the top of a transcript file (`build_transcript_header`). `context` "" writes "none"; nil
    /// leaves the line out.
    static func header(
        inputPath: String,
        workingInputPath: String,
        model: String,
        responseFormat: String? = nil,
        chunkingStrategy: String? = nil,
        localChunkSeconds: Int? = nil,
        durationSeconds: Double? = nil,
        languages: [String] = [],
        context: String? = nil,
        keywords: [String] = [],
        consistencyMode: Bool? = nil,
        chunkWarnings: [String] = []
    ) -> String {
        var lines = ["INPUT: \(inputPath)", "WORKING_INPUT: \(workingInputPath)", "MODEL: \(model)"]
        if let responseFormat { lines.append("RESPONSE_FORMAT: \(responseFormat)") }
        if let chunkingStrategy { lines.append("CHUNKING_STRATEGY: \"\(chunkingStrategy)\"") }
        if let localChunkSeconds { lines.append("LOCAL_CHUNK_SECONDS: \(localChunkSeconds)") }
        if let durationSeconds { lines.append(String(format: "DURATION_SECONDS: %.3f", durationSeconds)) }
        if !languages.isEmpty { lines.append("LANGUAGES: \(languages.joined(separator: ", "))") }
        if let context {
            // One line, so a multi-line context can't push the header into the transcript.
            let oneLine = words(context).joined(separator: " ")
            lines.append("CONTEXT: \(oneLine.isEmpty ? "none" : oneLine)")
        }
        if !keywords.isEmpty { lines.append("KEYWORDS: \(keywords.joined(separator: ", "))") }
        if let consistencyMode { lines.append("CONSISTENCY_MODE: \(consistencyMode ? "on" : "off")") }
        lines += chunkWarnings.map { "WARNING: \($0)" }
        return lines.joined(separator: "\n") + "\n\n"
    }
}
