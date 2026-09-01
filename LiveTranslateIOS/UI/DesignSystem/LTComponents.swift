import SwiftUI

// MARK: - Buttons

/// Primary action button: green fill, gentle press response, optional glow
/// reserved for main actions. The glow is a static soft shadow — no
/// animation loop.
struct LTPrimaryButtonStyle: ButtonStyle {
    var tint: Color = LTColors.accentGreen

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LTTypography.button)
            .foregroundStyle(Color.black.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, LTSpacing.m)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [tint.opacity(0.9), tint],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            )
            .shadow(color: tint.opacity(0.35), radius: configuration.isPressed ? 4 : 10, y: 3)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(LTMotion.quick, value: configuration.isPressed)
    }
}

/// Secondary button on dark surfaces.
struct LTSecondaryButtonStyle: ButtonStyle {
    var tint: Color = LTColors.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, LTSpacing.l)
            .padding(.vertical, LTSpacing.xs + 2)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Cards

/// Standard surface card: dark fill, hairline border, soft shadow.
struct LTCardModifier: ViewModifier {
    var padding: CGFloat = LTSpacing.m

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: LTRadius.medium)
                    .fill(LTColors.surfacePrimary.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LTRadius.medium)
                    .strokeBorder(LTColors.border, lineWidth: 0.5)
            )
            .shadow(color: LTShadow.card, radius: 8, y: 3)
    }
}

extension View {
    func ltCard(padding: CGFloat = LTSpacing.m) -> some View {
        modifier(LTCardModifier(padding: padding))
    }
}

// MARK: - Section header

/// Section heading used across screens: small caps-ish caption with an
/// optional trailing action.
struct LTSectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LTColors.textSecondary)
                .textCase(.uppercase)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(LTColors.accentBlue)
            }
        }
    }
}

// MARK: - Icon badge

/// Rounded-square icon container with a course-stable tint, used on
/// classroom cards.
struct LTIconBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3)
                    .fill(tint.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3)
                    .strokeBorder(tint.opacity(0.3), lineWidth: 0.5)
            )
    }
}

// MARK: - Empty state

struct LTEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: LTSpacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(LTColors.textTertiary)
            Text(title)
                .font(LTTypography.cardTitle)
                .foregroundStyle(LTColors.textPrimary)
            Text(message)
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LTSpacing.xl)
        .padding(.horizontal, LTSpacing.l)
    }
}

// MARK: - Activity indicator

/// Pulsing dot that mirrors live listening/audio activity. State-driven:
/// the parent passes the real activity boolean; with Reduce Motion the
/// pulse is dropped for a steady dot.
struct LTActivityDot: View {
    var active: Bool
    var tint: Color = LTColors.accentGreen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
            .shadow(color: tint.opacity(active ? 0.8 : 0), radius: active ? 5 : 0)
            .scaleEffect(active && !reduceMotion ? 1.15 : 1.0)
            .animation(
                reduceMotion ? nil : Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: active
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Floating tab bar

/// The five global tabs. Reference order: 首页 · 课堂记录 · 书签 · 搜索 · 我的.
enum LTTab: String, CaseIterable, Identifiable {
    case home, records, bookmarks, search, profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .records: return "课堂记录"
        case .bookmarks: return "书签"
        case .search: return "搜索"
        case .profile: return "我的"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .records: return "list.bullet.rectangle.fill"
        case .bookmarks: return "bookmark.fill"
        case .search: return "magnifyingglass"
        case .profile: return "person.crop.circle.fill"
        }
    }

    var symbolOutline: String {
        switch self {
        case .home: return "house"
        case .records: return "list.bullet.rectangle"
        case .bookmarks: return "bookmark"
        case .search: return "magnifyingglass"
        case .profile: return "person.crop.circle"
        }
    }
}

/// Floating translucent tab bar: dark material, hairline border, green
/// selection with a controlled glow. Hidden while a live classroom is
/// presented (the classroom provides its own internal toolbar).
struct LTFloatingTabBar: View {
    @Binding var selection: LTTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LTTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(LTSpacing.xxs)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(Capsule().strokeBorder(LTColors.border, lineWidth: 0.5))
        .background(Capsule().fill(LTColors.surfaceElevated.opacity(0.55)))
        .shadow(color: LTShadow.floating, radius: 12, y: 5)
        .padding(.horizontal, LTSpacing.screenPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("主导航"))
    }

    private func tabButton(_ tab: LTTab) -> some View {
        let isSelected = selection == tab
        return Button {
            withAnimation(LTMotion.resolved(reduceMotion)) { selection = tab }
            LTHaptics.tap()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: isSelected ? tab.symbol : tab.symbolOutline)
                    .font(.system(size: 17, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(tab.title)
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(isSelected ? LTColors.accentGreen : LTColors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, LTSpacing.xs)
            .background {
                if isSelected {
                    Capsule()
                        .fill(LTColors.accentGreen.opacity(0.14))
                        .shadow(color: LTColors.accentGreen.opacity(0.25), radius: 6)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tab.title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
