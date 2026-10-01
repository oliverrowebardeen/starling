import Foundation

// Who a request goes to (ADR 0020). The owner's lists and rules stay on the
// phone: no `MessageBody` can carry them, and a friend left out receives
// nothing that tells them so.

/// Who a request goes to, as the owner chose in New.
public enum Audience: Hashable, Sendable, Codable {
    case allFriends
    /// The owner's own "close friends" list, kept on this phone.
    case closeFriends
    case picked([PeerID])
    /// Every friend but these. Nobody left out can tell.
    case everyoneExcept([PeerID])
    /// One of the owner's saved private groups.
    case group(GroupID)
}

public struct GroupID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue.uuidString }
}

/// A saved private group, such as "Climbing". Kept on this phone only. The
/// name is the owner's own words, so it may appear in the owner's prompts.
public struct FriendGroup: Hashable, Sendable, Codable, Identifiable {
    public static let maxNameCharacters = 32

    public let id: GroupID
    public let name: String
    public let members: Set<PeerID>

    public init(id: GroupID = GroupID(), name: String, members: Set<PeerID>) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard (1...Self.maxNameCharacters).contains(trimmed.count) else {
            throw ValidationError("FriendGroup.name", "must be 1-\(Self.maxNameCharacters) characters")
        }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }) else {
            throw ValidationError("FriendGroup.name", "no control characters or line breaks")
        }
        self.id = id
        self.name = trimmed
        self.members = members
    }

    private enum CodingKeys: String, CodingKey { case id, name, members }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(GroupID.self, forKey: .id), name: c.decode(String.self, forKey: .name),
                      members: c.decode(Set<PeerID>.self, forKey: .members))
    }
}

/// A standing rule for one friend. It shapes who a request goes to, never
/// what is shared (ADR 0020; topics stay global, ADR 0014).
public enum FriendRule: String, Hashable, Sendable, Codable, CaseIterable {
    /// Added to every broad audience unless explicitly excepted.
    case alwaysInclude
    /// Left out of every broad audience.
    case neverInclude
    /// Only ever asked quietly: left out of Invite requests.
    case quietOnly
}

/// The owner's audience lists and rules, kept on this phone only.
public struct AudienceBook: Hashable, Sendable, Codable {
    public var closeFriends: Set<PeerID>
    public var groups: [GroupID: FriendGroup]
    /// At most one rule per friend.
    public var rules: [PeerID: FriendRule]

    public init(closeFriends: Set<PeerID> = [], groups: [FriendGroup] = [], rules: [PeerID: FriendRule] = [:]) {
        self.closeFriends = closeFriends
        self.groups = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.rules = rules
    }

    public static let empty = AudienceBook()
}

extension Audience {
    /// The friends a request goes to. Every surface uses this one function,
    /// so an exception, a group, or a rule means the same thing everywhere.
    ///
    /// - Picked friends are exactly the friends picked: a choice made now
    ///   beats any standing rule.
    /// - A broad audience (all friends, close friends, everyone except, a
    ///   group) starts from its set, adds `alwaysInclude` friends unless
    ///   explicitly excepted, removes `neverInclude` friends, and removes
    ///   `quietOnly` friends when the mode is Invite.
    /// - Then only friends whose card supports the skill stay, in the order
    ///   of `friends`. An unknown group resolves to nobody.
    ///
    /// - Parameters:
    ///   - friends: Every paired friend, in display order.
    ///   - canRun: Whether a friend's card supports the skill.
    public func resolve(mode: SendMode, friends: [PeerID], book: AudienceBook, canRun: (PeerID) -> Bool) -> [PeerID] {
        let paired = Set(friends)
        let chosen: Set<PeerID>
        switch self {
        case .picked(let peers):
            chosen = Set(peers).intersection(paired)
        case .allFriends, .closeFriends, .everyoneExcept, .group:
            let excepted: Set<PeerID> = if case .everyoneExcept(let peers) = self { Set(peers) } else { [] }
            var base: Set<PeerID>
            switch self {
            case .closeFriends: base = book.closeFriends
            case .group(let id): base = book.groups[id]?.members ?? []
            default: base = paired
            }
            if case .group(let id) = self, book.groups[id] == nil { return [] }
            base.formUnion(book.rules.filter { $0.value == .alwaysInclude }.keys)
            base.subtract(excepted)
            base.subtract(book.rules.filter { $0.value == .neverInclude }.keys)
            if mode == .invite { base.subtract(book.rules.filter { $0.value == .quietOnly }.keys) }
            chosen = base.intersection(paired)
        }
        return friends.filter { chosen.contains($0) && canRun($0) }
    }
}
