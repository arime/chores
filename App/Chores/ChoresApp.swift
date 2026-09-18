import SwiftUI
import ChoresCore

@main
struct ChoresApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
                .onAppear {
                    // The token cannot arrive before parent mode asks for it,
                    // and parent mode cannot appear before the root has, so
                    // this is early enough.
                    let registrar = environment.pushRegistrar
                    delegate.onDeviceToken = { token in
                        Task { await registrar.tokenDidArrive(token) }
                    }
                }
        }
    }
}
