import SwiftUI

/// Centralized design system for LiveTranslate.
///
/// The reference designs are a quiet, dark navy classroom interface with a
/// restrained green accent. All colors, type ramp, spacing, radii, shadows
/// and motion live here — screens must not scatter literal values.
///
/// The app commits to a dark presentation (`.preferredColorScheme(.dark)` on
/// the root), so these tokens are fixed dark values rather than adaptive
/// light/dark pairs.

// MARK: - Colors

enum LTColors {
    /// Deep black-blue page background (gradient start).
    static let backgroundPrimary = Color(red: 0.040, green: 0.055, blue: 0.102)
    /// Slightly lifted deep blue-gray (gradient end / secondary background).
    static let backgroundSecondary = Color(red: 0.055, green: 0.078, blue: 0.145)
    /// Primary card surface.
    static let surfacePrimary = Color(red: 0.082, green: 0.110, blue: 0.192)
    /// Floating toolbars and elevated controls.
    static let surfaceElevated = Color(red: 0.118, green: 0.153, blue: 0.255)

    /// OK / running / local-available accent (the reference green).
    static let accentGreen = Color(red: 0.200, green: 0.820, blue: 0.480)
    /// Recognition / audio activity accent.
    static let accentCyan = Color(red: 0.400, green: 0.820, blue: 0.980)
    /// Links and auxiliary states.
    static let accentBlue = Color(red: 0.290, green: 0.620, blue: 1.000)
    /// End-classroom and severe errors.
    static let destructive = Color(red: 1.000, green: 0.298, blue: 0.310)
    /// Transient / paused warning.
    static let warning = Color(red: 1.000, green: 0.760, blue: 0.290)

    static let textPrimary = Color(red: 0.949, green: 0.961, blue: 0.980)
    static let textSecondary = Color(red: 0.604, green: 0.647, blue: 0.722)
    static let textTertiary = Color(red: 0.388, green: 0.431, blue: 0.518)

    static let separator = Color.white.opacity(0.08)
    /// Hairline card border.
    static let border = Color.white.opacity(0.10)
}

// MARK: - Typography

/// System-font text ramp. All styles scale with Dynamic Type; nothing here
/// fixes a point size, so Chinese, Russian and math glyphs all render in the
/// system default fonts.
enum LTTypography {
    /// Screen large title (home greeting area).
    static let pageTitle = Font.title2.weight(.bold)
    /// Session / card titles.
    static let cardTitle = Font.headline
    /// The *current* Chinese translation in the live classroom — first
    /// visual hierarchy, largest flowing text on screen.
    static let liveCurrentTranslation = Font.title3.weight(.semibold)
    /// Completed Chinese translations.
    static let liveTranslation = Font.callout
    /// Russian source text — second hierarchy.
    static let liveOriginal = Font.subheadline
    /// Auxiliary explanation.
    static let caption = Font.footnote
    /// General body text (reader paragraphs, form copy). NOTE: this was
    /// referenced by CourseDetailView/ScheduleScreen before it existed
    /// (a latent break from an unverified round) — defined here now.
    static let body = Font.subheadline
    /// Timestamps and status chips.
    static let timestamp = Font.caption2.monospacedDigit()
    static let statusChip = Font.caption2.weight(.medium)
    /// Primary action button label.
    static let button = Font.headline
}

// MARK: - Spacing / radius

enum LTSpacing {
    static let xxs: CGFloat = 3
    static let xs: CGFloat = 6
    static let s: CGFloat = 10
    static let m: CGFloat = 14
    static let l: CGFloat = 20
    static let xl: CGFloat = 28
    /// Horizontal page padding.
    static let screenPadding: CGFloat = 20
    /// Vertical clearance reserved below tab content for the floating
    /// global tab bar (bar height + gap + home-indicator breathing room).
    static let tabBarReserve: CGFloat = 74
    /// Minimum touch target for standalone icon buttons (HIG).
    static let minTouchTarget: CGFloat = 44
}

