import StarlingCore
import StarlingFeatures
import SwiftUI

/// Starling's own sheet before a system permission alert (ADR 0013,
/// approved by Oliver): what the agent reads, what never leaves the phone,
/// what friends see, and one "Continue" button with no cancel, as the HIG
/// asks. The system alert that follows is where the owner says no.
struct PrePermissionSheet: View {
    let explanation: PermissionExplanation
    let proceed: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: Self.symbol(explanation.permission))
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 16))
                .accessibilityHidden(true)
            Text(explanation.title).font(.title.bold())
            Text(explanation.body)
            VStack(spacing: 0) {
                ForEach(Array(explanation.rows.enumerated()), id: \.offset) { index, row in
                    LabeledContent(row.title) {
                        Text(row.detail ?? "").fontWeight(.semibold).multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 12)
                    if index < explanation.rows.count - 1 { Divider() }
                }
            }
            .padding(.horizontal, 16)
            .background(.fill.quaternary, in: .rect(cornerRadius: 16))
            Spacer(minLength: 0)
            Button(action: proceed) {
                Text(PermissionExplanation.continueLabel).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text(explanation.footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .presentationDetents([.large])
        .interactiveDismissDisabled()
    }

    static func symbol(_ permission: SystemPermission) -> String {
        switch permission {
        case .calendarFullAccess: "calendar"
        case .locationWhenInUse: "location"
        case .photoLibrary: "photo.on.rectangle"
        }
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        PrePermissionSheet(
            explanation: .make(.calendarFullAccess, skill: try! SkillDescriptor(
                ref: SkillRef(.findATime, SkillVersion(1)),
                wording: SkillWording(name: "Find a time", summary: "Agree on when", startAction: "Find a time", acceptAction: "That works", declineAction: "Not then", declineNote: "If you pass, they just won't see it."),
                buildingBlock: .privateQuery, topicsUsed: [.time], topicsRequired: [.time], produces: [.timeSlot],
                intent: IntentSchema(slots: [IntentSlot(.time, required: true, hint: "when")])
            ), friends: ["Priya"]),
            proceed: {}
        )
    }
}
