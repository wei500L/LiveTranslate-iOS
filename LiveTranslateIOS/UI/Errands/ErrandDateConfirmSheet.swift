import SwiftUI

/// 日期确认界面：只有用户明确确认后才持久化为可提醒时间。
/// 显示原始文本、解析后的本地日期与星期、时区、是否相对日期换算、
/// 是否仍有歧义、提醒时间。不确定日期绝不自动调度。
struct ErrandDateConfirmSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let item: ErrandCaseItem
    let caseTitle: String
    let timezoneID: String

    @State private var selectedDate = Date.now
    @State private var hasTime: Bool
    @State private var reminderLead: ErrandReminderScheduler.Lead = .hour
    @State private var armReminder = true
    @State private var reminderDenied = false
    @State private var parsedCandidates: [ErrandDateParser.Candidate] = []

    init(item: ErrandCaseItem, caseTitle: String, timezoneID: String) {
        self.item = item
        self.caseTitle = caseTitle
        self.timezoneID = timezoneID
        // 初始值：已有确认时间则带出；否则本地解析候选的第一个。
        let candidates = ErrandDateParser.candidates(in: item.dateText)
        _parsedCandidates = State(initialValue: candidates)
        if let dueAt = item.dueAt {
            _selectedDate = State(initialValue: dueAt)
            _hasTime = State(initialValue: true)
        } else if let first = candidates.first(where: { $0.resolved != nil }) {
            // 只有日期没有时间：默认本地 10:00（清楚标注的本地默认
            // 值 —— 用户可改；绝不静默使用半夜）。
            _selectedDate = State(initialValue: first.resolved ?? .now)
            _hasTime = State(initialValue: first.hasTime)
        } else {
            _selectedDate = State(initialValue: .now)
            _hasTime = State(initialValue: false)
        }
    }

    private var timezone: TimeZone {
        TimeZone(identifier: timezoneID) ?? .current
    }

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.l) {
                        originalTextCard
                        candidatesCard
                        pickerCard
                        reminderCard
                        if reminderDenied {
                            deniedNotice
                        }
                        confirmButton
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                    .padding(.bottom, LTSpacing.xl)
                }
            }
            .navigationTitle("确认时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - 原文（永远保留）

    private var originalTextCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Label("原文", systemImage: "text.quote")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LTColors.textSecondary)
            Text(item.dateText.isEmpty ? "（无日期原文 —— 手动选择时间）" : item.dateText)
                .font(.body)
                .foregroundStyle(LTColors.textPrimary)
            if item.dateIsRelative {
                Text("相对日期 —— 已按来源时间与你的当前时区换算，请核对")
                    .font(.caption2)
                    .foregroundStyle(LTColors.warning)
            }
        }
        .ltCard(padding: LTSpacing.m)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 解析候选（可解释）

    private var candidatesCard: some View {
        Group {
            if !parsedCandidates.isEmpty {
                VStack(alignment: .leading, spacing: LTSpacing.s) {
                    Label("本地解析候选", systemImage: "wand.and.stars")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LTColors.textSecondary)
                    ForEach(parsedCandidates) { candidate in
                        Button {
                            if let resolved = candidate.resolved {
                                selectedDate = resolved
                                hasTime = candidate.hasTime
                            }
                        } label: {
                            HStack(alignment: .top, spacing: LTSpacing.s) {
                                Image(systemName: candidate.uncertain ? "exclamationmark.triangle" : "clock")
                                    .font(.footnote)
                                    .foregroundStyle(candidate.uncertain ? LTColors.warning : LTColors.accentBlue)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.rawText)
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(LTColors.textPrimary)
                                    Text(candidate.reason)
                                        .font(.caption2)
                                        .foregroundStyle(LTColors.textTertiary)
                                    if let resolved = candidate.resolved {
                                        Text("\(localDescription(resolved))\(resolved < .now ? " · 已在过去" : "")")
                                            .font(.caption2)
                                            .foregroundStyle(resolved < .now ? LTColors.destructive : LTColors.textSecondary)
                                    }
                                    if candidate.uncertain {
                                        Text("仍有歧义 —— 确认后才会用于提醒")
                                            .font(.caption2)
                                            .foregroundStyle(LTColors.warning)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                    }
                }
                .ltCard(padding: LTSpacing.m)
            }
        }
    }

    // MARK: - 选择器

    private var pickerCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.m) {
            Toggle(isOn: $hasTime) {
                Label("包含具体时间", systemImage: "clock")
                    .font(.footnote.weight(.medium))
            }
            .tint(LTColors.accentBlue)
            DatePicker(
                "日期",
                selection: $selectedDate,
                displayedComponents: hasTime ? [.date, .hourAndMinute] : [.date]
            )
            .datePickerStyle(.compact)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            Label("时区：\(timezone.identifier)", systemImage: "globe")
                .font(.caption2)
                .foregroundStyle(LTColors.textTertiary)
            if !hasTime {
                Text("只有日期时将按当天 10:00 处理（本地默认值，已清楚标注）")
                    .font(.caption2)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .ltCard(padding: LTSpacing.m)
    }

    // MARK: - 提醒

    private var reminderCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Toggle(isOn: $armReminder) {
                Label("创建提醒", systemImage: "bell")
                    .font(.footnote.weight(.medium))
            }
            .tint(LTColors.accentBlue)
            if armReminder {
                Picker("提醒时间", selection: $reminderLead) {
                    ForEach(ErrandReminderScheduler.Lead.allCases) { lead in
                        Text(lead.displayName).tag(lead)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .ltCard(padding: LTSpacing.m)
    }

    private var deniedNotice: some View {
        Label(
            "通知权限被拒绝 —— 时间会保存，但提醒未创建。可在系统设置中开启后回到这里。",
            systemImage: "bell.slash"
        )
        .font(.caption)
        .foregroundStyle(LTColors.warning)
    }

    // MARK: - 确认

    private var confirmButton: some View {
        Button {
            Task { await confirm() }
        } label: {
            Label("确认时间", systemImage: "checkmark.circle.fill")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(kindTint)
    }

    private var kindTint: Color {
        switch item.kind {
        case .appointment: return LTColors.accentCyan
        case .deadline: return LTColors.destructive
        case .followUp: return LTColors.warning
        default: return LTColors.accentBlue
        }
    }

    private func localDescription(_ date: Date) -> String {
        var calendar = Calendar.current
        calendar.timeZone = timezone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE HH:mm"
        formatter.timeZone = timezone
        return formatter.string(from: date)
    }

    private func confirm() async {
        guard let repository = environment.repository else { return }
        // 只有用户确认的值落库；不确定标记清除（用户已裁决）。
        var resolved = selectedDate
        if !hasTime {
            var calendar = Calendar.current
            calendar.timeZone = timezone
            resolved = calendar.date(
                bySettingHour: 10, minute: 0, second: 0, of: selectedDate
            ) ?? selectedDate
        }
        try? repository.setErrandCaseItemDate(
            item, dueAt: resolved,
            dateText: nil, isRelative: nil, uncertain: false
        )
        // 提醒（仅在用户选择创建时；被拒时如实反馈）。
        if armReminder && item.status != .unconfirmed {
            let kind: ErrandReminderScheduler.Kind
            switch item.kind {
            case .appointment: kind = .appointment
            case .deadline: kind = .deadline
            case .followUp: kind = .followUp
            default: kind = .deadline
            }
            let ok = await environment.errandReminders.enable(
                item: item, caseTitle: caseTitle, kind: kind, lead: reminderLead
            )
            reminderDenied = !ok
        } else {
            environment.errandReminders.disable(itemID: item.id)
        }
        dismiss()
    }
}
