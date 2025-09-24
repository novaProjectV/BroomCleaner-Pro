import SwiftUI

@main
struct BroomCleaner_ProApp: App {
    var body: some Scene {
        WindowGroup {
            CleanerView()
        }
        Settings {                // ← без точки перед Settings
            SettingsView()
                .frame(minWidth: 700, minHeight: 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .defaultSize(width: 700, height: 560)
    }
}

