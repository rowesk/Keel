import Foundation

extension KeelStore {
    public func recordHistoryVisit(_ event: HistoryVisitEvent) throws -> HistoryVisit {
        return try database.transaction {
            try recordHistoryVisitInTransaction(event)
        }
    }

    /// A caller can commit related WebKit callbacks atomically. This remains local store work, not coordinator policy.
    public func recordHistoryVisits(_ events: [HistoryVisitEvent]) throws -> [HistoryVisit] {
        try database.transaction {
            var visits: [HistoryVisit] = []
            for (index, event) in events.enumerated() {
                let visit = try recordHistoryVisitInTransaction(event)
                try faultInjector(index)
                visits.append(visit)
            }
            return visits
        }
    }

    private func recordHistoryVisitInTransaction(_ event: HistoryVisitEvent) throws -> HistoryVisit {
        let canonicalURL = try HistoryURLCanonicalizer.canonicalize(event.url)
        let branchID = event.branch.identifier(for: event.browsingSessionID)
        try ensureBrowsingSessionExists(event.browsingSessionID)
        try ensureHistoryBranch(branchID, sessionID: event.browsingSessionID, branch: event.branch, createdAt: event.visitedAt)
        let newURLID = try historyURLID(for: canonicalURL, at: event.visitedAt)

        let changedURLIDs: Set<Int64>
        let needsRegrouping: Bool
        switch event.navigationKind {
        case .reload, .replaceState:
            guard let currentVisitID = event.currentVisitID else { throw HistoryStoreError.missingCurrentVisit }
            guard let current = try historyVisitRow(id: currentVisitID) else { throw HistoryStoreError.missingCurrentVisit }
            guard current.sessionID == event.browsingSessionID, current.branchID == branchID else { throw HistoryStoreError.invalidCurrentVisit }
            try database.execute(
                "UPDATE history_visits SET history_url_id = ?, visited_at = ?, navigation_kind = ?, visit_source = ?, title_at_visit = ?, favicon_reference_key = ? WHERE id = ?",
                values: [
                    .integer(newURLID), .real(event.visitedAt.timeIntervalSince1970), .text(event.navigationKind.rawValue), .text(event.source.rawValue), .text(event.title), .text(event.faviconReferenceKey), .text(currentVisitID.uuidString)
                ]
            )
            changedURLIDs = [current.urlID, newURLID]
            needsRegrouping = true
        default:
            let groupID = try provisionalHostnameGroup(for: canonicalURL.hostname, sessionID: event.browsingSessionID, branchID: branchID, visitedAt: event.visitedAt)
            let sequence = try nextHistoryVisitSequence()
            try database.execute(
                "INSERT INTO history_visits (id, sequence, history_url_id, browsing_session_id, branch_id, hostname_group_id, visited_at, navigation_kind, visit_source, was_typed, typed_at, title_at_visit, favicon_reference_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                values: [
                    .text(event.id.uuidString), .integer(sequence), .integer(newURLID), .text(event.browsingSessionID.uuidString), .text(branchID.rawValue), .text(groupID.uuidString), .real(event.visitedAt.timeIntervalSince1970), .text(event.navigationKind.rawValue), .text(event.source.rawValue), .integer(event.source == .typedAddress ? 1 : 0), .real(event.source == .typedAddress ? event.visitedAt.timeIntervalSince1970 : nil), .text(event.title), .text(event.faviconReferenceKey)
                ]
            )
            try database.execute(
                "UPDATE history_hostname_groups SET last_visited_at = MAX(last_visited_at, ?) WHERE id = ?",
                values: [.real(event.visitedAt.timeIntervalSince1970), .text(groupID.uuidString)]
            )
            changedURLIDs = [newURLID]
            needsRegrouping = false
        }
        if needsRegrouping { try rebuildHostnameGroups(for: branchID) }
        for urlID in changedURLIDs { try rebuildHistoryURL(urlID) }
        guard let visit = try historyVisit(id: event.navigationKind == .reload || event.navigationKind == .replaceState ? event.currentVisitID ?? event.id : event.id) else {
            throw KeelStoreError.corruptData
        }
        return visit
    }

    public func updateHistoryTitle(visitID: UUID, title: String?) throws {
        try database.transaction {
            guard let visit = try historyVisitRow(id: visitID) else { throw HistoryStoreError.missingCurrentVisit }
            try database.execute("UPDATE history_visits SET title_at_visit = ? WHERE id = ?", values: [.text(title), .text(visitID.uuidString)])
            try rebuildHistoryURL(visit.urlID)
        }
    }

    public func historyVisits(in sessionID: UUID) throws -> [HistoryVisit] {
        try database.rows(Self.historyVisitSelect + " WHERE v.browsing_session_id = ? ORDER BY v.visited_at ASC, v.sequence ASC", values: [.text(sessionID.uuidString)]).map(Self.historyVisit)
    }

    /// Loads a whole page of sessions in one query. History used to ask for one
    /// session at a time, which cost an actor hop per row on screen.
    public func historyVisits(inSessions sessionIDs: [UUID]) throws -> [UUID: [HistoryVisit]] {
        guard !sessionIDs.isEmpty else { return [:] }
        guard sessionIDs.count <= Self.historySessionPageLimit else { throw HistoryStoreError.tooManySessions }
        let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ", ")
        let rows = try database.rows(
            Self.historyVisitSelect + " WHERE v.browsing_session_id IN (\(placeholders)) ORDER BY v.visited_at ASC, v.sequence ASC",
            values: sessionIDs.map { .text($0.uuidString) }
        )
        var grouped: [UUID: [HistoryVisit]] = [:]
        for row in rows {
            let visit = try Self.historyVisit(row)
            grouped[visit.browsingSessionID, default: []].append(visit)
        }
        return grouped
    }

    public func historyHostnameGroups(in sessionID: UUID) throws -> [HistoryHostnameGroup] {
        try database.rows(
            "SELECT id, browsing_session_id, branch_id, hostname, first_visited_at, last_visited_at FROM history_hostname_groups WHERE browsing_session_id = ? ORDER BY branch_id ASC, ordinal ASC",
            values: [.text(sessionID.uuidString)]
        ).map(Self.hostnameGroup)
    }

    /// History lists finished sessions only. The active session stays owned by
    /// Keel's runtime state.
    ///
    /// Sessions come back newest first. Pass the previous page's `nextCursor` to
    /// continue; a nil cursor on the way back means there is nothing older.
    public func endedHistorySessionPage(limit: Int = 25, before cursor: HistorySessionCursor? = nil) throws -> HistorySessionPage {
        guard (1 ... Self.historySessionPageLimit).contains(limit) else { throw HistoryStoreError.invalidSessionPageLimit }
        var sql = Self.historySessionSummarySelect + Self.historySessionSummaryGroupBy
        var values: [SQLiteValue] = []
        if let cursor {
            // Keyset paging on the same ordering key, so a session recorded
            // between two page loads cannot push a row past the reader.
            sql += " HAVING MAX(v.visited_at) < ? OR (MAX(v.visited_at) = ? AND s.id < ?)"
            let boundary = cursor.lastVisitedAt.timeIntervalSince1970
            values += [.real(boundary), .real(boundary), .text(cursor.sessionID.uuidString)]
        }
        sql += " ORDER BY MAX(v.visited_at) DESC, s.id DESC LIMIT ?"
        values.append(.integer(Int64(limit + 1)))

        var summaries = try database.rows(sql, values: values).map(Self.historySessionSummary)
        let hasMore = summaries.count > limit
        if hasMore { summaries.removeLast(summaries.count - limit) }
        let nextCursor = hasMore ? summaries.last.map { HistorySessionCursor(lastVisitedAt: $0.lastVisitedAt, sessionID: $0.id) } : nil
        return HistorySessionPage(sessions: summaries, nextCursor: nextCursor)
    }

    /// The newest page only. Callers that need the rest page through
    /// `endedHistorySessionPage(limit:before:)`.
    public func endedHistorySessions() throws -> [HistorySessionSummary] {
        try endedHistorySessionPage(limit: Self.historySessionPageLimit).sessions
    }

    /// Searches every recorded visit, not only the pages History has loaded.
    /// Matching runs on the folded hostname, path and title the Store already
    /// keeps, so a query finds a visit from a year ago.
    public func searchHistoryVisits(matching query: String, limit: Int = 200) throws -> HistorySearchResult {
        guard (1 ... Self.historySearchLimit).contains(limit) else { throw HistoryStoreError.invalidSearchLimit }
        let tokens = HistoryURLCanonicalizer.inputTokens(query)
        guard !tokens.isEmpty else { return HistorySearchResult(visits: [], sessions: [], reachedLimit: false) }

        // `searchTokens` keeps letters and digits only, so no token can carry a
        // LIKE wildcard into the pattern.
        let conditions = tokens.map { _ in "(u.host_folded LIKE ? OR u.path_folded LIKE ? OR u.title_folded LIKE ?)" }.joined(separator: " AND ")
        var values = tokens.flatMap { token -> [SQLiteValue] in
            let pattern = "%\(token)%"
            return [.text(pattern), .text(pattern), .text(pattern)]
        }
        values.append(.integer(Int64(limit + 1)))
        var visits = try database.rows(
            Self.historyVisitSelect + " WHERE \(conditions) ORDER BY v.visited_at DESC, v.sequence DESC LIMIT ?",
            values: values
        ).map(Self.historyVisit)

        let reachedLimit = visits.count > limit
        if reachedLimit { visits.removeLast(visits.count - limit) }

        var sessionOrder: [UUID] = []
        var seenSessions: Set<UUID> = []
        for visit in visits where seenSessions.insert(visit.browsingSessionID).inserted {
            sessionOrder.append(visit.browsingSessionID)
        }
        return HistorySearchResult(visits: visits, sessions: try historySessionSummaries(ids: sessionOrder), reachedLimit: reachedLimit)
    }

    /// Summaries for a known set of sessions. Sessions still running have no
    /// summary, so the result can be shorter than the input.
    public func historySessionSummaries(ids: [UUID]) throws -> [HistorySessionSummary] {
        guard !ids.isEmpty else { return [] }
        guard ids.count <= Self.historySearchLimit else { throw HistoryStoreError.tooManySessions }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        return try database.rows(
            Self.historySessionSummarySelect + " AND s.id IN (\(placeholders))" + Self.historySessionSummaryGroupBy,
            values: ids.map { .text($0.uuidString) }
        ).map(Self.historySessionSummary)
    }

    /// Records a selected local result without exposing or retaining the raw
    /// input outside the Store actor.
    public func recordAddressChoice(input: String, historyURLID: Int64) throws {
        try database.transaction {
            try recordAddressChoice(input: input, historyURLID: historyURLID, at: now())
        }
    }

    /// Compatibility helper for existing callers that only hold a URL. New
    /// palette code should use the stable History URL identifier instead.
    public func recordAddressChoice(input: String, chosenURL: URL, at date: Date) throws {
        let canonicalURL = try HistoryURLCanonicalizer.canonicalize(chosenURL)
        try database.transaction {
            guard let urlID = try database.scalarInteger("SELECT id FROM history_urls WHERE canonical_url = ?", values: [.text(canonicalURL.canonicalURL)]) else {
                throw HistoryStoreError.missingHistoryURL
            }
            try recordAddressChoice(input: input, historyURLID: urlID, at: date)
        }
    }

    /// Resolves the canonical destination for a palette row. Coordinators use
    /// this instead of trusting a URL that crossed an asynchronous UI boundary.
    public func historyURL(forID historyURLID: Int64) throws -> URL? {
        guard let storedURL = try database.scalarText("SELECT display_url FROM history_urls WHERE id = ?", values: [.integer(historyURLID)]) else {
            return nil
        }
        guard let url = URL(string: storedURL) else { throw KeelStoreError.corruptData }
        return url
    }

    /// The page title Keel last recorded for an address, if it ever loaded it.
    /// Home and the queue use this so a row can be named by its page rather
    /// than by a hostname and a raw URL.
    public func recordedTitle(for url: URL) throws -> String? {
        guard let canonical = canonicalHistoryURL(for: url.absoluteString) else { return nil }
        return try database.scalarText(
            "SELECT title FROM history_urls WHERE canonical_url = ?",
            values: [.text(canonical.canonicalURL)]
        )
    }

    /// Titles for a whole set of addresses in one query. Queue, Undo and Resume
    /// name every row at once instead of one actor hop per address. Addresses
    /// with no recorded title are absent from the result.
    public func recordedTitles(for urls: [URL]) throws -> [URL: String] {
        guard !urls.isEmpty else { return [:] }
        var canonicalToURL: [String: URL] = [:]
        for url in urls {
            guard let canonical = canonicalHistoryURL(for: url.absoluteString) else { continue }
            canonicalToURL[canonical.canonicalURL] = url
        }
        guard !canonicalToURL.isEmpty else { return [:] }

        var titles: [URL: String] = [:]
        let keys = Array(canonicalToURL.keys)
        for chunk in stride(from: 0, to: keys.count, by: Self.recordedTitleChunkSize).map({ Array(keys[$0 ..< min($0 + Self.recordedTitleChunkSize, keys.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows = try database.rows(
                "SELECT canonical_url, title FROM history_urls WHERE canonical_url IN (\(placeholders)) AND title IS NOT NULL AND title <> ''",
                values: chunk.map { .text($0) }
            )
            for row in rows {
                guard let canonical = row.text(0), let title = row.text(1), let url = canonicalToURL[canonical] else { continue }
                titles[url] = title
            }
        }
        return titles
    }

    /// Returns at most six deterministic, local History results. Match quality
    /// always wins over past choice, typed count, visit count, and recency.
    public func addressSuggestions(for input: String, limit: Int = 6) throws -> HistorySuggestionResult {
        guard (1 ... Self.addressSuggestionLimit).contains(limit) else { throw HistoryStoreError.invalidSuggestionLimit }
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInput = HistoryURLCanonicalizer.fold(trimmedInput)
        guard !normalizedInput.isEmpty else { return HistorySuggestionResult(suggestions: []) }

        let tokens = HistoryURLCanonicalizer.inputTokens(normalizedInput)
        guard !tokens.isEmpty else { return HistorySuggestionResult(suggestions: []) }

        var candidatesByID: [Int64: HistoryCandidate] = [:]

        let canonicalInput = canonicalHistoryURL(for: trimmedInput)
        let canonicalFoldedInput = canonicalInput.map { HistoryURLCanonicalizer.fold($0.canonicalURL) }
        if let canonicalInput {
            let exactRows = try database.rows(
                Self.candidateSelect + " WHERE h.canonical_url = ?",
                values: [.text(normalizedInput), .text(normalizedInput), .text(canonicalInput.canonicalURL)]
            )
            insertCandidates(try exactRows.map(Self.historyCandidate), into: &candidatesByID)
        }

        let exactHostnameRows = try database.rows(
            Self.candidateSelect + " WHERE h.host_folded = ? LIMIT ?",
            values: [.text(normalizedInput), .text(normalizedInput), .text(normalizedInput), .integer(Int64(Self.suggestionCandidateHeadLimit))]
        )
        insertCandidates(try exactHostnameRows.map(Self.historyCandidate), into: &candidatesByID)

        let hostnamePrefixRows = try database.rows(
            Self.candidateSelect + " WHERE h.host_folded >= ? AND h.host_folded < ? LIMIT ?",
            values: [.text(normalizedInput), .text(normalizedInput), .text(normalizedInput), .text(prefixUpperBound(for: normalizedInput)), .integer(Int64(Self.suggestionCandidateHeadLimit))]
        )
        insertCandidates(try hostnamePrefixRows.map(Self.historyCandidate), into: &candidatesByID)

        let tokenPrefixRows = try prefixCandidateRows(
            tokens: tokens,
            inputPrefix: normalizedInput,
            limit: Self.suggestionCandidateHeadLimit
        )
        insertCandidates(try tokenPrefixRows.map(Self.historyCandidate), into: &candidatesByID)

        let queryDate = now()
        var results = suggestionResults(
            from: candidatesByID.values,
            normalizedInput: normalizedInput,
            canonicalFoldedInput: canonicalFoldedInput,
            tokens: tokens,
            at: queryDate
        )

        if results.count < limit {
            let substringRows = try database.rows(
                Self.candidateSelect + " ORDER BY h.last_visited_at DESC LIMIT ?",
                values: [.text(normalizedInput), .text(normalizedInput), .integer(Int64(Self.substringCandidateHeadLimit))]
            )
            for candidate in try substringRows.map(Self.historyCandidate) {
                guard candidatesByID[candidate.id] == nil,
                      let match = suggestionMatch(for: candidate, normalizedInput: normalizedInput, canonicalFoldedInput: canonicalFoldedInput, tokens: tokens),
                      match.quality == .contiguousSubstring,
                      isEligibleSuggestion(candidate: candidate, match: match)
                else { continue }
                results.append(suggestionResult(candidate: candidate, match: match, at: queryDate))
            }
        }

        results.sort { Self.ranksBefore($0, $1) }
        let visibleSuggestions = Array(results.prefix(limit))
        let defaultSuggestionID = defaultSuggestionID(for: visibleSuggestions, input: normalizedInput)
        return HistorySuggestionResult(suggestions: visibleSuggestions, defaultSuggestionID: defaultSuggestionID)
    }

    /// Returns a filtered, bounded local set. The address palette owns ranking and visible-row deduplication.
    public func historyCandidates(matching input: String, limit: Int = 20) throws -> [HistoryCandidate] {
        guard (1 ... Self.historyCandidateLimit).contains(limit) else { throw HistoryStoreError.invalidCandidateLimit }
        let tokens = HistoryURLCanonicalizer.inputTokens(input)
        guard !tokens.isEmpty else { return [] }
        let inputPrefix = HistoryURLCanonicalizer.fold(input).trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixRows = try prefixCandidateRows(tokens: tokens, inputPrefix: inputPrefix, limit: limit)
        var candidates = try prefixRows.map(Self.historyCandidate).filter { $0.url.query == nil }
        guard candidates.count < limit else { return candidates }

        let existing = Set(candidates.map(\.id))
        let headRows = try database.rows(
            Self.candidateSelect + " ORDER BY h.last_visited_at DESC, h.visit_count DESC LIMIT ?",
            values: [.text(inputPrefix), .text(inputPrefix), .integer(Int64(Self.substringCandidateHeadLimit))]
        )
        for candidate in try headRows.map(Self.historyCandidate) where candidates.count < limit {
            guard candidate.url.query == nil,
                  !existing.contains(candidate.id),
                  candidateMatchesSubstring(candidate, tokens: tokens)
            else { continue }
            candidates.append(candidate)
        }
        return candidates
    }

    public func deleteHistory(_ scope: HistoryDeletionScope) throws {
        try database.transaction {
            let visitIDs = try historyVisitIDs(for: scope)
            guard !visitIDs.isEmpty else { return }
            let affectedURLIDs = try historyURLIDs(for: visitIDs)
            let affectedBranchIDs = try historyBranchIDs(for: visitIDs)
            try deleteAddressChoices(for: affectedURLIDs)
            for (index, id) in visitIDs.enumerated() {
                try database.execute("DELETE FROM history_visits WHERE id = ?", values: [.text(id.uuidString)])
                try faultInjector(index)
            }
            for branchID in affectedBranchIDs { try rebuildHostnameGroups(for: branchID) }
            try database.execute("DELETE FROM history_branches WHERE NOT EXISTS (SELECT 1 FROM history_visits WHERE history_visits.branch_id = history_branches.id)")
            for urlID in affectedURLIDs { try rebuildHistoryURL(urlID) }
        }
    }

    static let historyCandidateLimit = 100
    static let addressSuggestionLimit = 6
    static let historySessionPageLimit = 200
    static let historySearchLimit = 500
    private static let recordedTitleChunkSize = 400
    private static let suggestionCandidateHeadLimit = 500
    private static let substringCandidateHeadLimit = 500

    func recordAddressChoice(input: String, historyURLID: Int64, at date: Date) throws {
        let foldedInput = HistoryURLCanonicalizer.fold(input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !foldedInput.isEmpty else { return }
        guard let storedCanonicalURL = try database.scalarText("SELECT canonical_url FROM history_urls WHERE id = ?", values: [.integer(historyURLID)]) else {
            throw HistoryStoreError.missingHistoryURL
        }
        if let storedURL = URL(string: storedCanonicalURL), storedURL.query != nil {
            guard let inputURL = canonicalHistoryURL(for: input), inputURL.canonicalURL == storedCanonicalURL else {
                throw HistoryStoreError.invalidAddressChoiceInput
            }
        }
        try database.execute(
            "INSERT INTO address_choice_history (input_prefix_folded, history_url_id, use_count, last_used_at) VALUES (?, ?, 1, ?) ON CONFLICT(input_prefix_folded, history_url_id) DO UPDATE SET use_count = use_count + 1, last_used_at = excluded.last_used_at",
            values: [.text(foldedInput), .integer(historyURLID), .real(date.timeIntervalSince1970)]
        )
    }

    private func ensureBrowsingSessionExists(_ sessionID: UUID) throws {
        guard try database.scalarText("SELECT id FROM browsing_sessions WHERE id = ?", values: [.text(sessionID.uuidString)]) != nil else {
            throw HistoryStoreError.missingBrowsingSession
        }
    }

    private func ensureHistoryBranch(_ branchID: HistoryBranchID, sessionID: UUID, branch: HistoryBranch, createdAt: Date) throws {
        try database.execute(
            "INSERT INTO history_branches (id, browsing_session_id, kind, created_at) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO NOTHING",
            values: [.text(branchID.rawValue), .text(sessionID.uuidString), .text(branch.storedKind), .real(createdAt.timeIntervalSince1970)]
        )
    }

    private func historyURLID(for url: CanonicalHistoryURL, at date: Date) throws -> Int64 {
        try database.execute(
            "INSERT INTO history_urls (canonical_url, display_url, origin, hostname, host_folded, path_folded, title_folded, visit_count, typed_count, last_visited_at) VALUES (?, ?, ?, ?, ?, ?, '', 0, 0, ?) ON CONFLICT(canonical_url) DO UPDATE SET display_url = excluded.display_url",
            values: [.text(url.canonicalURL), .text(url.displayURL), .text(url.origin), .text(url.hostname), .text(url.hostnameFolded), .text(url.pathFolded), .real(date.timeIntervalSince1970)]
        )
        guard let identifier = try database.scalarInteger("SELECT id FROM history_urls WHERE canonical_url = ?", values: [.text(url.canonicalURL)]) else {
            throw KeelStoreError.corruptData
        }
        return identifier
    }

    private func nextHistoryVisitSequence() throws -> Int64 {
        guard let sequence = try database.scalarInteger("SELECT next_sequence FROM history_visit_sequence WHERE singleton = 1") else {
            throw KeelStoreError.corruptData
        }
        try database.execute("UPDATE history_visit_sequence SET next_sequence = ? WHERE singleton = 1", values: [.integer(sequence + 1)])
        return sequence
    }

    private func provisionalHostnameGroup(for hostname: String, sessionID: UUID, branchID: HistoryBranchID, visitedAt: Date) throws -> UUID {
        if let existing = try database.rows(
            "SELECT id, hostname FROM history_hostname_groups WHERE branch_id = ? ORDER BY ordinal DESC LIMIT 1",
            values: [.text(branchID.rawValue)]
        ).first, existing.text(1) == hostname, let id = existing.text(0).flatMap(UUID.init(uuidString:)) {
            return id
        }
        let nextOrdinal = (try database.scalarInteger("SELECT COALESCE(MAX(ordinal), -1) + 1 FROM history_hostname_groups WHERE branch_id = ?", values: [.text(branchID.rawValue)])) ?? 0
        let id = UUID()
        try database.execute(
            "INSERT INTO history_hostname_groups (id, browsing_session_id, branch_id, hostname, ordinal, first_visited_at, last_visited_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            values: [.text(id.uuidString), .text(sessionID.uuidString), .text(branchID.rawValue), .text(hostname), .integer(nextOrdinal), .real(visitedAt.timeIntervalSince1970), .real(visitedAt.timeIntervalSince1970)]
        )
        return id
    }

    /// Rebuild only this branch. A detour branch cannot alter the root branch's consecutive-hostname groups.
    private func rebuildHostnameGroups(for branchID: HistoryBranchID) throws {
        let visits = try database.rows(
            "SELECT v.id, v.browsing_session_id, v.visited_at, h.hostname FROM history_visits v JOIN history_urls h ON h.id = v.history_url_id WHERE v.branch_id = ? ORDER BY v.visited_at ASC, v.sequence ASC",
            values: [.text(branchID.rawValue)]
        )
        let existingGroups = try database.rows(
            "SELECT id, ordinal FROM history_hostname_groups WHERE branch_id = ?",
            values: [.text(branchID.rawValue)]
        ).reduce(into: [Int64: String]()) { groups, row in
            if let id = row.text(0), let ordinal = row.integer(1) { groups[ordinal] = id }
        }
        var currentHostname: String?
        var currentGroupID: String?
        var ordinal: Int64 = 0
        var usedGroupIDs: Set<String> = []
        for row in visits {
            guard let visitID = row.text(0), let sessionID = row.text(1), let visitedAt = row.real(2), let hostname = row.text(3) else { throw KeelStoreError.corruptData }
            if hostname != currentHostname {
                currentHostname = hostname
                currentGroupID = existingGroups[ordinal] ?? UUID().uuidString
                usedGroupIDs.insert(currentGroupID!)
                if existingGroups[ordinal] == nil {
                    try database.execute(
                        "INSERT INTO history_hostname_groups (id, browsing_session_id, branch_id, hostname, ordinal, first_visited_at, last_visited_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        values: [.text(currentGroupID), .text(sessionID), .text(branchID.rawValue), .text(hostname), .integer(ordinal), .real(visitedAt), .real(visitedAt)]
                    )
                } else {
                    try database.execute(
                        "UPDATE history_hostname_groups SET browsing_session_id = ?, hostname = ?, first_visited_at = ?, last_visited_at = ? WHERE id = ?",
                        values: [.text(sessionID), .text(hostname), .real(visitedAt), .real(visitedAt), .text(currentGroupID)]
                    )
                }
                ordinal += 1
            } else if let currentGroupID {
                try database.execute("UPDATE history_hostname_groups SET last_visited_at = ? WHERE id = ?", values: [.real(visitedAt), .text(currentGroupID)])
            }
            guard let currentGroupID else { throw KeelStoreError.corruptData }
            try database.execute("UPDATE history_visits SET hostname_group_id = ? WHERE id = ?", values: [.text(currentGroupID), .text(visitID)])
        }
        let oldGroupRows = try database.rows("SELECT id FROM history_hostname_groups WHERE branch_id = ?", values: [.text(branchID.rawValue)])
        for row in oldGroupRows {
            guard let id = row.text(0), !usedGroupIDs.contains(id) else { continue }
            try database.execute("DELETE FROM history_hostname_groups WHERE id = ?", values: [.text(id)])
        }
    }

    private func rebuildHistoryURL(_ urlID: Int64) throws {
        guard let aggregate = try database.rows("SELECT canonical_url, display_url, origin, hostname, host_folded, path_folded FROM history_urls WHERE id = ?", values: [.integer(urlID)]).first else { return }
        guard let visitCount = try database.scalarInteger("SELECT COUNT(*) FROM history_visits WHERE history_url_id = ?", values: [.integer(urlID)]), visitCount > 0 else {
            try database.execute("DELETE FROM history_urls WHERE id = ?", values: [.integer(urlID)])
            return
        }
        let typedCount = try database.scalarInteger("SELECT COUNT(*) FROM history_visits WHERE history_url_id = ? AND was_typed = 1", values: [.integer(urlID)]) ?? 0
        guard let lastVisitedAt = try database.scalarReal("SELECT MAX(visited_at) FROM history_visits WHERE history_url_id = ?", values: [.integer(urlID)]) else { throw KeelStoreError.corruptData }
        let lastTypedAt = try database.scalarReal("SELECT MAX(typed_at) FROM history_visits WHERE history_url_id = ?", values: [.integer(urlID)])
        let title = try database.rows(
            "SELECT title_at_visit FROM history_visits WHERE history_url_id = ? AND title_at_visit IS NOT NULL ORDER BY visited_at DESC, sequence DESC LIMIT 1",
            values: [.integer(urlID)]
        ).first?.text(0)
        let faviconReferenceKey = try database.rows(
            "SELECT favicon_reference_key FROM history_visits WHERE history_url_id = ? AND favicon_reference_key IS NOT NULL ORDER BY visited_at DESC, sequence DESC LIMIT 1",
            values: [.integer(urlID)]
        ).first?.text(0)
        try database.execute(
            "UPDATE history_urls SET title_folded = ?, title = ?, favicon_reference_key = ?, visit_count = ?, typed_count = ?, last_visited_at = ?, last_typed_at = ? WHERE id = ?",
            values: [.text(HistoryURLCanonicalizer.fold(title ?? "")), .text(title), .text(faviconReferenceKey), .integer(visitCount), .integer(typedCount), .real(lastVisitedAt), .real(lastTypedAt), .integer(urlID)]
        )
        try database.execute("DELETE FROM history_url_terms WHERE history_url_id = ?", values: [.integer(urlID)])
        let tokens = Set(
            HistoryURLCanonicalizer.searchTokens(aggregate.text(4))
                + HistoryURLCanonicalizer.searchTokens(aggregate.text(5))
                + HistoryURLCanonicalizer.searchTokens(title)
        )
        for token in tokens {
            try database.execute("INSERT INTO history_url_terms (history_url_id, token) VALUES (?, ?)", values: [.integer(urlID), .text(token)])
        }
    }

    private func prefixCandidateRows(tokens: [String], inputPrefix: String, limit: Int) throws -> [SQLiteRow] {
        let branches = tokens.enumerated().map { index, _ in
            "SELECT history_url_id, \(index) AS input_index FROM history_url_terms WHERE token >= ? AND token < ?"
        }
        let sql = """
            WITH term_matches AS (
                \(branches.joined(separator: " UNION ALL "))
            ), matching_url_ids AS (
                SELECT history_url_id FROM term_matches GROUP BY history_url_id HAVING COUNT(DISTINCT input_index) = ?
            )
            \(Self.candidateSelect) JOIN matching_url_ids m ON m.history_url_id = h.id
            ORDER BY h.last_visited_at DESC, h.visit_count DESC LIMIT ?
            """
        let values = tokens.flatMap { token in
            [SQLiteValue.text(token), SQLiteValue.text(prefixUpperBound(for: token))]
        } + [.integer(Int64(tokens.count)), .text(inputPrefix), .text(inputPrefix), .integer(Int64(limit))]
        return try database.rows(sql, values: values)
    }

    private func prefixUpperBound(for prefix: String) -> String {
        prefix + "\u{10FFFF}"
    }

    private func candidateMatchesSubstring(_ candidate: HistoryCandidate, tokens: [String]) -> Bool {
        let values = [HistoryURLCanonicalizer.fold(candidate.hostname), HistoryURLCanonicalizer.fold(candidate.url.path), HistoryURLCanonicalizer.fold(candidate.title ?? "")]
        return tokens.allSatisfy { token in values.contains { $0.contains(token) } }
    }

    private func insertCandidates(_ candidates: [HistoryCandidate], into destination: inout [Int64: HistoryCandidate]) {
        for candidate in candidates where destination[candidate.id] == nil {
            destination[candidate.id] = candidate
        }
    }

    private func canonicalHistoryURL(for input: String) -> CanonicalHistoryURL? {
        guard let url = URL(string: input) else { return nil }
        return try? HistoryURLCanonicalizer.canonicalize(url)
    }

    private func suggestionResults(
        from candidates: Dictionary<Int64, HistoryCandidate>.Values,
        normalizedInput: String,
        canonicalFoldedInput: String?,
        tokens: [String],
        at date: Date
    ) -> [HistorySuggestion] {
        candidates.compactMap { candidate in
            guard let match = suggestionMatch(for: candidate, normalizedInput: normalizedInput, canonicalFoldedInput: canonicalFoldedInput, tokens: tokens) else { return nil }
            guard isEligibleSuggestion(candidate: candidate, match: match) else { return nil }
            return suggestionResult(candidate: candidate, match: match, at: date)
        }
    }

    private func isEligibleSuggestion(candidate: HistoryCandidate, match: HistorySuggestionMatch) -> Bool {
        candidate.url.query == nil || match.field == .canonicalURL
    }

    private func suggestionMatch(
        for candidate: HistoryCandidate,
        normalizedInput: String,
        canonicalFoldedInput: String?,
        tokens: [String]
    ) -> HistorySuggestionMatch? {
        let hostname = HistoryURLCanonicalizer.fold(candidate.hostname)
        let canonicalURL = HistoryURLCanonicalizer.fold(candidate.url.absoluteString)

        if canonicalURL == canonicalFoldedInput {
            return HistorySuggestionMatch(quality: .exactURLOrHostname, field: .canonicalURL)
        }
        if hostname == normalizedInput {
            return HistorySuggestionMatch(quality: .exactURLOrHostname, field: .hostname)
        }
        if !normalizedInput.contains(where: { $0.isWhitespace }), hostname.hasPrefix(normalizedInput) {
            return HistorySuggestionMatch(quality: .hostnamePrefix, field: .hostname)
        }
        if let field = tokenBoundaryMatchField(for: candidate, tokens: tokens) {
            return HistorySuggestionMatch(quality: .tokenBoundaryPrefix, field: field)
        }
        if let field = contiguousSubstringMatchField(for: candidate, tokens: tokens) {
            return HistorySuggestionMatch(quality: .contiguousSubstring, field: field)
        }
        return nil
    }

    private func tokenBoundaryMatchField(for candidate: HistoryCandidate, tokens: [String]) -> HistorySuggestionMatchField? {
        let fields = suggestionSearchFields(for: candidate)
        for (field, values) in fields where tokens.allSatisfy({ token in values.contains(where: { $0.hasPrefix(token) }) }) {
            return field
        }
        guard tokens.allSatisfy({ token in fields.contains(where: { field in field.1.contains(where: { $0.hasPrefix(token) }) }) }) else {
            return nil
        }
        return .mixed
    }

    private func contiguousSubstringMatchField(for candidate: HistoryCandidate, tokens: [String]) -> HistorySuggestionMatchField? {
        let fields = suggestionSearchFields(for: candidate)
        for (field, values) in fields where tokens.allSatisfy({ token in values.contains(where: { $0.contains(token) }) }) {
            return field
        }
        guard tokens.allSatisfy({ token in fields.contains(where: { field in field.1.contains(where: { $0.contains(token) }) }) }) else {
            return nil
        }
        return .mixed
    }

    private func suggestionSearchFields(for candidate: HistoryCandidate) -> [(HistorySuggestionMatchField, [String])] {
        [
            (.hostname, HistoryURLCanonicalizer.searchTokens(candidate.hostname)),
            (.path, HistoryURLCanonicalizer.searchTokens(candidate.url.path)),
            (.title, HistoryURLCanonicalizer.searchTokens(candidate.title)),
        ]
    }

    private func suggestionResult(candidate: HistoryCandidate, match: HistorySuggestionMatch, at date: Date) -> HistorySuggestion {
        return HistorySuggestion(
            historyURLID: candidate.id,
            url: candidate.url,
            displayURL: candidate.displayURL,
            hostname: candidate.hostname,
            title: candidate.title,
            faviconReferenceKey: candidate.faviconReferenceKey,
            match: match,
            visitCount: candidate.visitCount,
            typedCount: candidate.typedCount,
            lastVisitedAt: candidate.lastVisitedAt,
            lastTypedAt: candidate.lastTypedAt,
            addressChoiceCount: candidate.addressChoiceCount,
            lastAddressChoiceAt: candidate.lastAddressChoiceAt,
            score: historyScore(for: candidate, at: date)
        )
    }

    private static func ranksBefore(_ lhs: HistorySuggestion, _ rhs: HistorySuggestion) -> Bool {
        if lhs.match.quality != rhs.match.quality { return lhs.match.quality > rhs.match.quality }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.historyURLID < rhs.historyURLID
    }

    private func historyScore(for candidate: HistoryCandidate, at date: Date) -> Double {
        let adaptiveScore: Double
        if candidate.addressChoiceCount > 0, let lastChoice = candidate.lastAddressChoiceAt {
            let ageInDays = max(0, date.timeIntervalSince(lastChoice) / 86_400)
            adaptiveScore = 130 * Foundation.log1p(Double(candidate.addressChoiceCount)) * Foundation.exp(-ageInDays / 90)
        } else {
            adaptiveScore = 0
        }
        let typedScore = 35 * Foundation.log1p(Double(candidate.typedCount))
        let visitScore = 12 * Foundation.log1p(Double(candidate.visitCount))
        let ageInDays = max(0, date.timeIntervalSince(candidate.lastVisitedAt) / 86_400)
        let recencyScore = 45 * Foundation.pow(2, -ageInDays / 14)
        return adaptiveScore + typedScore + visitScore + recencyScore
    }

    private func defaultSuggestionID(for suggestions: [HistorySuggestion], input: String) -> Int64? {
        guard !input.contains(where: { $0.isWhitespace }), let first = suggestions.first else { return nil }
        switch first.match.quality {
        case .exactURLOrHostname, .hostnamePrefix:
            return first.historyURLID
        case .tokenBoundaryPrefix, .contiguousSubstring:
            return nil
        }
    }

    private func deleteAddressChoices(for urlIDs: Set<Int64>) throws {
        for urlID in urlIDs {
            try database.execute("DELETE FROM address_choice_history WHERE history_url_id = ?", values: [.integer(urlID)])
        }
    }

    private func historyVisitIDs(for scope: HistoryDeletionScope) throws -> [UUID] {
        switch scope {
        case let .visits(ids):
            var existingIDs: [UUID] = []
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) where try historyVisitRow(id: id) != nil {
                existingIDs.append(id)
            }
            return existingIDs
        case let .hostnameGroup(sessionID, branchID, groupID):
            return try database.rows(
                "SELECT id FROM history_visits WHERE browsing_session_id = ? AND branch_id = ? AND hostname_group_id = ?",
                values: [.text(sessionID.uuidString), .text(branchID.rawValue), .text(groupID.uuidString)]
            ).compactMap { $0.text(0).flatMap(UUID.init(uuidString:)) }
        case let .session(sessionID):
            return try database.rows("SELECT id FROM history_visits WHERE browsing_session_id = ?", values: [.text(sessionID.uuidString)]).compactMap { $0.text(0).flatMap(UUID.init(uuidString:)) }
        case .all:
            return try database.rows("SELECT id FROM history_visits").compactMap { $0.text(0).flatMap(UUID.init(uuidString:)) }
        }
    }

    private func historyURLIDs(for visitIDs: [UUID]) throws -> Set<Int64> {
        var identifiers: Set<Int64> = []
        for visitID in visitIDs {
            if let id = try database.scalarInteger("SELECT history_url_id FROM history_visits WHERE id = ?", values: [.text(visitID.uuidString)]) { identifiers.insert(id) }
        }
        return identifiers
    }

    private func historyBranchIDs(for visitIDs: [UUID]) throws -> Set<HistoryBranchID> {
        var identifiers: Set<HistoryBranchID> = []
        for visitID in visitIDs {
            if let branchID = try database.scalarText("SELECT branch_id FROM history_visits WHERE id = ?", values: [.text(visitID.uuidString)]) {
                identifiers.insert(HistoryBranchID(rawValue: branchID))
            }
        }
        return identifiers
    }

    private func historyVisitRow(id: UUID) throws -> (urlID: Int64, sessionID: UUID, branchID: HistoryBranchID)? {
        guard let row = try database.rows("SELECT history_url_id, browsing_session_id, branch_id FROM history_visits WHERE id = ?", values: [.text(id.uuidString)]).first,
              let urlID = row.integer(0), let sessionID = row.text(1).flatMap(UUID.init(uuidString:)), let branchID = row.text(2)
        else { return nil }
        return (urlID, sessionID, HistoryBranchID(rawValue: branchID))
    }

    private func historyVisit(id: UUID) throws -> HistoryVisit? {
        try database.rows(Self.historyVisitSelect + " WHERE v.id = ?", values: [.text(id.uuidString)]).first.map(Self.historyVisit)
    }

    private static let historyVisitSelect = """
        SELECT v.id, u.display_url, v.title_at_visit, v.visited_at, v.browsing_session_id, v.branch_id, v.navigation_kind, v.visit_source, v.hostname_group_id
        FROM history_visits v JOIN history_urls u ON u.id = v.history_url_id
        """

    private static let candidateSelect = """
        SELECT h.id, h.display_url, h.hostname, h.title, h.favicon_reference_key, h.visit_count, h.typed_count, h.last_visited_at, h.last_typed_at,
               COALESCE((SELECT SUM(a.use_count) FROM address_choice_history a WHERE a.history_url_id = h.id AND a.input_prefix_folded = ?), 0),
               (SELECT MAX(a.last_used_at) FROM address_choice_history a WHERE a.history_url_id = h.id AND a.input_prefix_folded = ?)
        FROM history_urls h
        """

    private static let historySessionSummarySelect = """
        SELECT
            s.id, s.started_at, s.ended_at,
            MIN(v.visited_at), MAX(v.visited_at), COUNT(v.id),
            latest.hostname, COALESCE(latest.title_at_visit, latest.title), latest.display_url, latest.favicon_reference_key
        FROM browsing_sessions s
        JOIN history_visits v ON v.browsing_session_id = s.id
        JOIN (
            SELECT recent.browsing_session_id, recent.hostname, recent.title_at_visit, recent.title, recent.display_url, recent.favicon_reference_key
            FROM (
                SELECT v.browsing_session_id, u.hostname, v.title_at_visit, u.title, u.display_url, u.favicon_reference_key,
                       ROW_NUMBER() OVER (PARTITION BY v.browsing_session_id ORDER BY v.visited_at DESC, v.sequence DESC) AS row_number
                FROM history_visits v JOIN history_urls u ON u.id = v.history_url_id
            ) recent WHERE recent.row_number = 1
        ) latest ON latest.browsing_session_id = s.id
        WHERE s.ended_at IS NOT NULL
        """

    /// Kept apart from the select so a caller can insert its own predicate
    /// before grouping.
    private static let historySessionSummaryGroupBy = " GROUP BY s.id, s.started_at, s.ended_at, latest.hostname, latest.title_at_visit, latest.title, latest.display_url, latest.favicon_reference_key"

    private static func historyVisit(_ row: SQLiteRow) throws -> HistoryVisit {
        guard let id = row.text(0).flatMap(UUID.init(uuidString:)), let urlText = row.text(1), let url = URL(string: urlText), let visitedAt = row.real(3), let sessionID = row.text(4).flatMap(UUID.init(uuidString:)), let branchID = row.text(5), let kindText = row.text(6), let kind = HistoryNavigationKind(rawValue: kindText), let sourceText = row.text(7), let source = HistoryVisitSource(rawValue: sourceText), let groupID = row.text(8).flatMap(UUID.init(uuidString:)) else { throw KeelStoreError.corruptData }
        return HistoryVisit(id: id, url: url, title: row.text(2), visitedAt: Date(timeIntervalSince1970: visitedAt), browsingSessionID: sessionID, branchID: HistoryBranchID(rawValue: branchID), navigationKind: kind, source: source, hostnameGroupID: groupID)
    }

    private static func hostnameGroup(_ row: SQLiteRow) throws -> HistoryHostnameGroup {
        guard let id = row.text(0).flatMap(UUID.init(uuidString:)), let sessionID = row.text(1).flatMap(UUID.init(uuidString:)), let branchID = row.text(2), let hostname = row.text(3), let first = row.real(4), let last = row.real(5) else { throw KeelStoreError.corruptData }
        return HistoryHostnameGroup(id: id, browsingSessionID: sessionID, branchID: HistoryBranchID(rawValue: branchID), hostname: hostname, firstVisitedAt: Date(timeIntervalSince1970: first), lastVisitedAt: Date(timeIntervalSince1970: last))
    }

    private static func historyCandidate(_ row: SQLiteRow) throws -> HistoryCandidate {
        guard let id = row.integer(0), let urlText = row.text(1), let url = URL(string: urlText), let hostname = row.text(2), let visitCount = row.integer(5), let typedCount = row.integer(6), let lastVisitedAt = row.real(7), let addressChoiceCount = row.integer(9) else { throw KeelStoreError.corruptData }
        return HistoryCandidate(id: id, url: url, displayURL: urlText, hostname: hostname, title: row.text(3), faviconReferenceKey: row.text(4), visitCount: Int(visitCount), typedCount: Int(typedCount), lastVisitedAt: Date(timeIntervalSince1970: lastVisitedAt), lastTypedAt: row.real(8).map(Date.init(timeIntervalSince1970:)), addressChoiceCount: Int(addressChoiceCount), lastAddressChoiceAt: row.real(10).map(Date.init(timeIntervalSince1970:)))
    }

    private static func historySessionSummary(_ row: SQLiteRow) throws -> HistorySessionSummary {
        guard let id = row.text(0).flatMap(UUID.init(uuidString:)), let startedAt = row.real(1), let endedAt = row.real(2), let firstVisitedAt = row.real(3), let lastVisitedAt = row.real(4), let visitCount = row.integer(5), let hostname = row.text(6), let displayURL = row.text(8) else { throw KeelStoreError.corruptData }
        return HistorySessionSummary(id: id, startedAt: Date(timeIntervalSince1970: startedAt), endedAt: Date(timeIntervalSince1970: endedAt), firstVisitedAt: Date(timeIntervalSince1970: firstVisitedAt), lastVisitedAt: Date(timeIntervalSince1970: lastVisitedAt), visitCount: Int(visitCount), hostname: hostname, title: row.text(7), displayURL: displayURL, faviconReferenceKey: row.text(9))
    }
}
