import SwiftUI
import EventKit

/// 系统日历选择 — the restrained EventKit flow: write-only permission,
/// the user picks the destination calendar (any account, including a
/// Google calendar connected to Apple Calendar), the mirror never
/// duplicates and the app stays the source of truth.
struct ExamCalendarPickerScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let exam: Exam
    let courseName: String?

    @State private var calendars: [EKCalendar] = []
    @State private var isDenied = false
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.l) {
                        VStack(alignment: .leading, spacing: LTSpacing.xs) {
                            LTSectionHeader(title: "加入系统日历")
                            Text("考试仍以 LiveTranslate 为准；日历只是一个镜像，可随时移除。可以选任何支持写入的日历（包括绑定到 Apple 日历的 Google 账号）。")
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.textTertiary)
                        }
                        .ltCard()
                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, LTSpacing.l)
                        } else if isDenied {
                            VStack(alignment: .leading, spacing: LTSpacing.s) {
                                LTEmptyState(
                                    symbol: "calendar.badge.exclamationmark",
                                    title: "没有日历权限",
                                    message: "可以在系统设置中开启；不影响 App 内的考试和学习计划"
                                )
                            }
                        } else {
                            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                                LTSectionHeader(title: "选择日历")
                                ForEach(calendars, id: \.calendarIdentifier) { calendar in
                                    Button {
                                        mirror(to: calendar)
                                    } label: {
                                        HStack(spacing: LTSpacing.s) {
                                            Circle()
                                                .fill(Color(cgColor: calendar.cgColor))
                                                .frame(width: 12, height: 12)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(calendar.title)
                                                    .font(.subheadline)
                                                    .foregroundStyle(LTColors.textPrimary)
                                                Text(calendar.source.title)
                                                    .font(LTTypography.caption)
                                                    .foregroundStyle(LTColors.textTertiary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption2)
                                                .foregroundStyle(LTColors.textTertiary)
                                        }
                                        .padding(LTSpacing.s)
                                        .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary.opacity(0.6)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .ltCard()
                        }
                        if ExamCalendarService.shared.hasMirroredEvent(examID: exam.id) {
                            Button(role: .destructive) {
                                ExamCalendarService.shared.removeMirroredEvent(examID: exam.id)
                                dismiss()
                            } label: {
                                Label("移除日历中的镜像事件", systemImage: "trash")
                                    .font(.footnote.weight(.medium))
                                    .frame(maxWidth: .infinity, minHeight: LTSpacing.minTouchTarget)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(LTColors.destructive)
                        }
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                    .padding(.bottom, LTSpacing.xl)
                }
            }
            .navigationTitle("系统日历")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                calendars = await ExamCalendarService.shared.writableCalendars() ?? []
                isDenied = calendars.isEmpty
                isLoading = false
            }
        }
    }

    private func mirror(to calendar: EKCalendar) {
        Task {
            _ = await ExamCalendarService.shared.mirror(
                exam: exam, courseName: courseName, calendar: calendar
            )
            LTHaptics.success()
            dismiss()
        }
    }
}
