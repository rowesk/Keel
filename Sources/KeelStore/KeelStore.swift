import Foundation
import KeelFoundation
import SQLite3

public enum QueueRetention: Int, CaseIterable, Codable, Sendable {
    case hours24 = 86_400
    case hours72 = 259_200
    case days7 = 604_800
}

public enum SearchProvider: Codable, Equatable, Sendable {
    case google
    case duckDuckGo
    case kagi
    case custom(template: String)

    fileprivate var storedValue: String {
        switch self {
        case .google: "google"
        case .duckDuckGo: "duckduckgo"
        case .kagi: "kagi"
        case let .custom(template): "custom:\(template)"
        }
    }

    fileprivate init(storedValue: String) throws {
        switch storedValue {
        case "google": self = .google
        case "duckduckgo": self = .duckDuckGo
        case "kagi": self = .kagi
        default:
            guard storedValue.hasPrefix("custom:") else { throw KeelStoreError.corruptData }
            let template = String(storedValue.dropFirst("custom:".count))
            // Earlier releases accepted placeholders in hostnames. Keep the database
            // readable after tightening validation. This read does not rewrite the
            // original value; a later explicit settings save persists the selection.
            guard Self.isValidCustomTemplate(template) else {
                self = .google
                return
            }
            self = .custom(template: template)
        }
    }

    /// A custom provider must be a web URL with one path or query data placeholder.
    /// Replacing the placeholder before parsing avoids treating it as an invalid URL character.
    public static func isValidCustomTemplate(_ template: String) -> Bool {
        guard !template.isEmpty,
              template.utf8.count <= 2_048,
              !template.contains(where: { $0.isWhitespace }),
              template.components(separatedBy: "{query}").count == 2
        else { return false }

        let resolved = template.replacingOccurrences(of: "{query}", with: "keelqueryplaceholder")
        guard let components = URLComponents(string: resolved),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              !host.contains("keelqueryplaceholder"),
              components.user == nil,
              components.password == nil,
              components.fragment == nil
        else { return false }
        return true
    }
}

public enum AppearanceMode: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark
}

/// A fixed ladder rather than free text, so every stored zoom is one WebKit already renders well.
public enum PageZoomLevel: Int, CaseIterable, Codable, Sendable {
    case percent80 = 80
    case percent90 = 90
    case percent100 = 100
    case percent110 = 110
    case percent125 = 125
    case percent150 = 150
    case percent175 = 175
    case percent200 = 200

    public var scale: Double { Double(rawValue) / 100 }
}

/// Creates and resolves the security-scoped bookmark that lets a sandboxed Keel keep
/// writing to a directory the user picked in an earlier launch.
public enum DownloadDirectoryBookmark {
    /// A bookmark larger than this is not something Keel produced, so refuse to store it.
    public static let byteLimit = 64 * 1_024

    public static func make(for directory: URL) throws -> Data {
        let data = try directory.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        guard data.count <= byteLimit else { throw KeelStoreError.invalidSettings }
        return data
    }

    /// Resolves the bookmark and holds the security scope only for the duration of `body`.
    /// The sandbox leaks the scope if a caller forgets to stop it, so callers never see the raw pair.
    public static func withAccess<T>(_ data: Data, _ body: (URL, Bool) throws -> T) throws -> T {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body(url, isStale)
    }
}

public struct KeelSettings: Codable, Equatable, Sendable {
    public var queueRetention: QueueRetention
    public var keepsClosedPageReady: Bool
    public var searchProvider: SearchProvider
    public var diagnosticModeExpiresAt: Date?
    public var appearance: AppearanceMode
    public var defaultPageZoom: PageZoomLevel
    /// Absent means new downloads go to the system Downloads folder.
    public var downloadDirectoryBookmark: Data?
    public var homeSceneMode: HomeSceneMode
    /// Absent means the default bundled scene, `bundled:como`.
    public var selectedHomeSceneID: String?
    public var homeSceneRotation: HomeSceneRotationState

    public init(
        queueRetention: QueueRetention = .hours72,
        keepsClosedPageReady: Bool = true,
        searchProvider: SearchProvider = .google,
        diagnosticModeExpiresAt: Date? = nil,
        appearance: AppearanceMode = .system,
        defaultPageZoom: PageZoomLevel = .percent100,
        downloadDirectoryBookmark: Data? = nil,
        homeSceneMode: HomeSceneMode = .onePhoto,
        selectedHomeSceneID: String? = nil,
        homeSceneRotation: HomeSceneRotationState = HomeSceneRotationState()
    ) {
        self.queueRetention = queueRetention
        self.keepsClosedPageReady = keepsClosedPageReady
        self.searchProvider = searchProvider
        self.diagnosticModeExpiresAt = diagnosticModeExpiresAt
        self.appearance = appearance
        self.defaultPageZoom = defaultPageZoom
        self.downloadDirectoryBookmark = downloadDirectoryBookmark
        self.homeSceneMode = homeSceneMode
        self.selectedHomeSceneID = selectedHomeSceneID
        self.homeSceneRotation = homeSceneRotation
    }

    /// Decoded by hand so a record written before these preferences existed still loads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        queueRetention = try container.decode(QueueRetention.self, forKey: .queueRetention)
        keepsClosedPageReady = try container.decode(Bool.self, forKey: .keepsClosedPageReady)
        searchProvider = try container.decode(SearchProvider.self, forKey: .searchProvider)
        diagnosticModeExpiresAt = try container.decodeIfPresent(Date.self, forKey: .diagnosticModeExpiresAt)
        appearance = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
        defaultPageZoom = try container.decodeIfPresent(PageZoomLevel.self, forKey: .defaultPageZoom) ?? .percent100
        downloadDirectoryBookmark = try container.decodeIfPresent(Data.self, forKey: .downloadDirectoryBookmark)
        homeSceneMode = try container.decodeIfPresent(HomeSceneMode.self, forKey: .homeSceneMode) ?? .onePhoto
        selectedHomeSceneID = try container.decodeIfPresent(String.self, forKey: .selectedHomeSceneID)
        homeSceneRotation = try container.decodeIfPresent(HomeSceneRotationState.self, forKey: .homeSceneRotation) ?? HomeSceneRotationState()
    }
}

/// The principal that requested an external-app handoff. Keel itself and a website named
/// `keel` are deliberately different principals.
public enum ExternalApplicationApprovalPrincipal: Codable, Equatable, Hashable, Sendable {
    case keel
    case websiteHostname(String)

    fileprivate var storedKind: String {
        switch self {
        case .keel: "keel"
        case .websiteHostname: "website-hostname"
        }
    }

    fileprivate var storedValue: String {
        switch self {
        case .keel: "keel"
        case let .websiteHostname(hostname): hostname
        }
    }

