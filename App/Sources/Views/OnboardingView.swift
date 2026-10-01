import StarlingFeatures
import SwiftUI

/// First run: what this build is, Local Network, notifications, rules.
struct OnboardingView: View {
    @State var model: OnboardingModel
    let rules: RulesEditorModel
    let onFinish: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch model.step {
                case .welcome:
                    Page(
                        symbol: "bird",
                        title: "Welcome to Starling",
                        text: "Your agent lives on this iPhone. When you're up for something, it quietly checks with your friends' agents and tells you only when someone's up for the same thing.",
                        note: "This is a test build. Things will break, and Starling makes no privacy promises until its security has been reviewed. Don't put anything sensitive in it.",
                        primary: "Continue",
                        action: next
                    )
                case .localNetwork:
                    Page(
                        symbol: "wifi",
                        title: "Find friends nearby",
                        text: "Starling talks to your friends' phones directly, without a server. Next, iOS will ask to let Starling find devices on your local network. Tap Allow, or Starling can't reach your friends.",
                        note: "You can change this later in Settings, Privacy & Security, Local Network.",
                        primary: model.isWorking ? "Waiting for your answer..." : "Continue",
                        action: next
                    )
                case .notifications:
                    Page(
                        symbol: "bell.badge",
                        title: "Only real matches",
                        text: "Starling notifies you only when a friend is up for the same thing as you. One-sided interest never notifies you or them.",
                        note: nil,
                        primary: "Allow notifications",
                        secondary: "Not now",
                        action: next,
                        skip: model.skip
                    )
                case .rules:
                    RulesEditorView(model: rules)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(rules.saved == nil ? "Skip" : "Done") { Task { await model.next() } }
                                    .disabled(rules.phase == .reviewing || rules.phase == .interpreting)
                            }
                        }
                }
            }
            .disabled(model.isWorking)
        }
        .onChange(of: model.isFinished) { _, finished in
            if finished { onFinish() }
        }
    }

    private func next() {
        Task { await model.next() }
    }
}

private struct Page: View {
    let symbol: String
    let title: String
    let text: String
    let note: String?
    let primary: String
    var secondary: String?
    let action: () -> Void
    var skip: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text(text).font(.body).multilineTextAlignment(.center)
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(.quaternary, in: .rect(cornerRadius: 12))
            }
            Spacer()
            Button(action: action) {
                Text(primary).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if let secondary, let skip {
                Button(secondary, action: skip)
            }
        }
        .padding(24)
    }
}

#if DEBUG
#Preview {
    @Previewable @State var app = PreviewSupport.app()
    OnboardingView(model: app.makeOnboarding(), rules: app.rulesEditor, onFinish: {})
}
#endif
