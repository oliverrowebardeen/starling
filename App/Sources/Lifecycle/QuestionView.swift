import StarlingCore
import StarlingDesign
import StarlingFeatures
import SwiftUI

/// The agent's one question to its owner (the "Just ask me" fallback, or a
/// friend's request such as "when are you free next week?"). The owner
/// picks from typed candidates; the answer names the question's revision,
/// so it can never answer a newer one (ADR 0011 decision 10).
struct QuestionView: View {
    let app: AppModel
    let interaction: Interaction
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<Int> = []
    @State private var flag = true

    private var question: SkillQuestion? { interaction.pendingQuestion }
    private var chips: ChipFormatter { app.words.chips }

    var body: some View {
        Form {
            if let question {
                Section {
                    Text(app.words.question(interaction)).font(.headline)
                    Text("Your agent shares only what you pick here.").font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    options(question.candidates)
                }
                Section {
                    Button("Send my answer") { Task { await reply(question) } }
                        .disabled(answer(question) == nil)
                    Button("Not now", role: .destructive) {
                        Task {
                            await app.lifecycle.answer(interaction.id, with: .pass)
                            dismiss()
                        }
                    }
                } footer: {
                    Text("If you pass, they just won't see it.")
                }
            } else {
                Text("This was already answered.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(app.words.summary(interaction)?.tag ?? "Question")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func options(_ candidates: IssueValue) -> some View {
        switch candidates {
        case .slots(let slots):
            ForEach(Array(slots.sorted().enumerated()), id: \.offset) { index, slot in
                Toggle(chips.slot(slot), isOn: binding(index))
            }
        case .keywords(let words):
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Toggle(word.value.capitalized, isOn: binding(index))
            }
        case .places(let places):
            ForEach(Array(places.enumerated()), id: \.offset) { index, place in
                Button {
                    chosen = [index]
                } label: {
                    HStack {
                        Text(place.name.rawValue).foregroundStyle(.primary)
                        Spacer()
                        if chosen.contains(index) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
            }
        case .flag:
            Toggle("Yes", isOn: $flag)
        case .amount(let amount):
            Text(app.services.formatter.money(amount))
        case .count(let count):
            Text(String(count))
        case .peers(let peers):
            ForEach(RosterRow.rows(for: peers, friends: friendNames, me: app.localPeer)) { RosterRowView(row: $0) }
        }
    }

    private var friendNames: [PeerID: String] {
        Dictionary((app.friends?.friends ?? []).map { ($0.id, $0.nickname) }, uniquingKeysWith: { first, _ in first })
    }

    private func binding(_ index: Int) -> Binding<Bool> {
        Binding(get: { chosen.contains(index) }, set: { if $0 { chosen.insert(index) } else { chosen.remove(index) } })
    }

    /// Only values from the candidates, so the answer can never carry more
    /// than the question offered.
    private func answer(_ question: SkillQuestion) -> IssueValue? {
        switch question.candidates {
        case .slots(let slots):
            let picked = slots.sorted().enumerated().filter { chosen.contains($0.offset) }.map(\.element)
            return picked.isEmpty ? nil : .slots(picked)
        case .keywords(let words):
            let picked = words.enumerated().filter { chosen.contains($0.offset) }.map(\.element)
            return picked.isEmpty ? nil : .keywords(picked)
        case .places(let places):
            let picked = places.enumerated().filter { chosen.contains($0.offset) }.map(\.element)
            return picked.isEmpty ? nil : .places(picked)
        case .flag: return .flag(flag)
        case .amount, .count, .peers: return question.candidates
        }
    }

    private func reply(_ question: SkillQuestion) async {
        guard let value = answer(question) else { return }
        await app.lifecycle.answer(interaction.id, with: .reply(question: question.revision, value))
        dismiss()
    }
}
