#if canImport(PhotosUI) && canImport(SwiftUI)
import PhotosUI
import StarlingCore
import SwiftUI

/// The only way Swap photos sees photos: the system Photos picker, shown for
/// a pending Swap photos question and never at launch (ADR 0013, ADR 0242).
///
/// The picker runs out of process, so the app needs no photo library
/// permission and can read only the photos the owner selects ("Selecting
/// Photos and Videos in iOS", PhotoKit). Lane A presents it where the
/// question appears and passes the owner's answer to the service.
public struct SwapPhotosPicker: View {
    private let question: SkillQuestion
    private let onAnswer: @MainActor (OwnerAnswer, [PhotosPickerItem]) -> Void
    private let title: LocalizedStringKey
    @State private var selection: [PhotosPickerItem] = []

    /// `title` labels the button ("Pick photos"). `onAnswer` gets the
    /// answer for the service and the picked items, which stay on the phone.
    public init(_ title: LocalizedStringKey, question: SkillQuestion, onAnswer: @escaping @MainActor (OwnerAnswer, [PhotosPickerItem]) -> Void) {
        self.title = title
        self.question = question
        self.onAnswer = onAnswer
    }

    public var body: some View {
        PhotosPicker(title, selection: $selection, maxSelectionCount: limit, selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .automatic)
            .onChange(of: selection) { _, picked in
                guard let answer = SwapPhotos.answer(picked: picked.count, to: question) else { return }
                onAnswer(answer, picked)
            }
    }

    private var limit: Int {
        if case .count(let count) = question.candidates { min(count, SwapPhotos.maxPhotos) } else { SwapPhotos.maxPhotos }
    }
}
#endif