    public static func validatedWebsiteHostname(_ hostname: String) throws -> Self {
        let normalized = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              normalized.utf8.count <= 253,
              normalized.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        else { throw KeelStoreError.invalidExternalApplicationApproval }
        return .websiteHostname(normalized)
    }
}

/// The intentionally small, privacy-safe key for a remembered external-app handoff.
/// It never contains the target URL, path, query, or credentials.
public struct ExternalApplicationApprovalKey: Codable, Equatable, Hashable, Sendable {
    public let principal: ExternalApplicationApprovalPrincipal
    public let scheme: String

    public init(principal: ExternalApplicationApprovalPrincipal, scheme: String) throws {
        let normalizedScheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPrincipal: ExternalApplicationApprovalPrincipal = switch principal {
        case .keel:
            .keel
        case let .websiteHostname(hostname):
            try .validatedWebsiteHostname(hostname)
        }
        guard !normalizedScheme.isEmpty,
              normalizedScheme.utf8.count <= 64,
              normalizedScheme.first?.isLetter == true,
              normalizedScheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") })
        else { throw KeelStoreError.invalidExternalApplicationApproval }
        self.principal = normalizedPrincipal
        self.scheme = normalizedScheme
    }
}

public struct QueuedDestination: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let sequence: Int64
    public let capturedAt: Date

    public init(id: UUID = UUID(), url: URL, sequence: Int64, capturedAt: Date) {
        self.id = id
        self.url = url
        self.sequence = sequence
        self.capturedAt = capturedAt
    }
}

public struct ResumeCheckpoint: Codable, Equatable, Sendable {
    public let url: URL
    public let sessionID: UUID
    public let savedAt: Date
    public let interactionState: Data?

    public init(url: URL, sessionID: UUID, savedAt: Date, interactionState: Data? = nil) {
        self.url = url
        self.sessionID = sessionID
        self.savedAt = savedAt
        self.interactionState = interactionState
    }
}

public struct CloseUndoRecord: Codable, Equatable, Sendable {
    public let url: URL
    public let sessionID: UUID
    public let closedAt: Date
    public let deadline: Date

    public init(url: URL, sessionID: UUID, closedAt: Date, deadline: Date) {
        self.url = url
        self.sessionID = sessionID
        self.closedAt = closedAt
        self.deadline = deadline
    }
}

public struct BrowsingSession: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let hostname: String?

    public init(id: UUID, startedAt: Date, endedAt: Date? = nil, hostname: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.hostname = hostname
    }
}

public enum DownloadState: String, Codable, Sendable {
    case inProgress
    case completed
    case cancelled
    case failed
}

public struct DownloadRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let hostname: String
    public let filename: String
    public let pathReference: String?
    public let byteCount: Int64
    public let state: DownloadState
    public let createdAt: Date
    public let completedAt: Date?
    public let errorCode: Int?

    public init(
        id: UUID,
        hostname: String,
        filename: String,
        pathReference: String? = nil,
        byteCount: Int64,
        state: DownloadState,
        createdAt: Date,
        completedAt: Date? = nil,
        errorCode: Int? = nil
    ) {
        self.id = id
        self.hostname = hostname
        self.filename = filename
        self.pathReference = pathReference
        self.byteCount = byteCount
        self.state = state
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.errorCode = errorCode
    }
}

public enum DiagnosticEventType: String, Codable, Sendable {
    case navigation
    case webKitCallback
    case policyDecision
    case processEvent
    case download
}

public enum DiagnosticResult: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
    case ignored
}

/// A hostname is deliberately separate from URL. It rejects schemes, paths, ports, and query data.
public struct DiagnosticHostname: Codable, Equatable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        let normalized = value.lowercased()
        guard !normalized.isEmpty,
              normalized.utf8.count <= 253,
              !normalized.contains("://"),
              !normalized.contains("/"),
              !normalized.contains("?"),
              !normalized.contains("#"),
              !normalized.contains(":"),
              normalized.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        else { throw KeelStoreError.invalidDiagnosticHostname }
        self.value = normalized
    }
}

public struct DiagnosticRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let timestamp: Date
    public let eventType: DiagnosticEventType
    public let hostname: DiagnosticHostname
    public let result: DiagnosticResult
    public let durationMilliseconds: Int?
    public let errorCode: Int?

    public init(timestamp: Date, eventType: DiagnosticEventType, hostname: DiagnosticHostname, result: DiagnosticResult, durationMilliseconds: Int? = nil, errorCode: Int? = nil, id: Int64 = 0) {
        self.id = id
        self.timestamp = timestamp
        self.eventType = eventType
        self.hostname = hostname
        self.result = result
        self.durationMilliseconds = durationMilliseconds
        self.errorCode = errorCode
    }
}

/// The small, privacy-safe diagnostic payload that Settings can save locally.
/// It contains only the diagnostic fields that Keel stores, never full URLs or page contents.
public struct DiagnosticExport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let records: [DiagnosticRecord]

    public init(generatedAt: Date, records: [DiagnosticRecord]) {
        self.generatedAt = generatedAt
        self.records = records
    }
}

public struct QueueDeletionUndo: Codable, Equatable, Sendable {
    public let deadline: Date
    public let destinations: [QueuedDestination]

    public init(deadline: Date, destinations: [QueuedDestination]) {
        self.deadline = deadline
        self.destinations = destinations
    }
}

public struct KeelRuntimeState: Codable, Equatable, Sendable {
    public let queue: [QueuedDestination]
    public let resumeCheckpoint: ResumeCheckpoint?
    public let closeUndo: CloseUndoRecord?
    public let queueDeletionUndo: QueueDeletionUndo?
    public let activeSession: BrowsingSession?
    public let downloads: [DownloadRecord]
    public let settings: KeelSettings
}

public enum StoreChangeOutcome: Equatable, Sendable {
    case captured(QueuedDestination?)
    case consumed(QueuedDestination?)
    case completed
}

public struct KeelStoreCommit: Equatable, Sendable {
    public let runtimeState: KeelRuntimeState
    public let outcomes: [StoreChangeOutcome]
}

public enum StoreChange: Sendable {
    case captureQueuedDestination(URL)
    case prependQueuedDestination(URL)
    case consumeOldestQueuedDestination
    case advanceToOldestQueuedDestination(startingSession: BrowsingSession)
    case removeQueuedDestinations(ids: [UUID])
    case clearQueuedDestinations
    case restoreLatestQueueDeletionUndo
    case replaceResumeCheckpoint(ResumeCheckpoint?)
    case replaceCloseUndo(CloseUndoRecord?)
    case upsertSession(BrowsingSession)
    case updateDownload(DownloadRecord)
    case removeDownloads(ids: [UUID])
    case replaceSettings(KeelSettings)
    case recordAddressChoice(input: String, historyURLID: Int64)
    case recordDiagnostic(DiagnosticRecord)
    case deleteDiagnostics
    case rememberExternalApplicationApproval(ExternalApplicationApprovalKey)
    case forgetExternalApplicationApproval(ExternalApplicationApprovalKey)
}

