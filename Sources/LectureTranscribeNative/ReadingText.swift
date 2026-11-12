import Foundation
import NaturalLanguage

/// A word of the text being read aloud, and where it sits in the text. Ranges count UTF-16 units, as the text view
/// does, so a word's range is exactly what gets highlighted and what a click lands on.
struct ReadingWord: Equatable, Sendable {
    let range: NSRange
    let text: String
}

/// One piece of the text that is spoken in one go: a sentence, or part of a very long one.
struct ReadingSentence: Equatable, Sendable {
    let range: NSRange
    /// What the voice is given: the sentence with formatting marks (Markdown's `#`, `*` and the like) taken out.
    let spokenText: String
    let words: [ReadingWord]
}

/// Where reading is, as a sentence and a word in it.
struct ReadingPosition: Equatable, Hashable, Sendable {
    var sentence: Int
    var word: Int
}

/// The text of the Listen pane, split into sentences and words for speaking and highlighting.
struct ReadingDocument: Equatable, Sendable {
    /// Longest piece spoken in one go. Longer sentences are split at a comma or other pause, then at a space:
    /// the voice model starts faster and keeps its pace better on short pieces.
    static let maxSentenceLength = 280

    let text: String
    let sentences: [ReadingSentence]

    init(text: String) {
        self.text = text
        sentences = Self.split(text)
    }

    var isEmpty: Bool { sentences.isEmpty }

    var wordCount: Int { sentences.reduce(0) { $0 + $1.words.count } }

    /// The word at a place in the text (a click), or the word just after it when the place is between words.
    func position(at location: Int) -> ReadingPosition? {
        guard !sentences.isEmpty else { return nil }
        for (sentenceIndex, sentence) in sentences.enumerated() {
            for (wordIndex, word) in sentence.words.enumerated() where location < NSMaxRange(word.range) {
                return ReadingPosition(sentence: sentenceIndex, word: wordIndex)
            }
        }
        return nil
    }

    func word(at position: ReadingPosition) -> ReadingWord? {
        guard sentences.indices.contains(position.sentence) else { return nil }
        let words = sentences[position.sentence].words
        return words.indices.contains(position.word) ? words[position.word] : nil
    }

    // MARK: - Splitting

    private static func split(_ text: String) -> [ReadingSentence] {
        let nsText = text as NSString
        var sentences: [ReadingSentence] = []

        // Lines first, so a heading or list item without a full stop isn't run into the next line.
        for block in blocks(of: nsText) {
            let tokenizer = NLTokenizer(unit: .sentence)
            // The sentence tokenizer ends a sentence at every line break; a joined block's breaks are just spaces.
            // (One character for one, so ranges still line up with the text.)
            let blockText = nsText.substring(with: block)
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            tokenizer.string = blockText
            tokenizer.enumerateTokens(in: blockText.startIndex..<blockText.endIndex) { tokenRange, _ in
                let local = NSRange(tokenRange, in: blockText)
                let range = NSRange(location: block.location + local.location, length: local.length)
                for piece in pieces(of: range, in: nsText) {
                    if let sentence = sentence(in: piece, of: nsText) {
                        sentences.append(sentence)
                    }
                }
                return true
            }
        }
        return sentences
    }

