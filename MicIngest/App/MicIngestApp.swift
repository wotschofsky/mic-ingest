import SwiftUI

@main
struct MicIngestApp: App {
    /// nil while hosting unit tests, where the app's own services must stay out of the way.
    private let startup: Result<AppEnvironment, Error>?

    init() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            startup = nil
        } else {
            startup = Result { try AppEnvironment() }
        }
    }

    var body: some Scene {
        Window(AppConfig.appName, id: "main") {
            switch startup {
            case .success(let environment):
                RootView(environment: environment)
                    .environment(environment.source)
                    .environment(environment.imports)
                    .environment(environment.library)
                    .environment(environment.people)
                    .defaultAppStorage(environment.settings.defaults)
            case .failure(let error):
                ContentUnavailableView("Could not open the app database", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            case nil:
                EmptyView()
            }
        }
        .defaultSize(width: 980, height: 680)

        Settings {
            if case .success(let environment) = startup {
                SettingsView(environment: environment)
                    .environment(environment.people)
            }
        }
    }
}
