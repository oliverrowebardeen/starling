import Foundation
import StarlingCore

// After a restart (ADR 0011, amendment 10).

extension PickAPlaceService {
    /// Requests live only in memory, so a live interaction cannot be
    /// resumed yet: each is reported as failed, never left hanging.
    public func restore(_ interactions: [Interaction]) async {
        for interaction in interactions where interaction.skill.id == descriptor.id {
            switch interaction.state {
            case .drafting, .planned, .done, .ended: continue
            default: emit(interaction.id, .failed)
            }
        }
    }
}
