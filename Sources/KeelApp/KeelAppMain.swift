import AppKit

@main
@MainActor
struct KeelAppMain {
    static func main() {
        let startedAt = ContinuousClock.now
        if CommandLine.arguments.contains("--performance-probe") {
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            Task { @MainActor in
                await KeelPerformanceProbe.run(startedAt: startedAt)
                application.terminate(nil)
            }
            application.run()
            return
        }
        if CommandLine.arguments.contains("--probe") {
            runOffscreenProbe()
            return
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = KeelApplicationDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    private static func runOffscreenProbe() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await FoundationProbe.run()
            application.terminate(nil)
        }
        application.run()
    }
}