enum LTRadius {
    static let small: CGFloat = 10
    static let medium: CGFloat = 14
    static let large: CGFloat = 20
    static let pill: CGFloat = 999
}

// MARK: - Shadow

enum LTShadow {
    /// Soft card shadow.
    static let card = Color.black.opacity(0.35)
    /// Shadow used under floating chrome (tab bar, live controls).
    static let floating = Color.black.opacity(0.5)
}

// MARK: - Motion

/// Motion tokens. Everything is state-driven; `reducedMotion` callers swap
/// springs for opacity-only fades.
enum LTMotion {
    static let quick = Animation.easeOut(duration: 0.18)
    static let standard = Animation.spring(response: 0.35, dampingFraction: 0.86)
    static let focus = Animation.spring(response: 0.45, dampingFraction: 0.9)
    /// Text reveal for streamed translation text.
    static let textReveal = Animation.easeOut(duration: 0.25)

    /// The animation to use for the given reduce-motion preference
    /// (nil = no movement, only state changes).
    static func resolved(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : LTMotion.standard
    }
}

// MARK: - Background

/// The app-wide deep navy gradient with a very restrained green ambient
/// glow. Drawn once per screen; no per-frame work.
struct LTBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [LTColors.backgroundSecondary, LTColors.backgroundPrimary],
                startPoint: .top, endPoint: .bottom
            )
            // Faint green environment light, top center — the reference's
            // "quiet classroom" ambience. Deliberately low opacity so text
            // contrast is unaffected.
            RadialGradient(
                colors: [LTColors.accentGreen.opacity(0.10), .clear],
                center: UnitPoint(x: 0.5, y: 0.0),
                startRadius: 10,
                endRadius: 480
            )
        }
        .ignoresSafeArea()
    }
}

/// Standard page container: background + padded content column.
struct LTPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            LTBackground()
            content()
        }
    }
}

// MARK: - Iconography

/// Stable icon derivation: the same classroom name always maps to the same
/// tint + SF Symbol, so repeated courses read as consistent identity.
enum LTIconography {
    private static let symbols = [
        "book.fill", "function", "atom", "flask.fill", "square.grid.3x3.fill",
        "globe.asia.australia.fill", "square.and.pencil", "lightbulb.fill",
        "leaf.fill", "antenna.radiowaves.left.and.right", "heart.text.square.fill",
        "briefcase.fill",
    ]
    private static let tints: [Color] = [
        .cyan, .mint, .orange, .teal, .indigo, .purple, .pink, .blue, .green, .yellow,
    ]

    /// djb2 over unicode scalars — stable across launches (unlike
    /// `String.hashValue`, which is randomly seeded per process).
    private static func stableHash(_ name: String) -> Int {
        var hash: UInt64 = 5381
        for scalar in name.unicodeScalars {
            hash = (hash &<< 5) &+ hash &+ UInt64(scalar.value)
        }
        return Int(hash % 1_000_003)
    }

    static func symbol(for name: String) -> String {
        symbols[abs(stableHash(name)) % symbols.count]
    }

    static func tint(for name: String) -> Color {
        tints[abs(stableHash(name)) % tints.count]
    }
}

/// Fixed course color palette. `Course.colorIndex` (synced as a plain int)
/// indexes into this; unknown indices fall back to the first color so a
/// future palette change never renders a course colorless.
enum LTCoursePalette {
    static let colors: [Color] = [
        .cyan, .mint, .orange, .indigo, .pink, .yellow, .teal, .purple,
    ]

    static func color(_ index: Int) -> Color {
        guard !colors.isEmpty else { return .cyan }
        return colors[abs(index) % colors.count]
    }
}

// MARK: - Haptics

/// Central wrapper so haptic usage stays discoverable and testable.
@MainActor
enum LTHaptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