public enum KeelStoreError: Error, Equatable, Sendable {
    case storageFailure
    case corruptData
    case invalidDiagnosticHostname
    case invalidSettings
    case invalidExternalApplicationApproval
    case invalidDownloadReadLimit
}

public actor KeelStore {
    let database: SQLiteDatabase
    nonisolated let databaseURL: URL
    let now: @Sendable () -> Date
    let faultInjector: @Sendable (Int) throws -> Void

    public init() throws {
        try self.init(paths: KeelPathProvider.paths())
    }

    public init(paths: KeelPaths) throws {
        try self.init(databaseURL: paths.databaseURL, now: Date.init, faultInjector: { _ in })
    }

    init(databaseURL: URL) throws {
        try self.init(databaseURL: databaseURL, now: Date.init, faultInjector: { _ in })
    }

    init(
        databaseURL: URL,
        now: @escaping @Sendable () -> Date,
        faultInjector: @escaping @Sendable (Int) throws -> Void = { _ in }
    ) throws {
        self.now = now
        self.faultInjector = faultInjector
        self.databaseURL = databaseURL
        database = try SQLiteDatabase(url: databaseURL)
        try KeelStoreMigrationRunner.apply(database, migrations: Self.migrations)
    }

    public func runtimeState() throws -> KeelRuntimeState {
        try database.transaction {
            let settings = try self.settings()
            try self.pruneExpiredQueue(settings: settings, at: now())
            return try self.runtimeState(settings: settings, at: now())
        }
    }

    public func diagnostics() throws -> [DiagnosticRecord] {
        try database.rows(
            "SELECT id, timestamp, event_type, hostname, result, duration_ms, error_code FROM diagnostics ORDER BY id ASC"
        ).map(Self.diagnostic)
    }

    /// Returns a bounded, newest-first download history for the management screen.
    /// Current transfers remain durable through the same records as completed transfers.
    public func downloadRecords(limit: Int = 200) throws -> [DownloadRecord] {
        guard (1 ... Self.downloadRecordLimit).contains(limit) else {
            throw KeelStoreError.invalidDownloadReadLimit
        }
        return try database.rows(
            "SELECT id, hostname, filename, path_reference, byte_count, state, created_at, completed_at, error_code FROM downloads ORDER BY created_at DESC, id DESC LIMIT ?",
            values: [.integer(Int64(limit))]
        ).map(Self.download)
    }

    /// Encodes the bounded, locally stored diagnostic ledger for an explicit user export.
    /// Exporting is a read-only operation and cannot enable diagnostics or change retention.
    public func diagnosticExportData() throws -> Data {
        let export = DiagnosticExport(generatedAt: now(), records: try diagnostics())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }

    func diagnosticEstimatedBytes() throws -> Int64 {
        try database.scalarInteger("SELECT COALESCE(SUM(estimated_bytes), 0) FROM diagnostics") ?? 0
    }

    public func apply(_ changes: [StoreChange]) throws -> KeelStoreCommit {
        try database.transaction {
            var settings = try self.settings()
            var outcomes: [StoreChangeOutcome] = []
            try self.pruneExpiredQueue(settings: settings, at: now())
            for (index, change) in changes.enumerated() {
                try faultInjector(index)
                switch change {
                case let .captureQueuedDestination(url):
                    outcomes.append(.captured(try self.capture(url, at: now())))
                case let .prependQueuedDestination(url):
                    outcomes.append(.captured(try self.prepend(url, at: now())))
                case .consumeOldestQueuedDestination:
                    outcomes.append(.consumed(try self.consumeOldestQueuedDestination()))
                case let .advanceToOldestQueuedDestination(startingSession):
                    outcomes.append(.consumed(try self.advanceToOldestQueuedDestination(startingSession: startingSession)))
                case let .removeQueuedDestinations(ids):
                    try self.removeQueue(ids: ids, deletedAt: now())
                    outcomes.append(.completed)
                case .clearQueuedDestinations:
                    try self.clearQueue(deletedAt: now())
                    outcomes.append(.completed)
                case .restoreLatestQueueDeletionUndo:
                    try self.restoreQueueDeletionUndo(at: now(), settings: settings)
                    outcomes.append(.completed)
                case let .replaceResumeCheckpoint(checkpoint):
                    try self.replaceResume(checkpoint)
                    outcomes.append(.completed)
                case let .replaceCloseUndo(undo):
                    try self.replaceCloseUndo(undo)
                    outcomes.append(.completed)
                case let .upsertSession(session):
                    try self.upsert(session)
                    outcomes.append(.completed)
                case let .updateDownload(download):
                    try self.upsert(download)
                    outcomes.append(.completed)
                case let .removeDownloads(ids):
                    try self.removeDownloads(ids)
                    outcomes.append(.completed)
                case let .replaceSettings(newSettings):
                    try self.validate(newSettings)
                    try self.replaceSettings(newSettings)
                    settings = newSettings
                    try self.pruneExpiredQueue(settings: settings, at: now())
                    outcomes.append(.completed)
                case let .recordAddressChoice(input, historyURLID):
                    try self.recordAddressChoice(input: input, historyURLID: historyURLID, at: now())
                    outcomes.append(.completed)
                case let .recordDiagnostic(record):
                    try self.recordDiagnostic(record, settings: settings)
                    outcomes.append(.completed)
                case .deleteDiagnostics:
                    try database.execute("DELETE FROM diagnostics")
                    outcomes.append(.completed)
                case let .rememberExternalApplicationApproval(key):
                    try self.rememberExternalApplicationApproval(key, at: now())
                    outcomes.append(.completed)
                case let .forgetExternalApplicationApproval(key):
                    try self.forgetExternalApplicationApproval(key)
                    outcomes.append(.completed)
                }
            }
            return KeelStoreCommit(
                runtimeState: try self.runtimeState(settings: settings, at: now()),
                outcomes: outcomes
            )
        }
    }

    /// Other store domains append their migrations to this list. The runner's ledger makes each one atomic and idempotent.
    static let migrations = [
        KeelStoreMigration(identifier: "state.0001", apply: createStateSchema),
        KeelStoreMigration(identifier: "history.0001", apply: createHistorySchema),
        KeelStoreMigration(identifier: "external-apps.0001", apply: createExternalApplicationApprovalSchema),
        KeelStoreMigration(identifier: "external-apps.0002", apply: migrateExternalApplicationApprovalPrincipals),
        KeelStoreMigration(identifier: "state.0002", apply: addPresentationAndDownloadSettings),
        KeelStoreMigration(identifier: "home-scenes.0001", apply: createHomeSceneSchema),
    ]

    private static func createStateSchema(_ database: SQLiteDatabase) throws {
            try database.execute("""
                CREATE TABLE settings (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    queue_retention_seconds INTEGER NOT NULL,
                    keeps_closed_page_ready INTEGER NOT NULL,
                    search_provider TEXT NOT NULL,
                    diagnostic_mode_expires_at REAL
                )
                """)
            try database.execute("""
                CREATE TABLE queue (
                    id TEXT PRIMARY KEY NOT NULL,
                    url TEXT UNIQUE NOT NULL,
                    sequence INTEGER UNIQUE NOT NULL,
                    captured_at REAL NOT NULL
                )
                """)
            try database.execute("CREATE TABLE queue_sequence (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), next_sequence INTEGER NOT NULL)")
            try database.execute("""
                CREATE TABLE queue_deletion_undo (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    deadline REAL NOT NULL
                )
                """)
            try database.execute("""
                CREATE TABLE queue_deletion_undo_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    url TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    captured_at REAL NOT NULL
                )
                """)
            try database.execute("""
                CREATE TABLE resume_checkpoint (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    url TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    saved_at REAL NOT NULL,
                    interaction_state BLOB
                )
                """)
            try database.execute("""
                CREATE TABLE close_undo (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    url TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    closed_at REAL NOT NULL,
                    deadline REAL NOT NULL
                )
                """)
            try database.execute("""
                CREATE TABLE browsing_sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    started_at REAL NOT NULL,
                    ended_at REAL,
                    hostname TEXT
                )
                """)
            try database.execute("""
                CREATE TABLE downloads (
                    id TEXT PRIMARY KEY NOT NULL,
                    hostname TEXT NOT NULL,
                    filename TEXT NOT NULL,
                    path_reference TEXT,
                    byte_count INTEGER NOT NULL,
                    state TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    completed_at REAL,
                    error_code INTEGER
                )
                """)
            try database.execute("""
                CREATE TABLE diagnostics (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp REAL NOT NULL,
                    event_type TEXT NOT NULL,
                    hostname TEXT NOT NULL,
                    result TEXT NOT NULL,
                    duration_ms INTEGER,
                    error_code INTEGER,
                    estimated_bytes INTEGER NOT NULL
                )
                """)
            try database.execute("CREATE INDEX diagnostics_timestamp_index ON diagnostics(timestamp)")
            try database.execute("INSERT INTO settings (singleton, queue_retention_seconds, keeps_closed_page_ready, search_provider) VALUES (1, ?, 1, 'google')", values: [.integer(Int64(QueueRetention.hours72.rawValue))])
            try database.execute("INSERT INTO queue_sequence (singleton, next_sequence) VALUES (1, 0)")
    }

    /// Column defaults carry every pre-existing row to the same values a fresh install starts with.
    private static func addPresentationAndDownloadSettings(_ database: SQLiteDatabase) throws {
        try database.execute("ALTER TABLE settings ADD COLUMN appearance TEXT NOT NULL DEFAULT 'system'")
        try database.execute("ALTER TABLE settings ADD COLUMN default_page_zoom INTEGER NOT NULL DEFAULT 100")
        try database.execute("ALTER TABLE settings ADD COLUMN download_directory_bookmark BLOB")
    }

    private static func createExternalApplicationApprovalSchema(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE external_application_approvals (
                source TEXT NOT NULL,
                scheme TEXT NOT NULL,
                approved_at REAL NOT NULL,
                PRIMARY KEY (source, scheme)
            )
            """)
    }

    /// Existing v1 rows predate typed Keel approvals. Treat them as websites so a legacy
    /// hostname named `keel` can never silently grant the Keel application a privilege.
    private static func migrateExternalApplicationApprovalPrincipals(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE external_application_approvals_v2 (
                principal_kind TEXT NOT NULL CHECK (principal_kind IN ('keel', 'website-hostname')),
                principal_value TEXT NOT NULL,
                scheme TEXT NOT NULL,
                approved_at REAL NOT NULL,
                PRIMARY KEY (principal_kind, principal_value, scheme)
            )
            """)
        try database.execute("""
            INSERT INTO external_application_approvals_v2 (principal_kind, principal_value, scheme, approved_at)
            SELECT 'website-hostname', source, scheme, approved_at FROM external_application_approvals
            """)
        try database.execute("DROP TABLE external_application_approvals")
        try database.execute("ALTER TABLE external_application_approvals_v2 RENAME TO external_application_approvals")
    }

    /// Kept outside `runtimeState`: remembered app handoffs are an independent durable domain.
    public func hasExternalApplicationApproval(for key: ExternalApplicationApprovalKey) throws -> Bool {
        try database.scalarText(
            "SELECT principal_value FROM external_application_approvals WHERE principal_kind = ? AND principal_value = ? AND scheme = ?",
            values: [.text(key.principal.storedKind), .text(key.principal.storedValue), .text(key.scheme)]
        ) != nil
    }

    private func settings() throws -> KeelSettings {
        guard let row = try database.rows("SELECT queue_retention_seconds, keeps_closed_page_ready, search_provider, diagnostic_mode_expires_at, appearance, default_page_zoom, download_directory_bookmark, home_scene_mode, home_scene_selected, home_scene_rotation FROM settings WHERE singleton = 1").first,
              let retentionRaw = row.integer(0),
              let retention = QueueRetention(rawValue: Int(retentionRaw)),
              let keep = row.integer(1),
              let providerRaw = row.text(2),
              let appearanceRaw = row.text(4),
              let appearance = AppearanceMode(rawValue: appearanceRaw),
              let zoomRaw = row.integer(5),
              let zoom = PageZoomLevel(rawValue: Int(zoomRaw))
        else { throw KeelStoreError.corruptData }
        return KeelSettings(
            queueRetention: retention,
            keepsClosedPageReady: keep != 0,
            searchProvider: try SearchProvider(storedValue: providerRaw),
            diagnosticModeExpiresAt: row.real(3).map(Date.init(timeIntervalSince1970:)),
            appearance: appearance,
            defaultPageZoom: zoom,
            downloadDirectoryBookmark: row.blob(6),
            homeSceneMode: row.text(7).flatMap(HomeSceneMode.init(rawValue:)) ?? .onePhoto,
            selectedHomeSceneID: row.text(8),
            homeSceneRotation: HomeSceneRotationCoding.decode(row.text(9))
        )
    }

    private func runtimeState(settings: KeelSettings, at date: Date) throws -> KeelRuntimeState {
        KeelRuntimeState(
            queue: try database.rows("SELECT id, url, sequence, captured_at FROM queue ORDER BY sequence ASC").map(Self.queuedDestination),
            resumeCheckpoint: try database.rows("SELECT url, session_id, saved_at, interaction_state FROM resume_checkpoint WHERE singleton = 1").first.map(Self.resumeCheckpoint),
            closeUndo: try closeUndo(at: date),
            queueDeletionUndo: try queueDeletionUndo(settings: settings, at: date),
            activeSession: try database.rows("SELECT id, started_at, ended_at, hostname FROM browsing_sessions WHERE ended_at IS NULL ORDER BY started_at DESC LIMIT 1").first.map(Self.session),
            downloads: try database.rows("SELECT id, hostname, filename, path_reference, byte_count, state, created_at, completed_at, error_code FROM downloads ORDER BY created_at ASC").map(Self.download),
            settings: settings
        )
    }

    private func queueDeletionUndo(settings: KeelSettings, at date: Date) throws -> QueueDeletionUndo? {
        guard let row = try database.rows("SELECT deadline FROM queue_deletion_undo WHERE singleton = 1").first,
              let deadline = row.real(0).map(Date.init(timeIntervalSince1970:)), deadline > date else {
            try database.execute("DELETE FROM queue_deletion_undo")
            try database.execute("DELETE FROM queue_deletion_undo_items")
            return nil
        }
        let destinations = try database.rows("SELECT id, url, sequence, captured_at FROM queue_deletion_undo_items ORDER BY sequence ASC")
            .map(Self.queuedDestination)
            .filter { $0.capturedAt.addingTimeInterval(TimeInterval(settings.queueRetention.rawValue)) > date }
        return destinations.isEmpty ? nil : QueueDeletionUndo(deadline: deadline, destinations: destinations)
    }

    private func closeUndo(at date: Date) throws -> CloseUndoRecord? {
        guard let row = try database.rows("SELECT url, session_id, closed_at, deadline FROM close_undo WHERE singleton = 1").first else { return nil }
        let undo = try Self.closeUndo(row)
        guard undo.deadline > date else {
            try database.execute("DELETE FROM close_undo")
            return nil
        }
        return undo
    }

    private func capture(_ url: URL, at date: Date) throws -> QueuedDestination? {
        let normalized = url.absoluteString
        guard !normalized.isEmpty else { return nil }
        if try database.scalarText("SELECT id FROM queue WHERE url = ?", values: [.text(normalized)]) != nil { return nil }
        guard let sequence = try database.scalarInteger("SELECT next_sequence FROM queue_sequence WHERE singleton = 1") else { throw KeelStoreError.corruptData }
        guard sequence < Int64.max else { throw KeelStoreError.storageFailure }
        let destination = QueuedDestination(url: url, sequence: sequence, capturedAt: date)
        try database.execute("INSERT INTO queue (id, url, sequence, captured_at) VALUES (?, ?, ?, ?)", values: [.text(destination.id.uuidString), .text(normalized), .integer(sequence), .real(date.timeIntervalSince1970)])
        try database.execute("UPDATE queue_sequence SET next_sequence = ? WHERE singleton = 1", values: [.integer(sequence + 1)])
        return destination
    }

    private func prepend(_ url: URL, at date: Date) throws -> QueuedDestination? {
        let normalized = url.absoluteString
        guard !normalized.isEmpty else { return nil }
        if try database.scalarText("SELECT id FROM queue WHERE url = ?", values: [.text(normalized)]) != nil { return nil }
        guard let first = try database.rows("SELECT id, url, sequence, captured_at FROM queue ORDER BY sequence ASC LIMIT 1").first else {
            return try capture(url, at: date)
        }
        guard let firstSequence = first.integer(2) else { throw KeelStoreError.corruptData }
        if firstSequence == Int64.min {
            return try reindexQueueAndPrepend(url, at: date)
        }
        let destination = QueuedDestination(url: url, sequence: firstSequence - 1, capturedAt: date)
        try database.execute(
            "INSERT INTO queue (id, url, sequence, captured_at) VALUES (?, ?, ?, ?)",
            values: [
                .text(destination.id.uuidString),
                .text(normalized),
                .integer(destination.sequence),
                .real(date.timeIntervalSince1970),
            ]
        )
        return destination
    }

    /// SQLite stores queue order as a unique Int64. If repeated prepends reach Int64.min,
    /// rewrite the rows in their existing order inside the caller's transaction.
    private func reindexQueueAndPrepend(_ url: URL, at date: Date) throws -> QueuedDestination {
        let existing = try database.rows("SELECT id, url, sequence, captured_at FROM queue ORDER BY sequence ASC").map(Self.queuedDestination)
        guard let count = Int64(exactly: existing.count), count < Int64.max else { throw KeelStoreError.storageFailure }
        let destination = QueuedDestination(url: url, sequence: 0, capturedAt: date)
        try database.execute("DELETE FROM queue")
        try database.execute(
            "INSERT INTO queue (id, url, sequence, captured_at) VALUES (?, ?, ?, ?)",
            values: [
                .text(destination.id.uuidString),
                .text(destination.url.absoluteString),
                .integer(destination.sequence),
                .real(destination.capturedAt.timeIntervalSince1970),
            ]
        )
        for (offset, record) in existing.enumerated() {
            guard let sequence = Int64(exactly: offset), sequence < Int64.max else { throw KeelStoreError.storageFailure }
            try database.execute(
                "INSERT INTO queue (id, url, sequence, captured_at) VALUES (?, ?, ?, ?)",
                values: [
                    .text(record.id.uuidString),
                    .text(record.url.absoluteString),
                    .integer(sequence + 1),
                    .real(record.capturedAt.timeIntervalSince1970),
                ]
            )
        }
        try database.execute(
            "UPDATE queue_sequence SET next_sequence = ? WHERE singleton = 1",
            values: [.integer(count + 1)]
        )
        return destination
    }

    private func consumeOldestQueuedDestination() throws -> QueuedDestination? {
        guard let row = try database.rows("SELECT id, url, sequence, captured_at FROM queue ORDER BY sequence ASC LIMIT 1").first else { return nil }
        let destination = try Self.queuedDestination(row)
        try database.execute("DELETE FROM queue WHERE id = ?", values: [.text(destination.id.uuidString)])
        return destination
    }

    private func advanceToOldestQueuedDestination(startingSession: BrowsingSession) throws -> QueuedDestination? {
        guard let destination = try consumeOldestQueuedDestination() else { return nil }
        let session = BrowsingSession(
            id: startingSession.id,
            startedAt: startingSession.startedAt,
            endedAt: nil,
            hostname: startingSession.hostname ?? destination.url.host?.lowercased()
        )
        try upsert(session)
        return destination
    }

    private func removeQueue(ids: [UUID], deletedAt: Date) throws {
        let identifiers = Array(Set(ids.map(\.uuidString)))
        guard !identifiers.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: identifiers.count).joined(separator: ", ")
        let records = try database.rows(
            "SELECT id, url, sequence, captured_at FROM queue WHERE id IN (\(placeholders)) ORDER BY sequence ASC",
            values: identifiers.map { .text($0) }
        ).map(Self.queuedDestination)
        guard !records.isEmpty else { return }
        try database.execute("DELETE FROM queue_deletion_undo")
        try database.execute("DELETE FROM queue_deletion_undo_items")
        try database.execute("INSERT INTO queue_deletion_undo (singleton, deadline) VALUES (1, ?)", values: [.real(deletedAt.addingTimeInterval(60).timeIntervalSince1970)])
        for record in records {
            try database.execute("INSERT INTO queue_deletion_undo_items (id, url, sequence, captured_at) VALUES (?, ?, ?, ?)", values: [.text(record.id.uuidString), .text(record.url.absoluteString), .integer(record.sequence), .real(record.capturedAt.timeIntervalSince1970)])
            try database.execute("DELETE FROM queue WHERE id = ?", values: [.text(record.id.uuidString)])
        }
    }

    private func clearQueue(deletedAt: Date) throws {
        guard let count = try database.scalarInteger("SELECT COUNT(*) FROM queue"), count > 0 else { return }
        try database.execute("DELETE FROM queue_deletion_undo")
        try database.execute("DELETE FROM queue_deletion_undo_items")
        try database.execute(
            "INSERT INTO queue_deletion_undo (singleton, deadline) VALUES (1, ?)",
            values: [.real(deletedAt.addingTimeInterval(60).timeIntervalSince1970)]
        )
        try database.execute(
            "INSERT INTO queue_deletion_undo_items (id, url, sequence, captured_at) SELECT id, url, sequence, captured_at FROM queue"
        )
        try database.execute("DELETE FROM queue")
    }

    private func restoreQueueDeletionUndo(at date: Date, settings: KeelSettings) throws {
        guard let deadline = try database.scalarReal("SELECT deadline FROM queue_deletion_undo WHERE singleton = 1"), deadline > date.timeIntervalSince1970 else {
            try database.execute("DELETE FROM queue_deletion_undo")
            try database.execute("DELETE FROM queue_deletion_undo_items")
            return
        }
        let current = try database.rows("SELECT id, url, sequence, captured_at FROM queue ORDER BY sequence ASC").map(Self.queuedDestination)
        var knownURLs = Set(current.map { $0.url.absoluteString })
        let undoRecords = try database.rows("SELECT id, url, sequence, captured_at FROM queue_deletion_undo_items ORDER BY sequence ASC").map(Self.queuedDestination).filter { record in
            record.capturedAt.addingTimeInterval(TimeInterval(settings.queueRetention.rawValue)) > date
        }
        let restored = undoRecords.filter { record in
            return knownURLs.insert(record.url.absoluteString).inserted
        }

        let currentSequences = Set(current.map(\.sequence))
        let undoSequences = Set(undoRecords.map(\.sequence))
        let hasSequenceCollision = undoSequences.count != undoRecords.count || undoRecords.contains { currentSequences.contains($0.sequence) }
        if hasSequenceCollision {
            var currentPrefixCount = 0
            while currentPrefixCount < current.count,
                  undoSequences.contains(current[currentPrefixCount].sequence) {
                currentPrefixCount += 1
            }
            let currentPrefix = current.prefix(currentPrefixCount)
            let remainingCurrent = current.dropFirst(currentPrefixCount)
            let merged = remainingCurrent.map { (destination: $0, restored: false, order: 0) } + restored.enumerated().map { index, destination in
                (destination: destination, restored: true, order: index)
            }
            let ordered = merged.sorted { left, right in
                if left.destination.sequence != right.destination.sequence {
                    return left.destination.sequence < right.destination.sequence
                }
                if left.restored != right.restored {
                    return !left.restored
                }
                return left.order < right.order
            }
            try reindexQueue(currentPrefix.map { $0 } + ordered.map(\.destination))
        } else {
            for record in restored {
                try insertQueuedDestination(record)
            }
            try synchronizeQueueSequence()
        }
        try database.execute("DELETE FROM queue_deletion_undo")
        try database.execute("DELETE FROM queue_deletion_undo_items")
    }

    private func insertQueuedDestination(_ destination: QueuedDestination) throws {
        try database.execute(
            "INSERT INTO queue (id, url, sequence, captured_at) VALUES (?, ?, ?, ?)",
            values: [
                .text(destination.id.uuidString),
                .text(destination.url.absoluteString),
                .integer(destination.sequence),
                .real(destination.capturedAt.timeIntervalSince1970),
            ]
        )
    }

    /// Rewrites only the queue rows, preserving each destination's identity and metadata.
    /// The caller already owns the enclosing store transaction.
    private func reindexQueue(_ destinations: [QueuedDestination]) throws {
        guard let count = Int64(exactly: destinations.count), count < Int64.max else { throw KeelStoreError.storageFailure }
        try database.execute("DELETE FROM queue")
        for (offset, destination) in destinations.enumerated() {
            guard let sequence = Int64(exactly: offset) else { throw KeelStoreError.storageFailure }
            try insertQueuedDestination(QueuedDestination(id: destination.id, url: destination.url, sequence: sequence, capturedAt: destination.capturedAt))
        }
        try database.execute(
            "UPDATE queue_sequence SET next_sequence = ? WHERE singleton = 1",
            values: [.integer(count)]
        )
    }

    private func synchronizeQueueSequence() throws {
        guard let maximum = try database.scalarInteger("SELECT MAX(sequence) FROM queue"), maximum < Int64.max,
              let next = try database.scalarInteger("SELECT next_sequence FROM queue_sequence WHERE singleton = 1"), next <= maximum
        else { return }
        try database.execute(
            "UPDATE queue_sequence SET next_sequence = ? WHERE singleton = 1",
            values: [.integer(maximum + 1)]
        )
    }

    private func replaceResume(_ checkpoint: ResumeCheckpoint?) throws {
        try database.execute("DELETE FROM resume_checkpoint")
        guard let checkpoint else { return }
        try database.execute("INSERT INTO resume_checkpoint (singleton, url, session_id, saved_at, interaction_state) VALUES (1, ?, ?, ?, ?)", values: [.text(checkpoint.url.absoluteString), .text(checkpoint.sessionID.uuidString), .real(checkpoint.savedAt.timeIntervalSince1970), .blob(checkpoint.interactionState)])
    }

    private func replaceCloseUndo(_ undo: CloseUndoRecord?) throws {
        try database.execute("DELETE FROM close_undo")
        guard let undo else { return }
        try database.execute("INSERT INTO close_undo (singleton, url, session_id, closed_at, deadline) VALUES (1, ?, ?, ?, ?)", values: [.text(undo.url.absoluteString), .text(undo.sessionID.uuidString), .real(undo.closedAt.timeIntervalSince1970), .real(undo.deadline.timeIntervalSince1970)])
    }

    private func upsert(_ session: BrowsingSession) throws {
        try database.execute("INSERT INTO browsing_sessions (id, started_at, ended_at, hostname) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET started_at = excluded.started_at, ended_at = excluded.ended_at, hostname = excluded.hostname", values: [.text(session.id.uuidString), .real(session.startedAt.timeIntervalSince1970), .real(session.endedAt?.timeIntervalSince1970), .text(session.hostname)])
    }

    private func upsert(_ download: DownloadRecord) throws {
        try database.execute("INSERT INTO downloads (id, hostname, filename, path_reference, byte_count, state, created_at, completed_at, error_code) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET hostname = excluded.hostname, filename = excluded.filename, path_reference = excluded.path_reference, byte_count = excluded.byte_count, state = excluded.state, created_at = excluded.created_at, completed_at = excluded.completed_at, error_code = excluded.error_code", values: [.text(download.id.uuidString), .text(download.hostname), .text(download.filename), .text(download.pathReference), .integer(download.byteCount), .text(download.state.rawValue), .real(download.createdAt.timeIntervalSince1970), .real(download.completedAt?.timeIntervalSince1970), .integer(download.errorCode.map(Int64.init))])
    }

    private func removeDownloads(_ ids: [UUID]) throws {
        for id in Set(ids) { try database.execute("DELETE FROM downloads WHERE id = ?", values: [.text(id.uuidString)]) }
    }

    private func validate(_ settings: KeelSettings) throws {
        if case let .custom(template) = settings.searchProvider,
           !SearchProvider.isValidCustomTemplate(template) {
            throw KeelStoreError.invalidSettings
        }
        if let expiresAt = settings.diagnosticModeExpiresAt,
           expiresAt > now().addingTimeInterval(30 * 60) { throw KeelStoreError.invalidSettings }
        if let bookmark = settings.downloadDirectoryBookmark,
           bookmark.isEmpty || bookmark.count > DownloadDirectoryBookmark.byteLimit {
            throw KeelStoreError.invalidSettings
        }
    }

    private func replaceSettings(_ settings: KeelSettings) throws {
        try database.execute("UPDATE settings SET queue_retention_seconds = ?, keeps_closed_page_ready = ?, search_provider = ?, diagnostic_mode_expires_at = ?, appearance = ?, default_page_zoom = ?, download_directory_bookmark = ?, home_scene_mode = ?, home_scene_selected = ?, home_scene_rotation = ? WHERE singleton = 1", values: [.integer(Int64(settings.queueRetention.rawValue)), .integer(settings.keepsClosedPageReady ? 1 : 0), .text(settings.searchProvider.storedValue), .real(settings.diagnosticModeExpiresAt?.timeIntervalSince1970), .text(settings.appearance.rawValue), .integer(Int64(settings.defaultPageZoom.rawValue)), .blob(settings.downloadDirectoryBookmark), .text(settings.homeSceneMode.rawValue), .text(settings.selectedHomeSceneID), .text(HomeSceneRotationCoding.encode(settings.homeSceneRotation))])
    }

    private func rememberExternalApplicationApproval(_ key: ExternalApplicationApprovalKey, at date: Date) throws {
        try database.execute(
            """
            INSERT INTO external_application_approvals (principal_kind, principal_value, scheme, approved_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(principal_kind, principal_value, scheme) DO UPDATE SET approved_at = excluded.approved_at
            """,
            values: [.text(key.principal.storedKind), .text(key.principal.storedValue), .text(key.scheme), .real(date.timeIntervalSince1970)]
        )
    }

    private func forgetExternalApplicationApproval(_ key: ExternalApplicationApprovalKey) throws {
        try database.execute(
            "DELETE FROM external_application_approvals WHERE principal_kind = ? AND principal_value = ? AND scheme = ?",
            values: [.text(key.principal.storedKind), .text(key.principal.storedValue), .text(key.scheme)]
        )
    }

    private func recordDiagnostic(_ record: DiagnosticRecord, settings: KeelSettings) throws {
        guard let expires = settings.diagnosticModeExpiresAt, expires > now() else { return }
        let estimatedBytes = Int64(record.hostname.value.utf8.count + record.eventType.rawValue.utf8.count + record.result.rawValue.utf8.count + 64)
        try database.execute("INSERT INTO diagnostics (timestamp, event_type, hostname, result, duration_ms, error_code, estimated_bytes) VALUES (?, ?, ?, ?, ?, ?, ?)", values: [.real(record.timestamp.timeIntervalSince1970), .text(record.eventType.rawValue), .text(record.hostname.value), .text(record.result.rawValue), .integer(record.durationMilliseconds.map(Int64.init)), .integer(record.errorCode.map(Int64.init)), .integer(estimatedBytes)])
        var total = try diagnosticEstimatedBytes()
        while total > Self.diagnosticByteCap {
            guard let oldest = try database.rows("SELECT id, estimated_bytes FROM diagnostics ORDER BY id ASC LIMIT 1").first,
                  let identifier = oldest.integer(0), let bytes = oldest.integer(1) else { break }
            try database.execute("DELETE FROM diagnostics WHERE id = ?", values: [.integer(identifier)])
            total -= bytes
        }
    }

    static let diagnosticByteCap: Int64 = 5 * 1_024 * 1_024
    static let downloadRecordLimit = 1_000

    private func pruneExpiredQueue(settings: KeelSettings, at date: Date) throws {
        let cutoff = date.addingTimeInterval(-TimeInterval(settings.queueRetention.rawValue)).timeIntervalSince1970
        try database.execute("DELETE FROM queue WHERE captured_at <= ?", values: [.real(cutoff)])
        try database.execute("DELETE FROM queue_deletion_undo_items WHERE captured_at <= ?", values: [.real(cutoff)])
        if try database.scalarInteger("SELECT COUNT(*) FROM queue_deletion_undo_items") == 0 {
            try database.execute("DELETE FROM queue_deletion_undo")
        }
    }

    private static func queuedDestination(_ row: SQLiteRow) throws -> QueuedDestination {
        guard let id = row.text(0).flatMap(UUID.init(uuidString:)), let urlText = row.text(1), let url = URL(string: urlText), let sequence = row.integer(2), let capturedAt = row.real(3) else { throw KeelStoreError.corruptData }
        return QueuedDestination(id: id, url: url, sequence: sequence, capturedAt: Date(timeIntervalSince1970: capturedAt))
    }

    private static func resumeCheckpoint(_ row: SQLiteRow) throws -> ResumeCheckpoint {
        guard let urlText = row.text(0), let url = URL(string: urlText), let sessionID = row.text(1).flatMap(UUID.init(uuidString:)), let savedAt = row.real(2) else { throw KeelStoreError.corruptData }
        return ResumeCheckpoint(url: url, sessionID: sessionID, savedAt: Date(timeIntervalSince1970: savedAt), interactionState: row.blob(3))
    }

    private static func closeUndo(_ row: SQLiteRow) throws -> CloseUndoRecord {
        guard let urlText = row.text(0), let url = URL(string: urlText), let sessionID = row.text(1).flatMap(UUID.init(uuidString:)), let closedAt = row.real(2), let deadline = row.real(3) else { throw KeelStoreError.corruptData }
        return CloseUndoRecord(url: url, sessionID: sessionID, closedAt: Date(timeIntervalSince1970: closedAt), deadline: Date(timeIntervalSince1970: deadline))
    }

    private static func session(_ row: SQLiteRow) throws -> BrowsingSession {
        guard let id = row.text(0).flatMap(UUID.init(uuidString:)), let startedAt = row.real(1) else { throw KeelStoreError.corruptData }
        return BrowsingSession(id: id, startedAt: Date(timeIntervalSince1970: startedAt), endedAt: row.real(2).map(Date.init(timeIntervalSince1970:)), hostname: row.text(3))
    }

    private static func download(_ row: SQLiteRow) throws -> DownloadRecord {
        guard let id = row.text(0).flatMap(UUID.init(uuidString:)), let hostname = row.text(1), let filename = row.text(2), let byteCount = row.integer(4), let stateText = row.text(5), let state = DownloadState(rawValue: stateText), let createdAt = row.real(6) else { throw KeelStoreError.corruptData }
        return DownloadRecord(id: id, hostname: hostname, filename: filename, pathReference: row.text(3), byteCount: byteCount, state: state, createdAt: Date(timeIntervalSince1970: createdAt), completedAt: row.real(7).map(Date.init(timeIntervalSince1970:)), errorCode: row.integer(8).map(Int.init))
    }

    private static func diagnostic(_ row: SQLiteRow) throws -> DiagnosticRecord {
        guard let id = row.integer(0), let timestamp = row.real(1), let eventText = row.text(2), let eventType = DiagnosticEventType(rawValue: eventText), let hostnameText = row.text(3), let hostname = try? DiagnosticHostname(hostnameText), let resultText = row.text(4), let result = DiagnosticResult(rawValue: resultText) else { throw KeelStoreError.corruptData }
        return DiagnosticRecord(timestamp: Date(timeIntervalSince1970: timestamp), eventType: eventType, hostname: hostname, result: result, durationMilliseconds: row.integer(5).map(Int.init), errorCode: row.integer(6).map(Int.init), id: id)
    }
}

