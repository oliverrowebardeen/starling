import SwiftUI

/// The animated Overlap mark. Shape A is you, shape B is the other person.
///
/// Changing `state` moves the shapes from wherever they are toward the new
/// state's pose. A match ends in the logo pose, the same as the app icon. Under
/// Reduce Motion the mark crossfades between still poses instead.
public struct StatusMark: View {
    private let state: MarkState
    private let reduceMotionOverride: Bool?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var transition: MarkTransition
    @State private var settled = false

    /// - Parameter reduceMotion: overrides the system setting, for previews.
    public init(state: MarkState, reduceMotion: Bool? = nil) {
        self.state = state
        self.reduceMotionOverride = reduceMotion
        _transition = State(initialValue: MarkTransition(resting: state))
    }

    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    public var body: some View {
        let reduceMotion = reduceMotion
        let palette = MarkPalette.forScheme(colorScheme)
        ZStack {
            TimelineView(.animation(paused: settled)) { context in
                MarkGlyph(
                    frame: transition.frame(at: context.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion),
                    palette: palette
                )
            }
            // Under Reduce Motion each state is its own view, so a state change is a crossfade.
            .id(reduceMotion ? transition.target : nil)
            .transition(.opacity)
        }
        .onChange(of: state) { _, newState in
            let next = transition.retargeted(to: newState, at: Date.now.timeIntervalSinceReferenceDate)
            settled = false
            if reduceMotion {
                withAnimation(.easeInOut(duration: MarkTransition.crossfadeDuration)) { transition = next }
            } else {
                transition = next
            }
        }
        .task(id: SettleKey(transition: transition, reduceMotion: reduceMotion)) {
            settled = false
            guard let settleTime = transition.settleTime(reduceMotion: reduceMotion) else { return }
            let wait = settleTime - Date.now.timeIntervalSinceReferenceDate
            if wait > 0 {
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            }
            settled = true
        }
        .accessibilityElement()
        .accessibilityLabel(Text(state.accessibilityLabel))
    }

    private struct SettleKey: Equatable {
        let transition: MarkTransition
        let reduceMotion: Bool
    }
}

/// Steps through the states, for previews. A nil `reduceMotion` follows the system setting.
private struct StatusMarkDemo: View {
    let reduceMotion: Bool?
    @State private var state = MarkState.idle

    var body: some View {
        VStack(spacing: 16) {
            StatusMark(state: state, reduceMotion: reduceMotion)
                .frame(width: 160, height: 160)
            Picker("State", selection: $state) {
                ForEach(MarkState.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding()
    }
}

#Preview("States") {
    StatusMarkDemo(reduceMotion: nil)
}

#Preview("States, dark") {
    StatusMarkDemo(reduceMotion: nil)
        .background(MarkPalette.dark.background.color)
        .environment(\.colorScheme, .dark)
}

#Preview("Reduce Motion forced on") {
    StatusMarkDemo(reduceMotion: true)
}

#Preview("Every state") {
    HStack(spacing: 12) {
        ForEach(MarkState.allCases, id: \.self) { state in
            VStack {
                StatusMark(state: state).frame(width: 64, height: 64)
                Text(state.rawValue).font(.caption)
            }
        }
    }
    .padding()
}
