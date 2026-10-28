import Foundation

/// Subtitles (.srt) made from the diarize model's timed segments, ported from the Python backend
/// (`lecture_transcribe.py`). Each function returns exactly what its Python namesake does;
/// Tests/golden/text_functions.json records those answers. Lengths count Unicode code points, like Python's `len`.
enum SubtitleText {
    // Limits follow Netflix's English (USA) Timed Text Style Guide and its Subtitle Timing Guidelines.
    static let lineChars = 42
    static let maxLines = 2
    /// Longest a cue stays on screen.
    static let maxSeconds = 7.0
    /// Shortest a cue stays on screen (20 frames at 24fps).
    static let minSeconds = 5.0 / 6.0
    /// Adult reading speed, characters per second; slower text stays up longer.
    static let readingCPS = 20.0
    /// A cue stays up this long after its speech ends, so it isn't gone mid-read.
    static let lingerSeconds = 0.5
    /// 2 frames between cues, so the eye sees one cue replace another.
    static let minGapSeconds = 2.0 / 24.0
    /// Shorter gaps than this look like flicker, so the earlier cue is held to the next.
    static let chainGapSeconds = 0.5
    /// Netflix English style: a hyphen with no space.
    static let dialogueDash = "-"
    static let sentenceEnds = [".", "?", "!", "…", "\"", "”"]
    /// This many characters of uneven length cost as much as one rule point.
    static let breakBalanceChars = 10.0

    static var maxCueChars: Int { lineChars * maxLines }

    /// Who speaks in a cue: the diarize model's labels restart in every request, so they're scoped to a chunk.
    struct Speaker: Equatable {
        let chunk: Int
        let label: String
    }

    struct Cue: Equatable {
        var start: Double
        /// When the cue's speech ends (estimated when a long segment was split); `srt` sets the on-screen end.
        var end: Double
        var text: String
        var speaker: Speaker?
        /// Set for a two-speaker cue: one dash-prefixed line per speaker, shown as is.
        var lines: [String]?
    }

    static func length(_ text: String) -> Int { text.unicodeScalars.count }