internal struct KeelStoreMigration: Sendable {
    let identifier: String
    let apply: @Sendable (SQLiteDatabase) throws -> Void
}

/// Shared internal migration seam for state and future History-owned schema changes.
internal enum KeelStoreMigrationRunner {
    static func apply(_ database: SQLiteDatabase, migrations: [KeelStoreMigration]) throws {
        try database.execute("CREATE TABLE IF NOT EXISTS keel_schema_migrations (identifier TEXT PRIMARY KEY NOT NULL, applied_at REAL NOT NULL)")
        for migration in migrations {
            guard try database.scalarText("SELECT identifier FROM keel_schema_migrations WHERE identifier = ?", values: [.text(migration.identifier)]) == nil else { continue }
            try database.transaction {
                try migration.apply(database)
                try database.execute(
                    "INSERT INTO keel_schema_migrations (identifier, applied_at) VALUES (?, ?)",
                    values: [.text(migration.identifier), .real(Date().timeIntervalSince1970)]
                )
            }
        }
    }
}

internal enum SQLiteValue {
    case integer(Int64?)
    case real(Double?)
    case text(String?)
    case blob(Data?)
}

internal struct SQLiteRow {
    let values: [SQLiteValue]
    func integer(_ index: Int) -> Int64? { if case let .integer(value) = values[index] { value } else { nil } }
    func real(_ index: Int) -> Double? { if case let .real(value) = values[index] { value } else { nil } }
    func text(_ index: Int) -> String? { if case let .text(value) = values[index] { value } else { nil } }
    func blob(_ index: Int) -> Data? { if case let .blob(value) = values[index] { value } else { nil } }
}

