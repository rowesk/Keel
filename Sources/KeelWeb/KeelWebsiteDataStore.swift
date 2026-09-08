import WebKit

@MainActor
public enum KeelWebsiteDataStore {
    private static let persistentDataStore = WKWebsiteDataStore.default()

    public static var shared: WKWebsiteDataStore {
        persistentDataStore
    }
}
