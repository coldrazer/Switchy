#if canImport(SwiftUI)
import Foundation
import MNGCore
import UserNotifications

/// Local notifications for builds that finish while the window is not in front. No network, no analytics.
enum Notifier {
    static func request() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func finished(_ job: Job) {
        let content = UNMutableNotificationContent()
        let name = job.output.map { ($0 as NSString).lastPathComponent } ?? "Your build"
        content.title = job.status == "succeeded" ? "Build finished" : "Build failed"
        if job.status == "succeeded" {
            content.body = "\(name) is ready to play."
        } else {
            content.body = "\(name): \(job.error ?? "open Builds for details")"
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                    content: content, trigger: nil))
    }
}
#endif