internal final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path(percentEncoded: false), &opened, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else { throw KeelStoreError.storageFailure }
        handle = opened
        try execute("PRAGMA foreign_keys = ON")
        _ = try rows("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA busy_timeout = 250")
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String, values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw KeelStoreError.storageFailure }
    }

    func rows(_ sql: String, values: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var result: [SQLiteRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw KeelStoreError.storageFailure }
            let values: [SQLiteValue] = (0 ..< sqlite3_column_count(statement)).map { index in
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: return SQLiteValue.integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: return SQLiteValue.real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT: return SQLiteValue.text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB:
                    guard let bytes = sqlite3_column_blob(statement, index) else { return SQLiteValue.blob(Data()) }
                    return SQLiteValue.blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))))
                default: return SQLiteValue.text(nil)
                }
            }
            result.append(SQLiteRow(values: values))
        }
    }

    func scalarText(_ sql: String, values: [SQLiteValue] = []) throws -> String? { try rows(sql, values: values).first?.text(0) }
    func scalarInteger(_ sql: String, values: [SQLiteValue] = []) throws -> Int64? { try rows(sql, values: values).first?.integer(0) }
    func scalarReal(_ sql: String, values: [SQLiteValue] = []) throws -> Double? { try rows(sql, values: values).first?.real(0) }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw KeelStoreError.storageFailure }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .integer(value): result = value.map { sqlite3_bind_int64(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
            case let .real(value): result = value.map { sqlite3_bind_double(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
            case let .text(value): result = value.map { sqlite3_bind_text(statement, index, $0, -1, SQLITE_TRANSIENT) } ?? sqlite3_bind_null(statement, index)
            case let .blob(value):
                result = value.map { data in data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), SQLITE_TRANSIENT) } } ?? sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw KeelStoreError.storageFailure }
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
