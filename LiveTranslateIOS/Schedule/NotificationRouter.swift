import Foundation
import UIKit
import UserNotifications

/// UNUserNotificationCenterDelegate for the 上课提醒 layer. Until now the
/// app had NO notification delegate — tapping a task reminder only opened
/// the app. This delegate routes class-reminder taps (and the 开始课堂
/// notification action) into AppFlow, where HomeScreen's next-class card
/// runs the CONTROLLED start chain (microphone + resource checks, no
/// bypass).
///
/// The delegate object must outlive views — the App struct holds it in
/// @State and re-attaches the current profile's AppFlow on switches.
/// Foreground presentation is a quiet banner: a reminder firing while the
/// user is in the app stays informative, never intrusive.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// The current profile's flow. Written from the MainActor (App
    /// composition); read from notification callbacks via a hop.
    private weak var flowBox: FlowBox?

    @MainActor
    private final class FlowBox {
        weak var flow: AppFlow?
        init(flow: AppFlow?) { self.flow = flow }
    }

    @MainActor
    func attach(flow: AppFlow?) {
        flowBox = FlowBox(flow: flow)
        UNUserNotificationCenter.current().delegate = self
    }

    /// Category + action registration (idempotent). The 开始课堂 action
    /// runs the same routing as a plain tap.
    static func registerCategories() {
        let startAction = UNNotificationAction(
            identifier: ClassReminderScheduler.startActionID,
            title: "开始课堂"
        )
        let category = UNNotificationCategory(
            identifier: ClassReminderScheduler.categoryID,
            actions: [startAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Tapped while the app is FOREGROUND: a quiet banner, no sound layer.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.content.categoryIdentifier == ClassReminderScheduler.categoryID {
            completionHandler([.banner, .list])
        } else {
            completionHandler([.banner, .list, .sound])
        }
    }

    /// Tapped (foreground or background) or an action fired. The class
    /// reminder carries its occurrence key in userInfo; the route lands on
    /// the home tab with the occurrence flagged — the start flow itself
    /// (permissions, resources, duplicate guard) lives in HomeScreen's
    /// controlled chain, never here.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let category = response.notification.request.content.categoryIdentifier
        guard category == ClassReminderScheduler.categoryID,
              let occurrenceKey = userInfo[ClassReminderScheduler.occurrenceKeyUserInfo] as? String
        else {
            completionHandler()
            return
        }
        Task { @MainActor in
            // Cold start: App.onAppear attaches the flow; if the delegate
            // fires before that, the box is nil and the tap is a no-op
            // (the notification stays in Notification Center for re-tap).
            flowBox?.flow?.openClassReminder(occurrenceKey: occurrenceKey)
            completionHandler()
        }
    }
}
