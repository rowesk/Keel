import Foundation

public struct KeelDownloadModel: Equatable, Sendable {
    public let items: [KeelDownloadItem]
    public let itemIDs: [UUID]

    public init(items: [KeelDownloadItem] = []) {
        let sortedItems = items.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.id.uuidString > $1.id.uuidString
        }
        self.items = sortedItems
        self.itemIDs = sortedItems.map(\.id)
    }

    public var isEmpty: Bool {
        items.isEmpty
    }

    public static func fixture(count: Int) -> KeelDownloadModel {
        let safeCount = max(0, count)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let items = (0..<safeCount).map { index in
            KeelDownloadItem(
                id: UUID(),
                hostname: "files.example.test",
                filename: "document-\(index).pdf",
                path: "/Users/example/Downloads/document-\(index).pdf",
                receivedBytes: Int64(index + 1) * 1_000,
                expectedBytes: 100_000,
                status: index.isMultiple(of: 3) ? .inProgress : .completed,
                createdAt: now.addingTimeInterval(TimeInterval(-index)),
                bytesPerSecond: 420_000
            )
        }
        return KeelDownloadModel(items: items)
    }
}