    /// The text's lines, with lines that were wrapped mid-sentence joined back up: a line that doesn't end in
    /// sentence punctuation runs on into the next when that one starts with a small letter (a wrapped email or a
    /// pasted PDF), but a heading followed by a capitalised line stays on its own.
    private static func blocks(of text: NSString) -> [NSRange] {
        var lines: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            lines.append(lineRange)
        }
        var blocks: [NSRange] = []
        for line in lines {
            let lineText = text.substring(with: line)
            let trimmed = lineText.trimmingCharacters(in: .whitespaces)
            if let previous = blocks.last,
               let first = trimmed.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first),
               let last = text.substring(with: previous).trimmingCharacters(in: .whitespaces).unicodeScalars.last,
               !CharacterSet(charactersIn: ".!?:;。！？…\"”’)").contains(last) {
                blocks[blocks.count - 1] = NSRange(location: previous.location, length: NSMaxRange(line) - previous.location)
            } else if !trimmed.isEmpty {
                blocks.append(line)
            }
        }
        return blocks
    }

    /// Splits a long sentence at the last pause (`,;:` or a dash) before the limit, or failing that the last space.
    private static func pieces(of range: NSRange, in text: NSString) -> [NSRange] {
        var pieces: [NSRange] = []
        var remaining = range
        while remaining.length > maxSentenceLength {
            let window = NSRange(location: remaining.location, length: maxSentenceLength)
            var cut = NSNotFound
            for breaks in [",;:—–", " \t"] {
                let set = CharacterSet(charactersIn: breaks)
                let found = text.rangeOfCharacter(from: set, options: .backwards, range: window)
                // Not too near the start, or the first piece would be a word or two.
                if found.location != NSNotFound, found.location - remaining.location >= maxSentenceLength / 4 {
                    cut = NSMaxRange(found)
                    break
                }
            }
            if cut == NSNotFound { cut = NSMaxRange(window) }
            pieces.append(NSRange(location: remaining.location, length: cut - remaining.location))
            remaining = NSRange(location: cut, length: NSMaxRange(remaining) - cut)
        }
        if remaining.length > 0 { pieces.append(remaining) }
        return pieces
    }

    private static func sentence(in range: NSRange, of text: NSString) -> ReadingSentence? {
        let words = words(in: range, of: text)
        guard let first = words.first, let last = words.last else { return nil }
        // From the first word's line-start marks (like a list's "- ") to the end of the sentence's punctuation.
        let raw = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStart = text.range(of: raw, options: [], range: range).location
        let start = trimmedStart == NSNotFound ? first.range.location : min(trimmedStart, first.range.location)
        let end = max(NSMaxRange(last.range), trimmedStart == NSNotFound ? 0 : trimmedStart + (raw as NSString).length)
        return ReadingSentence(
            range: NSRange(location: start, length: end - start),
            spokenText: spokenText(raw),
            words: words
        )
    }

    /// Words are runs of text between spaces, without the punctuation around them, which is how the aligner splits
    /// text too. Runs in scripts written without spaces (Chinese, Japanese, Thai…) are split into words by the system.
    private static func words(in range: NSRange, of text: NSString) -> [ReadingWord] {
        var words: [ReadingWord] = []
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            let gap = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: [], range: NSRange(location: index, length: end - index))
            guard gap.location != NSNotFound else { break }
            let next = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: [], range: NSRange(location: gap.location, length: end - gap.location))
            let chunkEnd = next.location == NSNotFound ? end : next.location
            let chunk = NSRange(location: gap.location, length: chunkEnd - gap.location)
            words.append(contentsOf: wordsInChunk(chunk, of: text))
            index = chunkEnd
        }
        return words
    }

    private static func wordsInChunk(_ chunk: NSRange, of text: NSString) -> [ReadingWord] {
        let chunkText = text.substring(with: chunk)
        if chunkText.unicodeScalars.contains(where: isUnspacedScript) {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = chunkText
            var words: [ReadingWord] = []
            tokenizer.enumerateTokens(in: chunkText.startIndex..<chunkText.endIndex) { tokenRange, _ in
                let local = NSRange(tokenRange, in: chunkText)
                let range = NSRange(location: chunk.location + local.location, length: local.length)
                words.append(ReadingWord(range: range, text: String(chunkText[tokenRange])))
                return true
            }
            return words
        }
        // Trim punctuation and symbols from both ends; a chunk that is nothing but those ("—", "*", "1.") is
        // kept only if it has a letter or digit.
        let trimmable = CharacterSet.punctuationCharacters.union(.symbols)
        let scalars = Array(chunkText.unicodeScalars)
        guard let firstKept = scalars.firstIndex(where: { !trimmable.contains($0) }),
              let lastKept = scalars.lastIndex(where: { !trimmable.contains($0) })
        else { return [] }
        let kept = String(String.UnicodeScalarView(scalars[firstKept...lastKept]))
        guard kept.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return [] }
        let leading = String(String.UnicodeScalarView(scalars[..<firstKept])).utf16.count
        return [ReadingWord(range: NSRange(location: chunk.location + leading, length: kept.utf16.count), text: kept)]
    }

    private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, // CJK ideographs
             0x0E00...0x0EFF, // Thai, Lao
             0x1000...0x109F, // Myanmar
             0x1780...0x17FF: // Khmer
            return true
        default:
            return false
        }
    }

    /// Formatting marks the voice would otherwise read out ("hash", "asterisk").
    private static func spokenText(_ text: String) -> String {
        var spoken = text.replacingOccurrences(of: #"[#*_`>|~]+"#, with: " ", options: .regularExpression)
        spoken = spoken.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return spoken.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Word timing

/// When a word is spoken, in seconds from the start of its sentence's audio.
struct WordTime: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
}

/// A word and its time, as the aligner reports them.
struct AlignedWordTime: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// Matches the aligner's words to the sentence's words, so every word on screen gets a time even where the two
/// split the text differently ("e.g." against "eg", "well-known" against "well" + "known") or the aligner
/// skipped a word. Words the aligner didn't time are spread between their neighbours by length.
enum WordTimingMatcher {
    static func timings(for words: [String], aligned: [AlignedWordTime], duration: Double) -> [WordTime] {
        guard !words.isEmpty else { return [] }
        let duration = max(duration, 0)
        let mine = words.map(normalized)
        let theirs = aligned.map { normalized($0.text) }
        var times = [WordTime?](repeating: nil, count: words.count)

        var i = 0
        var j = 0
        while i < mine.count, j < theirs.count {
            if mine[i] == theirs[j] {
                times[i] = WordTime(start: aligned[j].start, end: aligned[j].end)
                i += 1
                j += 1
                continue
            }
            // One of my words spoken as several of theirs ("well-known" → "well", "known").
            if !theirs[j].isEmpty, mine[i].hasPrefix(theirs[j]) {
                var joined = theirs[j]
                var k = j
                while joined.count < mine[i].count, k + 1 < theirs.count, mine[i].hasPrefix(joined + theirs[k + 1]) {
                    k += 1
                    joined += theirs[k]
                }
                if joined == mine[i] {
                    times[i] = WordTime(start: aligned[j].start, end: aligned[k].end)
                    i += 1
                    j = k + 1
                    continue
                }
            }
            // Several of my words as one of theirs: leave them for the spreading below, inside its span.
            if !mine[i].isEmpty, theirs[j].hasPrefix(mine[i]) {
                var joined = mine[i]
                var k = i
                while joined.count < theirs[j].count, k + 1 < mine.count, theirs[j].hasPrefix(joined + mine[k + 1]) {
                    k += 1
                    joined += mine[k]
                }
                if joined == theirs[j], k > i {
                    spread(&times, words: words, from: i, through: k, start: aligned[j].start, end: aligned[j].end)
                    i = k + 1
                    j += 1
                    continue
                }
            }
            // The aligner skipped one of my words, or has an extra word: look a few words ahead on each side.
            if let skip = (1...3).first(where: { j + $0 < theirs.count && theirs[j + $0] == mine[i] }) {
                j += skip
                continue
            }
            if (1...3).contains(where: { i + $0 < mine.count && mine[i + $0] == theirs[j] }) {
                i += 1
                continue
            }
            // A different spelling of the same word ("2024" spoken as "twenty twenty-four" is still one word).
            times[i] = WordTime(start: aligned[j].start, end: aligned[j].end)
            i += 1
            j += 1
        }

        fillGaps(&times, words: words, duration: duration)
        return makeMonotonic(times.map { $0! }, duration: duration)
    }

    /// Which word is being spoken at a time in the sentence: the last one that has started, so the highlight stays
    /// on a word through the pause after it.
    static func wordIndex(at time: Double, in timings: [WordTime]) -> Int? {
        guard let first = timings.first else { return nil }
        if time < first.start { return 0 }
        var low = 0
        var high = timings.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if timings[mid].start <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    private static func weight(_ word: String) -> Double { Double(max(word.count, 1)) }

    private static func spread(_ times: inout [WordTime?], words: [String], from first: Int, through last: Int, start: Double, end: Double) {
        guard first <= last else { return }
        let total = (first...last).reduce(0.0) { $0 + weight(words[$1]) }
        var cursor = start
        for index in first...last {
            let length = (end - start) * weight(words[index]) / total
            times[index] = WordTime(start: cursor, end: cursor + length)
            cursor += length
        }
    }

    private static func fillGaps(_ times: inout [WordTime?], words: [String], duration: Double) {
        var index = 0
        while index < times.count {
            guard times[index] == nil else {
                index += 1
                continue
            }
            var last = index
            while last + 1 < times.count, times[last + 1] == nil { last += 1 }
            let start = index > 0 ? times[index - 1]!.end : 0
            let end = last + 1 < times.count ? times[last + 1]!.start : duration
            spread(&times, words: words, from: index, through: last, start: start, end: max(end, start))
            index = last + 1
        }
    }

    /// Times only move forward and stay inside the audio, whatever the aligner reported.
    private static func makeMonotonic(_ times: [WordTime], duration: Double) -> [WordTime] {
        var result: [WordTime] = []
        var floor = 0.0
        for time in times {
            let start = min(max(time.start, floor), duration)
            let end = min(max(time.end, start), duration)
            result.append(WordTime(start: start, end: end))
            floor = start
        }
        return result
    }
}
