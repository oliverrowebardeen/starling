import StarlingChaining
import StarlingCore
import StarlingDesign
import StarlingFeatures
import SwiftUI

/// Home (ADR 0015 decision 1, mockup "Home"): the status mark and one line
/// at the top, then Needs you, In progress, and Coming up across skills.
struct HomeView: View {
    let app: AppModel
    let startNew: () -> Void
    let continueWith: (Interaction, ChainSuggestion) -> Void
    @State private var question: Interaction?

    var body: some View {
        let home = app.home
        List {
            Section {
                HStack(spacing: 12) {
                    StatusMark(state: home.pose.mark).frame(width: 36, height: 36)
                    Text(home.headline).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            if let notice = app.lifecycle.notice { NoticeSection(text: notice) }
            if let notice = app.ledgerNotice { NoticeSection(text: notice) }

            if !home.needsYou.isEmpty {
                Section {
                    ForEach(home.needsYou) { summary in needsYou(summary) }
                } header: {
                    HStack {
                        Text("Needs you")
                        Text("\(home.needsYou.count)")
                            .font(.caption.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: .capsule)
                    }
                }
            }
            if !home.inProgress.isEmpty {
                Section("In progress") {
                    ForEach(home.inProgress) { summary in
                        NavigationLink(value: summary.id) { StatusCard(summary: summary) }
                    }
                }
            }
            if !home.comingUp.isEmpty {
                Section("Coming up") {
                    ForEach(home.comingUp) { summary in
                        NavigationLink(value: PlanRoute(id: summary.id)) { comingUp(summary) }
                    }
                    // A quiet ask matched several friends: make it one plan.
                    ForEach(home.groupInvites) { invite in
                        Button {
                            app.composer.inviteMatched(invite)
                            startNew()
                        } label: {
                            Label(invite.title, systemImage: "person.3")
                        }
                    }
                }
            }
        }
        .overlay {
            if home.isEmpty { empty }
        }
        .navigationTitle("Home")
        .navigationDestination(for: InteractionID.self) { id in InteractionDetailView(app: app, id: id) }
        .navigationDestination(for: PlanRoute.self) { route in
            if let root = app.lifecycle.interaction(route.id) {
                PlanDetailView(app: app, root: root) { next in continueWith(root, next) }
            }
        }
        .sheet(item: $question) { interaction in
            NavigationStack { QuestionView(app: app, interaction: interaction) }
        }
    }

    @ViewBuilder private func needsYou(_ summary: InteractionSummary) -> some View {
        switch summary.interaction.state {
        case .proposed:
            ProposalCard(summary: summary, text: app.proposals.text(for: summary.interaction, words: app.words, basis: app.changeBasis(for: summary.interaction)), isFriend: app.words.isFriend, localPeer: app.localPeer,
                         limit: app.answerLimit(summary.interaction)) { answer in
                await app.lifecycle.answer(summary.id, with: answer)
            }
        case .awaitingOwner:
            NeedsYouCard(summary: summary) { question = summary.interaction }
        default:
            // A consent sheet is already on screen over everything.
            NeedsYouCard(summary: summary, review: nil)
        }
    }

    private func comingUp(_ summary: InteractionSummary) -> some View {
        let plan = summary.interaction.plan
        return HStack(spacing: 12) {
            PairSymbolRow(peers: plan?.attendees.peers.filter { $0 != app.localPeer } ?? [], isFriend: app.words.isFriend, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(.headline)
                if let time = plan?.time {
                    Text([app.words.chips.start(time), plan?.place?.name.rawValue].compactMap(\.self).joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Nothing yet", systemImage: "sparkles")
        } description: {
            Text((app.friends?.friends.isEmpty ?? true)
                 ? "Pair with a friend in Friends, then tap New to make a plan."
                 : "Tap New to make a plan with friends.")
        } actions: {
            Button("New plan", action: startNew).buttonStyle(.borderedProminent)
        }
    }
}

/// Navigation to a plan's detail.
struct PlanRoute: Hashable {
    let id: InteractionID
}
