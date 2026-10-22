import XCTest
@testable import BedJetKit

@MainActor
final class DiscoveryTests: XCTestCase {
    func testLinksOnlyTakeTheUnitTheyWereMadeFor() {
        let mine = UUID(), partners = UUID()
        XCTAssertTrue(BLELink.takes(mine, boundTo: mine))
        XCTAssertFalse(BLELink.takes(partners, boundTo: mine))
        // Only `bedjetctl` makes a link without a unit, to use whichever BedJet answers.
        XCTAssertTrue(BLELink.takes(partners, boundTo: nil))
    }

    func testSimulatedBedJetsAreListedAsSoonAsLookingStarts() {
        let discovery = DemoDiscovery()
        var changes = 0
        discovery.onChange = { changes += 1 }
        XCTAssertTrue(discovery.nearby.isEmpty)
        discovery.start()
        XCTAssertEqual(discovery.nearby, DemoDiscovery.simulated)
        XCTAssertGreaterThan(changes, 0)
        // Two share a name, as real units often do; their identities differ.
        XCTAssertEqual(discovery.nearby[0].name, discovery.nearby[1].name)
        XCTAssertNotEqual(discovery.nearby[0].id, discovery.nearby[1].id)
        discovery.stop()
        XCTAssertTrue(discovery.nearby.isEmpty)
    }

    func testSignalIsDescribedInWords() {
        XCTAssertEqual(NearbyBedJet(id: UUID(), name: "B", generation: nil, rssi: -50).signal, .strong)
        XCTAssertEqual(NearbyBedJet(id: UUID(), name: "B", generation: nil, rssi: -70).signal, .fair)
        XCTAssertEqual(NearbyBedJet(id: UUID(), name: "B", generation: nil, rssi: -90).signal, .weak)
    }

    func testASimulatedBedJetThatIsAwayNeverConnects() async throws {
        let link = DemoLink()
        link.answers = false
        link.start()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(link.state, .searching)
        link.stop()
    }

    func testHandOverRequestsAreForOneBedJetOnly() {
        // A phone asking for one unit by its name is ignored by a phone holding another.
        XCTAssertNotEqual(BLELink.handoffUUID(forDeviceNamed: "BEDJET_3A1F"), BLELink.handoffUUID(forDeviceNamed: "BEDJET_3B07"))
    }
}
