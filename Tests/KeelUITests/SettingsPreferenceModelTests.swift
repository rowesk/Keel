@testable import KeelUI
import Foundation
import Testing

@Suite("Settings preference model")
struct SettingsPreferenceModelTests {
    @Test("the model defaults to system appearance, 100 percent zoom and no chosen folder")
    func defaults() {
        let model = KeelSettingsModel()

        #expect(model.appearance == .system)
        #expect(model.defaultPageZoom == .percent100)
        #expect(model.downloadDirectoryPath == nil)
        #expect(model.downloadDirectoryLabel == "Downloads")
    }

    @Test("the zoom picker offers a fixed ladder around 100 percent")
    func zoomLadder() {
        #expect(KeelPageZoom.allCases.map(\.rawValue) == [80, 90, 100, 110, 125, 150, 175, 200])
        #expect(KeelPageZoom.percent125.label == "125%")
    }

    @Test("a folder inside the home directory shows as a tilde path")
    func labelsFolderInsideHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let chosen = home.appending(path: "Documents/Reading", directoryHint: .isDirectory)
        let model = KeelSettingsModel(downloadDirectoryPath: chosen.path(percentEncoded: false))

        #expect(model.downloadDirectoryLabel == "~/Documents/Reading")
    }

    @Test("a folder outside the home directory keeps its full path")
    func labelsFolderOutsideHome() {
        let model = KeelSettingsModel(downloadDirectoryPath: "/Volumes/Archive/Keel")

        #expect(model.downloadDirectoryLabel == "/Volumes/Archive/Keel")
    }

    @Test("choosing a folder and reverting to Downloads are separate actions")
    func downloadActionsAreDistinct() {
        #expect(KeelSettingsAction.chooseDownloadDirectory != .useDefaultDownloadDirectory)
        #expect(KeelSettingsAction.setAppearance(.dark) != .setAppearance(.light))
        #expect(KeelSettingsAction.setDefaultPageZoom(.percent150) == .setDefaultPageZoom(.percent150))
    }
}
