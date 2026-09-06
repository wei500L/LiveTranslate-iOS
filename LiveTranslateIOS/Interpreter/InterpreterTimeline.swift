import SwiftUI

// 聚焦式双语时间线（第十九轮柜台重构）。
//
// 页面主体：当前回合最清晰（Apple Music 当前歌词式聚焦 —— 但这里是
// 办事对话，不是歌词播放器），最近回合逐步降级，历史保持可读。
//
// 自动跟随状态机（数据驱动，不依赖不可控几何抖动）：
// - 底部哨兵以带滞回的阈值判定"接近底部"，只在翻转时通知 ViewModel；
// - 新回合落定且在跟随中 → 滚到底（编程式滚动期间抑制误判）；
// - 用户回看 → 暂停跟随 + "回到最新（n 条新回合）"按钮 + 未读计数；
// - 翻译完成（count 不变）不触发滚动 —— 不打断正在回看历史的用户；
// - 展开最新回合后重新贴底；展开历史回合不跳底。

/// 底部哨兵在滚动坐标系中的 Y（用于"接近底部"判定）。
private struct TimelineBottomYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct InterpreterTimeline: View {
    let viewModel: InterpreterViewModel
    /// 回合动作接线（由页面提供 —— 保持时间线不直接持有服务）。
    var onTurnActions: (InterpreterTurn) -> InterpreterTurnActions = { _ in
        InterpreterTurnActions()
    }

    @State private var lastNearBottom: Bool?
    /// "接近底部"判定阈值（pt）：内容增长一屏内仍视为贴底，
    /// 防止新回合落位瞬间被误判为用户回看。
    private let bottomThreshold: CGFloat = 160

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { outer in
                ScrollView {
                    LazyVStack(spacing: LTSpacing.s) {
                        if viewModel.turns.isEmpty {
                            emptyState
                        }
                        ForEach(Array(viewModel.turns.enumerated()), id: \.element.id) { index, turn in
                            InterpreterTurnRow(
                                turn: turn,
                                presentation: viewModel.presentation(
                                    for: turn,
                                    isTranslating: viewModel.isTranslating(turn: turn)
                                ),
                                emphasis: InterpreterTimelineLayout.emphasis(
                                    forTurnAt: index, totalCount: viewModel.turns.count
                                ),
                                isExpanded: viewModel.expandedTurnIDs.contains(turn.id),
                                availableDocumentIDs: viewModel.availableDocumentIDs,
                                actions: onTurnActions(turn)
                            )
                            .id(turn.id)
                        }
                        bottomSentinel
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.s)
                }
                .defaultScrollAnchor(.bottom)
                .coordinateSpace(name: "interpreterTimeline")
                .onPreferenceChange(TimelineBottomYKey.self) { bottomY in
                    let nearBottom = bottomY <= outer.size.height + bottomThreshold
                    if nearBottom != lastNearBottom {
                        lastNearBottom = nearBottom
                        viewModel.userScrolledTimeline(nearBottom: nearBottom)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !viewModel.follow.isFollowing {
                    resumeFollowingButton(proxy: proxy)
                }
            }
            .onChange(of: viewModel.turns.count) { oldCount, newCount in
                // 新回合落定（count 增加）才滚动；删除/翻译完成不触发。
                guard newCount > oldCount, let last = viewModel.turns.last else { return }
                if viewModel.follow.isFollowing {
                    programmaticScroll(to: last.id, proxy: proxy)
                } else {
                    viewModel.noteNewTurnLanded()
                }
            }
            .onChange(of: viewModel.expandedTurnIDs) { _, _ in
                // 展开最新回合后重新贴底（跟随中）；展开历史回合不跳底。
                guard viewModel.follow.isFollowing,
                      let last = viewModel.turns.last,
                      viewModel.expandedTurnIDs.contains(last.id) else { return }
                programmaticScroll(to: last.id, proxy: proxy)
            }
            .onTapGesture { dismissKeyboard() }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: - 底部哨兵

    private var bottomSentinel: some View {
        Color.clear
            .frame(height: 1)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TimelineBottomYKey.self,
                        value: geo.frame(in: .named("interpreterTimeline")).minY
                    )
                }
            )
            .accessibilityHidden(true)
    }

    // MARK: - 回到最新

    private func resumeFollowingButton(proxy: ScrollViewProxy) -> some View {
        Button {
            viewModel.resumeFollowing()
            if let last = viewModel.turns.last {
                programmaticScroll(to: last.id, proxy: proxy)
            }
        } label: {
            let unread = viewModel.follow.unreadCount
            Label(
                unread > 0 ? "回到最新（\(unread) 条新回合）" : "回到最新",
                systemImage: "arrow.down.circle.fill"
            )
            .font(LTTypography.interpreterStatus.weight(.medium))
            .foregroundStyle(LTColors.textPrimary)
            .padding(.horizontal, LTSpacing.m)
            .padding(.vertical, LTSpacing.s)
            .background(
                Capsule().fill(LTColors.surfaceElevated.opacity(0.95))
                    .shadow(color: LTShadow.floating, radius: 6, y: 2)
            )
            .overlay(Capsule().strokeBorder(LTColors.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(.bottom, LTSpacing.xs)
        .accessibilityLabel(
            viewModel.follow.unreadCount > 0
                ? "回到最新，\(viewModel.follow.unreadCount) 条新回合未读"
                : "回到最新"
        )
    }

    // MARK: - 编程式滚动（抑制期间的"远离底部"误判）

    private func programmaticScroll(
        to id: UUID, proxy: ScrollViewProxy
    ) {
        viewModel.isProgrammaticScrollActive = true
        withAnimation(LTMotion.quick) {
            proxy.scrollTo(id, anchor: .bottom)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            viewModel.isProgrammaticScrollActive = false
        }
    }

    private var emptyState: some View {
        LTEmptyState(
            symbol: "person.2.wave.2",
            title: "开始你们的对话",
            message: "点击下方\"听对方说\"收录对方的俄语，或直接输入中文回复。"
        )
        .padding(.top, LTSpacing.xl)
    }
}

@MainActor
private func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
    )
}
