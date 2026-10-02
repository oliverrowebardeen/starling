import PickAPlace
import StarlingCore
import StarlingDesign
import StarlingFeatures
import SwiftUI

/// New (ADR 0015 decision 2, mockup "New"): type anything, check what
/// Starling understood, pick who to ask, and tap the skill's own button.
/// The draft survives switching tabs; Cancel clears it.
struct NewView: View {
    let app: AppModel
    @Bindable var composer: ComposerModel
    let done: () -> Void
    let cancel: () -> Void
    @State private var editing: RulesDraft?
    @State private var chipEdit: ChipEdit?
    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let chain = composer.chain { chainHeader(chain) }
                composerField
                if composer.skill != nil || composer.isUnderstanding { understood }
                if composer.skill == .pickAPlace, let places = composer.places {
                    PlacePickerSection(app: app, picker: places, composer: composer)
                }
                ask
                tiles
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("New")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    composer.clear()
                    cancel()
                }
            }
        }
        .safeAreaInset(edge: .bottom) { sendBar }
        .task(id: composer.text) {
            // Read the words once the owner pauses typing.
            guard composer.chain == nil, !composer.text.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await composer.understand()
        }
        .sheet(item: $chipEdit) { edit in
            switch edit {
            case .words(let issue, let text):
                ChipWordsEditor(title: Self.wordsTitle(issue, formatter: app.services.formatter), text: text) { words in
                    composer.setWords(words, for: issue)
                }
            case .time(let slot):
                ChipTimeEditor(slot: slot) { composer.setTime($0) }
            }
        }
        .sheet(item: $editing) { draft in
            ChipEditor(draft: draft, formatter: app.services.formatter) { edited in
                if let rules = try? edited.build() { composer.constraints = rules.constraints }
                editing = nil
            }
        }
    }

    private var composerField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What do you want to do with friends?").font(.subheadline).foregroundStyle(.secondary)
            TextField("boba tonight with whoever's free", text: $composer.text, axis: .vertical)
                .font(.title2)
                .lineLimit(2...5)
                .focused($typing)
                .submitLabel(.done)
                .onSubmit { Task { await composer.understand() } }
            if !composer.understands {
                Text("The on-device model isn't available, so pick what this is below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 20))
    }

    private func chainHeader(_ chain: ComposerModel.ChainDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Keeps your plan going", systemImage: "link").font(.headline)
            if let note = composer.chainAddsNote {
                Text(note).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var understood: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Starling understood").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                if composer.skill != nil {
                    Button("Edit") { editing = RulesDraft(OwnerRules(constraints: composer.constraints)) }
                        .font(.subheadline)
                }
            }
            if composer.isUnderstanding {
                ProgressView("Reading this on your iPhone...")
            } else {
                // Every chip is applied; a tap edits it in place, and an
                // optional one can be removed. Edit opens everything.
                FlowLayout(spacing: 8) {
                    ForEach(composer.chipItems) { chip in chipView(chip) }
                }

            }
        }
    }

    @ViewBuilder private func chipView(_ chip: ComposeChip) -> some View {
        let lead = chip.part == .skill
        HStack(spacing: 6) {
            chipAction(chip)
            if chip.isRemovable {
                Button {
                    composer.remove(chip.part)
                } label: {
                    Image(systemName: "xmark.circle.fill").imageScale(.medium)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(chip.text)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .foregroundStyle(lead ? Color.white : Color.accentColor)
        .background(lead ? Color.accentColor : Color.accentColor.opacity(0.14), in: .capsule)
    }

    @ViewBuilder private func chipAction(_ chip: ComposeChip) -> some View {
        switch chip.editor {
        case .none:
            Text(chip.text)
        case .words(let issue, let text):
            Button(chip.text) { chipEdit = .words(issue, text) }
                .buttonStyle(.plain)
                .accessibilityHint("Edit")
        case .time(let slot):
            Button(chip.text) { chipEdit = .time(slot) }
                .buttonStyle(.plain)
                .accessibilityHint("Edit")
        case .details:
            Button(chip.text) { editing = RulesDraft(OwnerRules(constraints: composer.constraints)) }
                .buttonStyle(.plain)
                .accessibilityHint("Edit")
        case .mode:
            Menu {
                Picker(chip.text, selection: Binding(get: { composer.sendMode }, set: { composer.mode = $0 })) {
                    Text(ComposerModel.modeLabel(.askQuietly)).tag(SendMode.askQuietly)
                    Text(ComposerModel.modeLabel(.invite)).tag(SendMode.invite)
                }
            } label: { Text(chip.text) }
        case .audience:
            Menu {
                Picker(chip.text, selection: $composer.audience) {
                    ForEach(Array(composer.audienceOptions.enumerated()), id: \.offset) { _, option in
                        Text(option.label).tag(option.choice)
                    }
                }
            } label: { Text(chip.text) }
        case .expiry:
            Menu {
                Section(Expiry.controlTitle) {
                    ForEach(Expiry.presets, id: \.self) { preset in
                        Button(preset.label) { composer.expiry = preset }
                    }
                }
            } label: { Text(chip.text) }
            .accessibilityHint(Expiry.controlTitle)
        }
    }

    static func wordsTitle(_ issue: IssueKey, formatter: ValueFormatter) -> String {
        switch issue {
        case .activity: "What you want to do"
        case .place: "Where"
        default: formatter.issueName(issue)
        }
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Ask").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Picker("Ask", selection: $composer.audience) {
                    ForEach(Array(composer.audienceOptions.enumerated()), id: \.offset) { _, option in
                        Text(option.label).tag(option.choice)
                    }
                }
                .pickerStyle(.menu)
            }
            if composer.offersModeChoice {
                Picker("How", selection: Binding(get: { composer.sendMode }, set: { composer.mode = $0 })) {
                    Text(ComposerModel.modeLabel(.askQuietly)).tag(SendMode.askQuietly)
                    Text(ComposerModel.modeLabel(.invite)).tag(SendMode.invite)
                }
                .pickerStyle(.segmented)
                Text(ComposerModel.modeNote(composer.sendMode))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if composer.audience == .everyoneExcept {
                Text("Tap a friend to leave them out. Nobody you leave out can tell.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if composer.audienceFriends.isEmpty {
                Text("Pair with a friend in Friends first.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(composer.audienceFriends) { friend in
                            Button { composer.toggle(friend.id) } label: {
                                VStack(spacing: 6) {
                                    PairSymbol(seed: friend.id.bytes)
                                        .frame(width: 36, height: 36)
                                        .padding(8)
                                        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
                                        .overlay {
                                            if friend.isIncluded && friend.canRun {
                                                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, lineWidth: 2)
                                            }
                                        }
                                    Text(friend.name).font(.caption).lineLimit(1).foregroundStyle(.primary)
                                }
                                .frame(width: 64)
                                .opacity(friend.isIncluded && friend.canRun ? 1 : 0.4)
                            }
                            .accessibilityLabel(friend.name)
                            .accessibilityValue(friend.isIncluded ? (friend.canRun ? "Asked" : "Their Starling doesn't do this yet") : "Not asked")
                            .disabled(composer.chain != nil && !friend.isIncluded)
                        }
                    }
                }
            }
            if let note = composer.leftOutNote {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var tiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Or start with").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(composer.tiles) { tile in
                    Button {
                        Task { await composer.choose(tile.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tile.skill.wording.name).font(.headline).foregroundStyle(.primary)
                            Text(tile.subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                        .padding()
                        .background(.background.secondary, in: .rect(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(composer.skill == tile.id ? Color.accentColor : Color.clear, lineWidth: 2)
                        }
                    }
                    .disabled(!tile.canStart)
                }
            }
        }
    }

    private var sendBar: some View {
        VStack(spacing: 8) {
            if let notice = composer.notice {
                Text(notice).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            } else if let blocker = composer.blocker, composer.skill != nil {
                Text(blocker).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button {
                typing = false
                Task {
                    if await composer.send() != nil { done() }
                }
            } label: {
                Group {
                    if composer.isSending { ProgressView() } else { Text(composer.startLabel) }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!composer.canSend)
            if let footnote = composer.footnote {
                Text(footnote).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.bar)
    }
}

/// One chip being edited in place.
enum ChipEdit: Identifiable {
    case words(IssueKey, String)
    case time(TimeSlot?)

    var id: String {
        switch self {
        case .words(let issue, _): "words-\(issue.rawValue)"
        case .time: "time"
        }
    }
}

/// Edits a chip's words, comma separated, in the owner's own words.
private struct ChipWordsEditor: View {
    let title: String
    @State var text: String
    /// Returns whether the words applied.
    let save: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var refused = false

    var body: some View {
        NavigationStack {
            Form {
                TextField(title, text: $text)
                    .submitLabel(.done)
                    .onSubmit(apply)
                if refused {
                    Text("Starling can't use that. Try a few plain words.").font(.footnote).foregroundStyle(.orange)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: apply) }
            }
        }
        .presentationDetents([.height(220)])
    }

    private func apply() {
        if save(text) { dismiss() } else { refused = true }
    }
}

/// Edits the time asked about: one window, start and end.
private struct ChipTimeEditor: View {
    @State private var start: Date
    @State private var end: Date
    let save: (TimeSlot) -> Bool
    @Environment(\.dismiss) private var dismiss

    init(slot: TimeSlot?, save: @escaping (TimeSlot) -> Bool) {
        let start = slot?.start ?? Date().addingTimeInterval(3600)
        _start = State(initialValue: start)
        _end = State(initialValue: slot?.end ?? start.addingTimeInterval(2 * 3600))
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $start)
                DatePicker("Until", selection: $end, in: start...)
            }
            .navigationTitle("When")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let slot = try? TimeSlot(start: start, end: end), save(slot) { dismiss() }
                    }
                    .disabled(end <= start)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Edits the chips as rules, with the same review rows as the rules editor.
private struct ChipEditor: View {
    @State var draft: RulesDraft
    let formatter: ValueFormatter
    let done: (RulesDraft) -> Void

    var body: some View {
        NavigationStack {
            Form {
                RulesReviewSections(draft: $draft, flags: [:], problems: draft.problems, formatter: formatter, fromModel: false)
            }
            .navigationTitle("Edit details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { done(draft) }.disabled(!draft.problems.isEmpty)
                }
            }
        }
    }
}