    static func timestamp(_ seconds: Double) -> String {
        // Python's round() rounds halves to even.
        let ms = max(0, Int((seconds * 1000).rounded(.toNearestOrEven)))
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms % 3_600_000) / 60_000, (ms % 60_000) / 1000, ms % 1000)
    }

    // MARK: - Line breaks

    // Where a subtitle may break, after Netflix's English line-break rules: break after punctuation, before a
    // conjunction or preposition; never between an article and its noun, a preposition and its object, a subject
    // pronoun or auxiliary and its verb, a verb and "not", or a first and last name. Lower cost is better.
    private static func wordSet(_ words: String) -> Set<String> { Set(words.split(separator: " ").map(String.init)) }
    private static let conjunctions = wordSet(
        "and but or nor so yet because that which who whom whose when whenever while if unless until although "
            + "though since where whether than"
    )
    private static let prepositions = wordSet(
        "to in on at with from for of about into onto over under after before through without between around "
            + "across against during behind near toward towards like by"
    )
    private static let determiners = wordSet("the a an this these those my your his her its our their some any no every each")
    private static let subjectPronouns = wordSet("i we they he she")
    private static let auxiliaries = wordSet(
        "am is are was were be been being have has had do does did will would shall should can could may might "
            + "must i'm you're we're they're he's she's it's i've you've we've they've i'll you'll we'll they'll i'd "
            + "you'd we'd they'd don't doesn't didn't won't wouldn't can't couldn't shouldn't isn't aren't wasn't "
            + "weren't haven't hasn't hadn't not"
    )
    private static let sentenceEndPunctuation = [".", "?", "!", "…"]
    private static let pausePunctuation = [",", ";", ":", "—", "–", "-"]
    private static let quoteCharacters = Set("\"'“”‘’()[]".unicodeScalars)

    private static func trimmingQuotes(_ word: String, leading: Bool = true) -> String {
        var scalars = Substring(word).unicodeScalars[...]
        while let last = scalars.last, quoteCharacters.contains(last) { scalars = scalars.dropLast() }
        while leading, let first = scalars.first, quoteCharacters.contains(first) { scalars = scalars.dropFirst() }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func bareWord(_ word: String) -> String {
        trimmingQuotes(word).lowercased().replacingOccurrences(of: "’", with: "'")
    }

    private static func startsUppercase(_ word: String) -> Bool {
        word.unicodeScalars.first.map { $0.properties.isUppercase } ?? false
    }

    /// Cost of ending a line or cue after `left` and starting the next with `right`.
    static func breakCost(_ left: String, _ right: String) -> Double {
        let tail = trimmingQuotes(left, leading: false)
        if sentenceEndPunctuation.contains(where: tail.hasSuffix) { return -6 }
        if pausePunctuation.contains(where: tail.hasSuffix) { return -4 }
        let before = bareWord(left), after = bareWord(right)
        var cost = 0.0
        if conjunctions.contains(after) {
            cost -= 2
        } else if prepositions.contains(after) {
            cost -= 1
        }
        if determiners.contains(before) { cost += 6 }
        if prepositions.contains(before) || subjectPronouns.contains(before) || auxiliaries.contains(before) { cost += 4 }
        // "and" belongs at the start of the next line, not the end of this one.
        if conjunctions.contains(before) { cost += 3 }
        if after == "not" { cost += 4 }
        // Likely a name ("John | Smith").
        if startsUppercase(left) && startsUppercase(right) && before != "i" { cost += 3 }
        return cost
    }

    private static func joinedLength(_ words: [String], _ start: Int, _ stop: Int) -> Int {
        words[start..<stop].reduce(0) { $0 + length($1) } + max(0, stop - start - 1)
    }

    private static func lengthCost(_ length: Int, target: Double, limit: Int) -> Double {
        abs(Double(length) - target) / breakBalanceChars + 100 * Double(max(0, length - limit))
    }

    /// One line if it fits, otherwise two lines broken at the best place (see `breakCost`), keeping both lines
    /// within the limit and close in length, with the bottom line the longer one when it's a close call.
    static func wrap(_ text: String, lineChars: Int = lineChars) -> [String] {
        let words = TranscriptText.words(text)
        if length(text) <= lineChars || words.count < 2 { return [text] }
        let total = Double(joinedLength(words, 0, words.count))
        func cost(_ k: Int) -> Double {
            let top = joinedLength(words, 0, k), bottom = joinedLength(words, k, words.count)
            // Netflix prefers a bottom-heavy pyramid.
            let shape = top > bottom ? 0.5 : 0
            return breakCost(words[k - 1], words[k])
                + lengthCost(top, target: total / 2, limit: lineChars)
                + lengthCost(bottom, target: total / 2, limit: lineChars)
                + shape
        }
        var best = 1
        var bestCost = cost(1)
        for k in 2..<words.count {
            let c = cost(k)
            if c < bestCost { (best, bestCost) = (k, c) }
        }
        return [words[..<best].joined(separator: " "), words[best...].joined(separator: " ")]
    }

    /// Splits text into `parts` pieces of at most `maxChars`, choosing breaks by `breakCost` and even length.
    static func splitAtBestBreaks(_ text: String, parts: Int, maxChars: Int) -> [String] {
        let words = TranscriptText.words(text)
        if parts <= 1 || words.count < parts { return [text] }
        let target = Double(joinedLength(words, 0, words.count)) / Double(parts)
        let m = words.count
        // best[j][k]: lowest cost of splitting words[..<k] into j pieces; back[j][k]: where the last piece starts.
        var best = [[Double]](repeating: [Double](repeating: .infinity, count: m + 1), count: parts + 1)
        var back = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: parts + 1)
        best[0][0] = 0
        for j in 1...parts {
            for k in j...(m - (parts - j)) {
                for a in (j - 1)..<k where best[j - 1][a] != .infinity {
                    var c = best[j - 1][a] + lengthCost(joinedLength(words, a, k), target: target, limit: maxChars)
                    if a > 0 { c += breakCost(words[a - 1], words[a]) }
                    if c < best[j][k] {
                        best[j][k] = c
                        back[j][k] = a
                    }
                }
            }
        }
        var pieces: [String] = []
        var k = m
        for j in stride(from: parts, to: 0, by: -1) {
            let a = back[j][k]
            pieces.append(words[a..<k].joined(separator: " "))
            k = a
        }
        return pieces.reversed()
    }

    /// Splits one segment's text into cue texts: whole sentences packed together, long ones split at natural breaks.
    static func pieces(_ text: String, maxChars: Int = maxCueChars) -> [String] {
        var groups: [String] = []
        for sentence in TranscriptText.sentenceLines(text) {
            if let last = groups.last, length(last) + 1 + length(sentence) <= maxChars {
                groups[groups.count - 1] = last + " " + sentence
            } else {
                groups.append(sentence)
            }
        }
        return groups.flatMap { group in
            let parts = Int((Double(length(group)) / Double(maxChars)).rounded(.up))
            return splitAtBestBreaks(group, parts: parts, maxChars: maxChars)
        }
    }

    // MARK: - Cues

    /// Cues for timed diarize segments, shifted by the chunk's offset in the recording.
    static func cues(_ segments: [TranscriptionResult.Segment], offsetSeconds: Double = 0, chunk: Int = 0) -> [Cue] {
        var cues: [Cue] = []
        for segment in segments {
            let text = TranscriptText.words(segment.text).joined(separator: " ")
            guard let start = segment.start, var end = segment.end, !text.isEmpty else { continue }
            end = max(end, start)
            let speaker = segment.speaker.map { Speaker(chunk: chunk, label: $0) }
            let pieces = pieces(text)
            let totalChars = Double(pieces.reduce(0) { $0 + length($1) })
            var t = start
            for piece in pieces {
                let share = (end - start) * Double(length(piece)) / totalChars
                cues.append(Cue(start: offsetSeconds + t, end: offsetSeconds + t + share, text: piece, speaker: speaker))
                t += share
            }
        }
        return cues
    }

    /// How long a cue with this many characters needs on screen to be read.
    static func readingSeconds(_ chars: Int) -> Double {
        max(minSeconds, Double(chars) / readingCPS)
    }

    private static func chars(_ cue: Cue) -> Int {
        cue.lines.map { $0.reduce(0) { $0 + length($1) } } ?? length(cue.text)
    }

    /// In order of start time, keeping the order of cues that start together (like Python's stable sort).
    private static func ordered(_ cues: [Cue]) -> [Cue] {
        cues.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    /// Joins a cue with the next one when the next starts before the first could stay up for the shortest time
    /// allowed, whoever speaks, if both fit in one cue and in the longest time a cue may stay up. The diarize model
    /// sometimes returns single words a tenth of a second apart, often with changing speaker labels, which would
    /// otherwise flash by unread (or end before they start). A joined cue can join the next one again.
    static func joinFlashCues(_ cues: [Cue]) -> [Cue] {
        var joined: [Cue] = []
        for cue in ordered(cues) {
            if let last = joined.last,
               cue.start - last.start < minSeconds + minGapSeconds,
               last.lines == nil, cue.lines == nil,
               length(last.text) + 1 + length(cue.text) <= maxCueChars,
               max(last.end, cue.end) - last.start <= maxSeconds
            {
                joined[joined.count - 1] = Cue(start: last.start, end: max(last.end, cue.end), text: "\(last.text) \(cue.text)", speaker: last.speaker)
                continue
            }
            joined.append(cue)
        }
        return joined
    }

    /// Joins a cue with the next one when the next starts before the first can be read, if both fit in one cue
    /// and in the longest time a cue may stay up (a joined cue can join the next one again). The same speaker's
    /// lines are joined as text. Two speakers (in the same chunk, since labels restart in each) get one
    /// dash-prefixed line each, when each line is one whole sentence that fits on a line with its dash.
    static func mergeQuickCues(_ cues: [Cue]) -> [Cue] {
        func fitsDialogueLine(_ cue: Cue) -> Bool {
            length(cue.text) + length(dialogueDash) <= lineChars
                && sentenceEnds.contains(where: cue.text.hasSuffix)
                && TranscriptText.sentenceLines(cue.text).count == 1
        }
        var ordered = ordered(cues)
        var merged: [Cue] = []
        var i = 0
        while i < ordered.count {
            let first = ordered[i]
            let second = i + 1 < ordered.count ? ordered[i + 1] : nil
            guard let second, let firstSpeaker = first.speaker, let secondSpeaker = second.speaker,
                  first.lines == nil, second.lines == nil,
                  // The first line gets less time than it needs before the next one starts.
                  second.start - first.start < readingSeconds(length(first.text)) + lingerSeconds,
                  second.end - first.start <= maxSeconds
            else {
                merged.append(first)
                i += 1
                continue
            }
            if firstSpeaker == secondSpeaker, length(first.text) + 1 + length(second.text) <= maxCueChars {
                // The joined cue takes the next one's place, so a run of quick lines can keep joining while it fits.
                ordered[i + 1] = Cue(start: first.start, end: max(first.end, second.end), text: "\(first.text) \(second.text)", speaker: firstSpeaker)
                i += 1
            } else if firstSpeaker.chunk == secondSpeaker.chunk, fitsDialogueLine(first), fitsDialogueLine(second) {
                merged.append(Cue(
                    start: first.start,
                    end: max(first.end, second.end),
                    text: "\(first.text) \(second.text)",
                    speaker: nil,
                    lines: [dialogueDash + first.text, dialogueDash + second.text]
                ))
                i += 2
            } else {
                merged.append(first)
                i += 1
            }
        }
        return merged
    }

    /// (start, on-screen end, cue) for each cue, in order. A cue appears when its speech starts and stays up
    /// until its speech ends plus a short linger, or longer if its text needs more reading time, but never past
    /// 7 seconds or into the next cue (a 2-frame gap is kept). A gap shorter than half a second is closed, since
    /// a cue blinking off and straight back on reads as flicker. Speech that overlaps the next cue keeps its time,
    /// and so does the shortest time on screen: a cue the next one follows too closely to join (see
    /// `joinFlashCues`) overlaps it rather than flashing by or ending before it starts.
    static func timed(_ cues: [Cue]) -> [(start: Double, end: Double, cue: Cue)] {
        let ordered = ordered(cues)
        return ordered.enumerated().map { i, cue in
            let start = cue.start
            let nextStart = i + 1 < ordered.count ? ordered[i + 1].start : .infinity
            let latest = start + maxSeconds
            let speechEnd = min(cue.end, latest)
            let wanted = min(max(speechEnd + lingerSeconds, start + readingSeconds(chars(cue))), latest)
            let limit = nextStart - minGapSeconds
            // Only speech that really overlaps the next cue (two people talking at once) runs into it; pieces of one
            // segment, which end exactly where the next begins, keep the 2-frame gap.
            let floor = speechEnd > nextStart + minGapSeconds ? speechEnd : min(speechEnd, limit)
            var end = max(min(wanted, limit), floor, start + minSeconds)
            if 0 < limit - end, limit - end < chainGapSeconds - minGapSeconds, limit <= latest {
                end = limit
            }
            return (start, end, cue)
        }
    }

    /// SubRip text for the cues: flashes and quick two-speaker exchanges merged, then timed to the standards above.
    static func srt(_ cues: [Cue]) -> String {
        let blocks = timed(mergeQuickCues(joinFlashCues(cues))).enumerated().map { n, timed in
            let lines = (timed.cue.lines ?? wrap(timed.cue.text)).joined(separator: "\n")
            return "\(n + 1)\n\(timestamp(timed.start)) --> \(timestamp(timed.end))\n\(lines)"
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Speaker labels

    /// "[Speaker] text" lines for a speaker-labelled transcript, one per sentence. The diarize model often splits
    /// one person's sentence at its commas, so timed segments in a row from the same speaker are joined into one
    /// turn, which is then broken into sentences like a plain transcript (a lecture is one long turn). Untimed or
    /// empty segments are left out.
    static func diarizedLines(_ segments: [TranscriptionResult.Segment]) -> [String] {
        var turns: [(speaker: String, texts: [String])] = []
        for segment in segments {
            let text = TranscriptText.words(segment.text).joined(separator: " ")
            guard segment.start != nil, segment.end != nil, !text.isEmpty else { continue }
            let speaker = segment.speaker ?? "Speaker"
            if turns.last?.speaker == speaker {
                turns[turns.count - 1].texts.append(text)
            } else {
                turns.append((speaker, [text]))
            }
        }
        return turns.flatMap { turn in
            TranscriptText.sentenceLines(turn.texts.joined(separator: " ")).map { "[\(turn.speaker)] \($0)" }
        }
    }
}
