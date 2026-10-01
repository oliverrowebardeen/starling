import Contacts
import ContactsUI
import EventKit
import EventKitUI
import MapKit
import MessageUI
import StarlingCore
import StarlingFeatures
import SwiftUI

// Hand-offs (ADR 0018): each opens another app with the owner in control,
// and none sends anything by itself.

/// Add to Calendar with `EKEventEditViewController`, which needs no
/// calendar permission (ADR 0013, EventKit docs).
struct CalendarEventEditor: UIViewControllerRepresentable {
    let draft: CalendarDraft
    let done: (_ saved: Bool) -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.location = draft.location
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let done: (Bool) -> Void
        init(done: @escaping (Bool) -> Void) { self.done = done }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            done(action == .saved)
        }
    }
}

/// Message the group with `MFMessageComposeViewController`. Recipients
/// come only from contact links the owner made on this phone.
struct MessageComposer: UIViewControllerRepresentable {
    let draft: MessageDraft
    let done: (_ sent: Bool) -> Void

    static var canSend: Bool { MFMessageComposeViewController.canSendText() }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = draft.recipients
        controller.body = draft.body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let done: (Bool) -> Void
        init(done: @escaping (Bool) -> Void) { self.done = done }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            done(result == .sent)
        }
    }
}

/// Picks a contact with `CNContactPickerViewController`, which "does not
/// need access to the user's contacts" (ADR 0018). Only contacts with a
/// phone number can be picked; the link keeps the first one.
struct ContactPicker: UIViewControllerRepresentable {
    let done: (ContactLink?) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let controller = CNContactPickerViewController()
        controller.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        controller.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let done: (ContactLink?) -> Void
        init(done: @escaping (ContactLink?) -> Void) { self.done = done }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            guard let phone = contact.phoneNumbers.first?.value.stringValue else { return done(nil) }
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? phone
            done(ContactLink(contactID: contact.identifier, name: name, phone: phone))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            done(nil)
        }
    }
}

/// Directions in Apple Maps. Maps routes from the owner's location itself,
/// so Starling needs no location permission (ADR 0018 decision 3).
@MainActor
enum Directions {
    static func open(_ place: PlaceChoice) {
        let options = [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault]
        if let raw = place.mapItemID, let identifier = MKMapItem.Identifier(rawValue: raw) {
            Task {
                if let item = try? await MKMapItemRequest(mapItemIdentifier: identifier).mapItem {
                    item.openInMaps(launchOptions: options)
                } else {
                    openByCoordinate(place, options: options)
                }
            }
        } else {
            openByCoordinate(place, options: options)
        }
    }

    private static func openByCoordinate(_ place: PlaceChoice, options: [String: String]) {
        guard let coordinate = place.coordinate else {
            // No position: search Maps for the name instead.
            var components = URLComponents(string: "maps://")!
            components.queryItems = [URLQueryItem(name: "q", value: place.name.rawValue)]
            if let url = components.url { UIApplication.shared.open(url) }
            return
        }
        let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        item.name = place.name.rawValue
        item.openInMaps(launchOptions: options)
    }
}
