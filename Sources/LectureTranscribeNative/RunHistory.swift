import Foundation

/// Rules for the run list in the Runs pane. `TranscribeViewModel` keeps the list and saves it with
/// `TranscriptionHistoryStore`; these work out what the list becomes after each change.
enum RunHistory {
    typealias Entry = TranscriptionHistoryEntry

    /// Older runs are dropped past this many.
    static let maxEntries = 200

    /// Newest first. Runs still marked running were interrupted when the app quit, so they become cancelled;
    /// `changed` says whether any did, so the list is saved again.
    static func loaded(_ entries: [Entry]) -> (entries: [Entry], changed: Bool) {
        var changed = false
        let closed = entries.map { entry -> Entry in
            guard entry.status == .running else { return entry }
            var interrupted = entry
            interrupted.status = .cancelled
            interrupted.finishedAt = interrupted.finishedAt ?? interrupted.startedAt
            interrupted.errorMessage = interrupted.errorMessage ?? "Run interrupted before completion."
            changed = true
            return interrupted
        }
        return (closed.sorted { $0.startedAt > $1.startedAt }, changed)
    }

    /// A run that just started goes first; the oldest runs past `maxEntries` are dropped.
    static func adding(_ entry: Entry, to entries: [Entry]) -> [Entry] {
        Array(([entry] + entries.filter { $0.id != entry.id }).prefix(maxEntries))
    }

    /// The run's outcome recorded, and the run moved to the top. Nil when the run isn't in the list.
    static func finishing(
        _ id: UUID,
        in entries: [Entry],
        status: Entry.Status,
        outputPath: String?,
        errorMessage: String?,
        warnings: [String],
        log: String,
        at finishedAt: Date = Date()
    ) -> [Entry]? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        var entries = entries
        var entry = entries.remove(at: index)
        entry.status = status
        entry.finishedAt = finishedAt
        entry.errorMessage = errorMessage
        entry.warnings = warnings.isEmpty ? nil : warnings
        entry.log = log.isEmpty ? nil : log
        if let outputPath {
            entry.outputPath = outputPath
        }
        return [entry] + entries
    }

    struct Deletion {
        /// The list without the deleted runs.
        var remaining: [Entry]
        /// Selected runs that weren't deleted because they're still running.
        var skippedRunning: Int
        /// A still-selected run to keep selected, if any.
        var keepSelected: UUID?
        var deletedAny: Bool
    }

    /// Deletes the selected runs, except any still running.
    static func deleting(_ selection: Set<UUID>, from entries: [Entry]) -> Deletion {
        let selected = entries.filter { selection.contains($0.id) }
        let deletable = Set(selected.filter { $0.status != .running }.map(\.id))
        return Deletion(
            remaining: entries.filter { !deletable.contains($0.id) },
            skippedRunning: selected.count - deletable.count,
            keepSelected: selection.first { !deletable.contains($0) },
            deletedAny: !deletable.isEmpty
        )
    }

    /// The selection limited to runs still in the list; when nothing is left selected, `preferred` if it's
    /// there, else the newest run.
    static func selection(_ selection: Set<UUID>, in entries: [Entry], preferring preferred: UUID? = nil) -> Set<UUID> {
        let ids = Set(entries.map(\.id))
        let kept = selection.intersection(ids)
        if !kept.isEmpty { return kept }
        if let preferred, ids.contains(preferred) { return [preferred] }
        return entries.first.map { [$0.id] } ?? []
    }
}
