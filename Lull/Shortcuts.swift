import AppIntents

/// Lull's actions in Siri, Spotlight and the Shortcuts app.
struct LullShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartNightIntent(),
            phrases: ["Start my night in \(.applicationName)", "Start \(.applicationName)"],
            shortTitle: "Start Night",
            systemImageName: "moon.stars.fill"
        )
        AppShortcut(
            intent: OpenLullIntent(tab: .remote),
            phrases: ["Open the \(.applicationName) remote"],
            shortTitle: "Remote",
            systemImageName: "dial.medium.fill"
        )
    }
}