extension RulesDraft: @retroactive Identifiable {
    public var id: Int { hashValue }
}

/// Lays chips out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Pick a place's part of New (P15-D request 2): look near an area or
/// nearby, choose the places to ask about, or type them.
private struct PlacePickerSection: View {
    let app: AppModel
    @Bindable var picker: PlacePicker
    let composer: ComposerModel
    @State private var typing = ""
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Places to ask about").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            TextField("What kind of place, like dinner or boba", text: $picker.what)
                .textFieldStyle(.roundedBorder)
            Toggle("Near me", isOn: $picker.nearby)
            if !picker.nearby {
                TextField("Area, like near Franklin", text: $picker.area)
                    .textFieldStyle(.roundedBorder)
            }
            Button {
                searching = true
                Task {
                    let friends = composer.audienceFriends.filter { $0.isIncluded && $0.canRun }.map(\.name)
                    await picker.search(permissions: app.permissions, skill: PickAPlaceSkill.descriptor, friends: friends, settings: app.settings)
                    searching = false
                }
            } label: {
                if searching { ProgressView() } else { Label("Find places", systemImage: "magnifyingglass") }
            }
            .buttonStyle(.bordered)
            .disabled(searching)
            if let notice = picker.notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(picker.results + picker.typed, id: \.choice) { candidate in
                Toggle(isOn: Binding(get: { picker.selected.contains(candidate.choice) }, set: { _ in picker.toggle(candidate.choice) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.choice.name.rawValue)
                        if let tier = candidate.facts.priceTier {
                            Text(tier.symbol).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                TextField("Or type a place", text: $typing)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                Button("Add", action: addTyped).disabled(typing.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addTyped() {
        if picker.add(typing) { typing = "" }
    }
}
