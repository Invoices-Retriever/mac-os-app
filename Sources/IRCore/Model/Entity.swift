import Foundation

/// A ring-fenced set of sources and documents.
///
/// Multi-entity work (persona P3, the accounting firm) is out of scope for
/// v1.0, but the specification is explicit that the data model must not
/// preclude it. Every source and document therefore carries an entity from day
/// one; v1 simply keeps exactly one, named after the user's own business, and
/// the UI does not show a picker.
public struct Entity: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var vatNumber: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, vatNumber: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.vatNumber = vatNumber; self.createdAt = createdAt
    }

    public static var defaultName: String { core("My business") }
}
