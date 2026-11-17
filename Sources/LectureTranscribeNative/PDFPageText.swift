import Foundation

/// A PDF's pages as text to read aloud, without the running headers and footers printed on every page ("The Tempest
/// — Reading Guide", "Page 3 of 43"). Read aloud, they broke into the text between every two pages.
enum PDFPageText {
    /// How many lines at the top and bottom of a page can be a header or footer.
    static let edgeLines = 3

    /// `pages` (each page's text, its lines as PDFKit gives them) with the lines removed that sit at the top or bottom
    /// of most pages, page numbers aside: on at least three pages and half of them, and not ending like a sentence.
    /// Body text that happens to repeat stays, the document's first line (its title) stays, and documents of one or two
    /// pages are left as they are.
    static func withoutHeadersAndFooters(_ pages: [String]) -> [String] {
        guard pages.count >= 3 else { return pages }
        let pageLines = pages.map { $0.components(separatedBy: .newlines) }
        var pagesWithLine: [String: Int] = [:]
        for lines in pageLines {
            for line in Set(edgeIndices(of: lines).map({ key(lines[$0]) })) {
                pagesWithLine[line, default: 0] += 1
            }
        }
        let needed = max(3, (pages.count + 1) / 2)
        // A line ending like a sentence is text, even when every page has it.
        let repeated = Set(pagesWithLine.filter { line, count in
            count >= needed && !(line.last.map { ".!?".contains($0) } ?? false)
        }.keys)
        guard !repeated.isEmpty else { return pages }
        return zip(pages, pageLines).enumerated().map { pageIndex, item in
            let (page, lines) = item
            var dropped = Set(edgeIndices(of: lines).filter { repeated.contains(key(lines[$0])) })
            // The document's first line is its title, even when every page repeats it as a header or footer.
            if pageIndex == 0, let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                dropped.remove(first)
            }
            guard !dropped.isEmpty else { return page }
            // Everything else, blank lines between paragraphs included, stays as it was.
            return lines.indices.filter { !dropped.contains($0) }.map { lines[$0] }.joined(separator: "\n")
        }
    }

    /// Where the first and last `edgeLines` lines with something on them are.
    private static func edgeIndices(of lines: [String]) -> [Int] {
        let filled = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        return Array(Set(filled.prefix(edgeLines) + filled.suffix(edgeLines))).sorted()
    }

    /// A line as compared across pages: numbers (the page number) stand for any number, and case and spacing
    /// don't count.
    private static func key(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
