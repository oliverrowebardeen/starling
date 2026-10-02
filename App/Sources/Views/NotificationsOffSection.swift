import StarlingFeatures
import SwiftUI
import UIKit

/// A quiet line in You when the owner turned Starling's notifications off
/// in iOS (ADR 0260). Starling cannot ask again, so it offers Settings
/// instead. Nothing shows while they are on or not asked yet.
struct NotificationsOffSection: View {
    let app: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        if app.notificationAccess == .denied {
            Section {
                LabeledContent {
                    Button("Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                } label: {
                    Label("Notifications are off", systemImage: "bell.slash")
                }
            } footer: {
                Text("You won't hear when a friend wants to make plans. Turn them on in Settings.")
            }
        }
    }
}
