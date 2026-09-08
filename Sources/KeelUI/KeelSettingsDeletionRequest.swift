import Foundation

public enum KeelSettingsDeletionRequest: Equatable, Sendable {
    case diagnostics
    /// The name travels with the id so the dialog can name the photograph
    /// after the tile it came from has stopped being under the pointer.
    case removeHomeScene(KeelHomeSceneID, String)

    public var confirmationTitle: String {
        switch self {
        case .diagnostics:
            "Delete diagnostics?"
        case .removeHomeScene(_, let name):
            "Remove \u{201C}\(name)\u{201D} from Home?"
        }
    }

    public var confirmationMessage: String {
        switch self {
        case .diagnostics:
            "This removes Keel's local diagnostic records. Downloaded files and browsing data stay intact."
        case .removeHomeScene:
            "Keel deletes its copy. Your original file is untouched."
        }
    }

    /// The verb on the destructive button.
    public var confirmTitle: String {
        switch self {
        case .diagnostics: "Delete diagnostics"
        case .removeHomeScene: "Remove"
        }
    }
}
