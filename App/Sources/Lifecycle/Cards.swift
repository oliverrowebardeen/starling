import StarlingCore
import StarlingDesign
import StarlingFeatures
import SwiftUI

extension StatusPose {
    var mark: MarkState {
        switch self {
        case .idle: .idle
        case .searching: .searching
        case .negotiating: .negotiating
        case .match: .match
        case .noMatch: .noMatch
        }
    }
}

/// The skill's name in a small capsule: "Down for boba", "Find a time".
struct SkillTag: View {
    let text: String
    var muted = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(muted ? Color.secondary : Color.accentColor)
            .background(muted ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.12), in: .capsule)
    }
}

/// Friends' pair symbols in a row, decorative beside their names. Anyone
/// not paired gets a question mark: their symbol would be chosen by
/// whoever sent their ID.
struct PairSymbolRow: View {
    let peers: [PeerID]
    let isFriend: (PeerID) -> Bool
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: 4) {
            ForEach(peers.prefix(5), id: \.self) { peer in
                Group {
                    if isFriend(peer) {
                        PairSymbol(seed: peer.bytes)
                    } else {
                        Image(systemName: "questionmark").foregroundStyle(.secondary)
                    }
                }
                .frame(width: size, height: size)
                .padding(4)
                .background(.fill.tertiary, in: .rect(cornerRadius: 8))
            }
        }
        .accessibilityHidden(true)
    }
}

/// An In progress row (status card): the interaction's own mark, what it
/// is, and one plain line about where it is.
struct StatusCard: View {
    let summary: InteractionSummary

    var body: some View {
        HStack(spacing: 12) {
            StatusMark(state: summary.pose.mark).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(summary.skill.wording.name) · \(summary.title)")
                    .font(.headline)
                    .lineLimit(2)
                Text(summary.status).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The proposal card (Propose step): one sentence, the people, and the
/// skill's own accept and decline, bound to the proposal's revision so a
/// tap on an older card never accepts newer terms (ADR 0011 decision 9).
struct ProposalCard: View {
    let summary: InteractionSummary
    let text: (headline: String, detail: String?)?
    let isFriend: (PeerID) -> Bool
    let localPeer: PeerID?
    let answer: (OwnerAnswer) async -> Void
    @State private var isAnswering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SkillTag(text: summary.tag)
                Spacer()
                PairSymbolRow(peers: (summary.interaction.proposal?.participants ?? summary.interaction.participants).filter { $0 != localPeer }, isFriend: isFriend, size: 20)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(text?.headline ?? summary.title).font(.title3.weight(.semibold))
                if let detail = text?.detail {
                    Text(detail).foregroundStyle(.secondary)
                }
            }
            if let revision = summary.interaction.proposalRevision {
                HStack(spacing: 12) {
                    Button {
                        respond(.accept(proposal: revision))
                    } label: {
                        Text(summary.skill.wording.acceptAction).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        respond(.pass)
                    } label: {
                        Text(summary.skill.wording.declineAction).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .disabled(isAnswering)
            }
            Text(summary.skill.wording.declineNote).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func respond(_ answer: OwnerAnswer) {
        isAnswering = true
        Task {
            await self.answer(answer)
            isAnswering = false
        }
    }
}

/// A Needs you card for a question or a consent sheet: what is asked, and
/// a Review button.
struct NeedsYouCard: View {
    let summary: InteractionSummary
    let review: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SkillTag(text: summary.tag)
                Text(summary.status).font(.headline)
                if summary.interaction.state == .awaitingOwner {
                    Text("Shares only what you pick").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let review {
                Button("Review", action: review).buttonStyle(.bordered)
            }
        }
    }
}
