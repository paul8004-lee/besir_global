import Foundation
@testable import besir

/// The shared places of the partner tests (SPEC-DELIVERYCARD-001, card t91): copied from `DeliveryToolFixture` so the tests that
/// survive the deletion of the delivery-only files keep their fixtures. The originals stay beside them until that file is deleted
/// with its tests.
enum ToolFixture {
    static let library = Place(name: "Central Library", address: "9 Library Road", latitude: 37.79, longitude: -122.42)
    /// What the device position would give if the toolbox ever read it.
    static let device = Place(name: "SENTINEL-HOME-1", address: "SENTINEL-HOME-ADDRESS-1", latitude: 37.70, longitude: -122.30)
}

/// How often the toolbox asked for the device position (the manual start place merged with the current location).
@MainActor
final class DeviceReads {
    var count = 0
}
