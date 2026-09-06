import Foundation
import UIKit
import UserNotifications

/// UNUserNotificationCenterDelegate for the notification layers. Routes
/// class-reminder, exam-reminder and study-plan taps into AppFlow, where
/// the target screens run the CONTROLLED chains (permission and resource
/// checks, no bypass).
///
/// The delegate object must outlive views — the App struct holds it in
/// @State and re-attaches the current profile's AppFlow on switches.
/// Foreground presentation is a quiet banner: a reminder firing while the
/// user is in the app stays informative, never intrusive.
///
/// Isolation: the router is @MainActor (its only state is the MainActor
/// flow box). The sync `willPresent` requirement is nonisolated and never
/// touches that state; the tap handler uses the ASYNC `didReceive`
/// overload (iOS 15+) so its MainActor isolation is the hop itself — no
/// completion-handler closure crosses domains.
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// The current profile's flow (written on attach, read on taps).
    private weak var flowBox: FlowBox?

    private final class FlowBox {
        weak var flow: AppFlow?
        init(flow: AppFlow?) { self.flow = flow }
    }

    func attach(flow: AppFlow?) {
        flowBox = FlowBox(flow: flow)
        UNUserNotificationCenter.current().delegate = self
    }

    /// Category + action registration (idempotent). The 开始课堂 action
    /// runs the same routing as a plain tap.
    nonisolated static func registerCategories() {
        let startAction = UNNotificationAction(
            identifier: ClassReminderScheduler.startActionID,
            title: "开始课堂"
        )
        let classCategory = UNNotificationCategory(
            identifier: ClassReminderScheduler.categoryID,
            actions: [startAction],
            intentIdentifiers: [],
            options: []
        )
        let examCategory = UNNotificationCategory(
            identifier: ExamReminderScheduler.categoryID,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let studyCategory = UNNotificationCategory(
            identifier: ExamReminderScheduler.studyCategoryID,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let errandCategory = UNNotificationCategory(
            identifier: ErrandReminderScheduler.categoryID,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories(
            [classCategory, examCategory, studyCategory, errandCategory]
        )
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Tapped while the app is FOREGROUND: a quiet banner, no sound layer.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let category = notification.request.content.categoryIdentifier
        if category == ClassReminderScheduler.categoryID
            || category == ExamReminderScheduler.categoryID
            || category == ExamReminderScheduler.studyCategoryID
            || category == ErrandReminderScheduler.categoryID {
            completionHandler([.banner, .list])
        } else {
            completionHandler([.banner, .list, .sound])
        }
    }

    /// Tapped (foreground or background) or an action fired. Each
    /// category carries its route target in userInfo; the landing screen
    /// resolves it against the live store (a deleted row shows 来源已不存在
    /// instead of a dead screen).
    ///
    /// nonisolated (the response parameters are not Sendable, so the
    /// implementation may not be actor-isolated): the Sendable routing
    /// values are extracted first, then the routing itself hops to the
    /// main actor.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let category = response.notification.request.content.categoryIdentifier

        let classKey = userInfo[ClassReminderScheduler.occurrenceKeyUserInfo] as? String
        let examIDString = userInfo[ExamReminderScheduler.examIDUserInfo] as? String
        let examID = examIDString.flatMap(UUID.init(uuidString:))
        let errandCaseIDString = userInfo[ErrandReminderScheduler.caseIDUserInfo] as? String
        let errandCaseID = errandCaseIDString.flatMap(UUID.init(uuidString:))

        await MainActor.run {
            // Cold start: App.onAppear attaches the flow; if the delegate
            // fires before that, the box is nil and the tap is a no-op
            // (the notification stays in Notification Center for re-tap).
            switch category {
            case ClassReminderScheduler.categoryID:
                if let classKey {
                    flowBox?.flow?.openClassReminder(occurrenceKey: classKey)
                }
            case ExamReminderScheduler.categoryID:
                if let examID {
                    flowBox?.flow?.openExamReminder(examID: examID)
                }
            case ExamReminderScheduler.studyCategoryID:
                flowBox?.flow?.openStudyPlanReminder()
            case ErrandReminderScheduler.categoryID:
                // The case may have been deleted since scheduling — the
                // landing screen shows the honest 事项已不存在 state.
                if let errandCaseID {
                    flowBox?.flow?.openErrandCaseReminder(caseID: errandCaseID)
                }
            default:
                break
            }
        }
    }
}
