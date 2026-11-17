import Foundation

/// Writes the numbers in a text out as words ("1990" → "nineteen ninety", "3.5%" → "three point five percent").
///
/// The voice says a number as several words, but the word aligner is given the text it was asked to say; with the
/// digits it had nothing to match the words it heard against, so the highlight stuck on a number and fell behind
/// after it. Giving both the voice and the aligner the words, and mapping the words back onto the number they came
/// from (`ReadingSentence.spokenWords(in:)`), keeps the highlight with the voice through numbers.
///
/// Only languages written with spaces between words are changed; the others are left as they are.
enum SpokenNumbers {
    static func spoken(_ text: String, language: ListenLanguage) -> String {
        guard let locale = locale(for: language), text.contains(where: \.isNumber) else { return text }
        let english = language == .english
        var result = text
        if english {
            // "$5" and "£5": the amount first, so it's read as "five dollars".
            result = replacing(#"([$£€])(\d[\d,]*(?:\.\d+)?)"#, in: result) { match in
                let amount = match[2]
                let unit = ["$": "dollars", "£": "pounds", "€": "euros"][match[1]] ?? ""
                let parts = amount.split(separator: ".", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[1].count == 2, let cents = Int(parts[1]) {
                    return cents == 0 ? "\(parts[0]) \(unit)" : "\(parts[0]) \(unit) \(cents) cents"
                }
                return "\(amount) \(unit)"
            }
            // "p. 67" and "pp. 67–79": page and pages, not the letter p.
            result = replacing(Self.pageAbbreviation, in: result) { match in match[1].count == 1 ? "page " : "pages " }
            // "1990–1995" and "10-20": a range.
            result = replacing(#"(?<=\d)\s?[–—-]\s?(?=\d)"#, in: result) { _ in " to " }
            // "1.2.345", a reference like act, scene and line: each part as a number, "one two three hundred
            // forty-five", rather than "one point two" and a stray ".345".
            result = replacing(#"(?<![\p{L}\d.,])(\d+(?:\.\d+){2,})(?![\p{L}\d]|\.\d)"#, in: result) { match in
                let parts = match[1].split(separator: ".").map { part in Int(part).flatMap { spellOut($0) } ?? String(part) }
                return parts.joined(separator: " ")
            }
        }
        // Numbers, with thousands separators and decimals, then an ordinal or plural ending and a percent sign.
        let pattern = english
            ? #"(?<![\p{L}\d.,])(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?(st|nd|rd|th|s)?(?![\p{L}\d])(\s?%)?"#
            : #"(?<![\p{L}\d.,])(\d+)(?![\p{L}\d])(?![.,]\d)(\s?%)?"#
        return replacing(pattern, in: result) { match in
            let whole = match[1].replacingOccurrences(of: ",", with: "")
            guard whole.count <= 15, let value = Int(whole) else { return match[0] }
            if !english {
                guard let words = spellOut(value, locale: locale) else { return match[0] }
                return match[2].isEmpty ? words : "\(words) \(percentWord(for: language))"
            }
            let decimals = match[2]
            let ending = match[3]
            var words: String
            if !decimals.isEmpty {
                guard let integer = spellOut(value, locale: locale) else { return match[0] }
                let digits = decimals.compactMap { $0.wholeNumberValue }.compactMap { spellOut($0, locale: locale) }
                words = ([integer, "point"] + digits).joined(separator: " ")
            } else if !match[1].contains(","), let year = yearWords(value) {
                words = year
            } else {
                guard let spelled = spellOut(value, locale: locale) else { return match[0] }
                words = spelled
            }
            switch ending {
            case "st", "nd", "rd", "th": words = changingLastWord(of: words, with: ordinal)
            case "s": words = changingLastWord(of: words, with: plural)
            default: break
            }
            if !match[4].isEmpty { words += " percent" }
            return words
        }
    }

    // MARK: - English

    /// "p." or "pp." just before a number.
    static let pageAbbreviation = #"(?<![\p{L}])([pP]{1,2})\.\s?(?=\d)"#

    /// A number that reads as a year ("nineteen ninety", "two thousand five", "twenty twenty-four"), or nil.
    static func yearWords(_ value: Int) -> String? {
        switch value {
        case 2000:
            return "two thousand"
        case 2001...2009:
            return "two thousand \(spellOut(value - 2000)!)"
        case 1100...1999, 2010...2099:
            let century = spellOut(value / 100)!
            let rest = value % 100
            if rest == 0 { return "\(century) hundred" }
            if rest < 10 { return "\(century) oh \(spellOut(rest)!)" }
            return "\(century) \(spellOut(rest)!)"
        default:
            return nil
        }
    }

    private static func ordinal(_ word: String) -> String {
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                         "nine": "ninth", "twelve": "twelfth"]
        if let word = irregular[word] { return word }
        if word.hasSuffix("y") { return word.dropLast() + "ieth" }
        return word + "th"
    }

    private static func plural(_ word: String) -> String {
        if word.hasSuffix("y") { return word.dropLast() + "ies" }
        if word.hasSuffix("x") { return word + "es" }
        return word + "s"
    }

    /// Changes the last word, or the last part of a hyphenated one ("twenty-one" → "twenty-first").
    private static func changingLastWord(of words: String, with change: (String) -> String) -> String {
        var parts = words.components(separatedBy: " ")
        guard let last = parts.popLast() else { return words }
        var pieces = last.components(separatedBy: "-")
        if let final = pieces.popLast() { pieces.append(change(final)) }
        parts.append(pieces.joined(separator: "-"))
        return parts.joined(separator: " ")
    }

    // MARK: - Spelling out

    private static func locale(for language: ListenLanguage) -> Locale? {
        switch language {
        case .english: return Locale(identifier: "en_US")
        case .german: return Locale(identifier: "de_DE")
        case .french: return Locale(identifier: "fr_FR")
        case .spanish: return Locale(identifier: "es_ES")
        case .italian: return Locale(identifier: "it_IT")
        case .portuguese: return Locale(identifier: "pt_BR")
        case .russian: return Locale(identifier: "ru_RU")
        // Chinese, Japanese and Korean aren't written with spaces between words, and the voice reads their digits.
        case .automatic, .chinese, .japanese, .korean: return nil
        }
    }

    private static func percentWord(for language: ListenLanguage) -> String {
        switch language {
        case .german: return "Prozent"
        case .french: return "pour cent"
        case .spanish: return "por ciento"
        case .italian: return "per cento"
        case .portuguese: return "por cento"
        case .russian: return "процентов"
        default: return "percent"
        }
    }

    private static func spellOut(_ value: Int, locale: Locale = Locale(identifier: "en_US")) -> String? {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .spellOut
        // German (and others) mark where a long number word may break with soft hyphens, which the voice mustn't get.
        return formatter.string(from: NSNumber(value: value))?.replacingOccurrences(of: "\u{AD}", with: "")
    }

    /// Replaces each match of `pattern` with what `make` returns for its groups (missing groups are empty).
    private static func replacing(_ pattern: String, in text: String, make: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            result += nsText.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : nsText.substring(with: range)
            }
            result += make(groups)
            last = NSMaxRange(match.range)
        }
        result += nsText.substring(from: last)
        return result
    }
}

extension ReadingSentence {
    /// What the voice is given for this sentence in `language`: `spokenText` with its numbers written out.
    func voiceText(in language: ListenLanguage) -> String {
        SpokenNumbers.spoken(spokenText, language: language)
    }

    /// The words the voice says for each of the sentence's words: the word itself, or for a number the words it's
    /// read as. One list per word in `words`.
    func spokenWords(in language: ListenLanguage) -> [[String]] {
        words.enumerated().map { index, word in
            // "p" and "pp" before a number are read as page and pages (see `SpokenNumbers.spoken`).
            if language == .english, ["p", "pp"].contains(word.text.lowercased()),
               words.indices.contains(index + 1), words[index + 1].text.first?.isNumber == true {
                return [word.text.count == 1 ? "page" : "pages"]
            }
            let spoken = SpokenNumbers.spoken(word.text, language: language)
                .split(whereSeparator: \.isWhitespace).map(String.init)
            return spoken.isEmpty ? [word.text] : spoken
        }
    }
}
