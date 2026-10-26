import SwiftUI

@main
struct CameraLUTApp: App {
    var body: some Scene {
        WindowGroup {
            CameraView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
