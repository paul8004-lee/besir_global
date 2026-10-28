import XCTest
@testable import besir

/// SPEC-FULLSIR-001 (card t30 (2)): the closed Place field shows a searched place by its own name, and a favorite
/// row keeps the favorite's label. Pure tests on `PlaceLine.closedSearchText` and on the `LegCardForm` memory
/// "this value was tapped in a search-result row" (`candidatePickedFields`); nothing here uses the network.
@MainActor
final class ClosedPlaceTextTests: XCTestCase {
    private let ferry = Place(name: "Ferry Building", address: "1 Ferry Building, San Francisco, CA 94111",
                              latitude: 37.7955, longitude: -122.3937)
    private let other = Place(name: "Ferry Plaza Farmers Market", address: "1 Ferry Building, San Francisco, CA 94111",
                              latitude: 37.7956, longitude: -122.3935)

    /// A favorite "zzfavx" that holds the same place as the search result "Ferry Building", and one without a place.
    private var favs: [EditField.Option] {
        [EditField.Option(label: "zzfavx", value: "zzfavx", place: ferry),
         EditField.Option(label: "Work", value: "work-value")]
    }

    private func makeForm() -> LegCardForm {
        LegCardForm(card: EditCard(fields: [LegCardForm.manualPlaceRow(label: "Place", favorites: favs)]),
                    favoriteOptions: favs)
    }

    private func placeRow(_ f: LegCardForm) -> UUID {
        f.card.fields.first { $0.key == "location_query" }!.id
    }

    private func originRow(_ f: LegCardForm) -> UUID {
        f.card.fields.first { $0.key == LegRowKeys.originQuery }!.id
    }

    /// Ferry Building in the Place row, the outbound leg switched on (the transition inserts the Origin row).
    private func formWithOriginRow() -> LegCardForm {
        var f = makeForm()
        f.choose(field: placeRow(f), value: ferry.name, place: ferry)
        f.choose(field: f.card.fields.first { $0.key == LegRowKeys.outboundEnabled }!.id, value: "true")
        return f
    }

    // T1
    func testFULLSIR_ClosedTextFavoriteRowKeepsLabel() {
        XCTAssertEqual(PlaceLine.closedSearchText(chosen: "Ferry Building", confirmedPlace: ferry, favorites: favs,
                                                  pickedFromCandidate: false), "zzfavx")
        XCTAssertEqual(PlaceLine.closedSearchText(chosen: "Ferry Building", confirmedPlace: ferry, favorites: favs),
                       "zzfavx", "the default of the new argument keeps the base rule")
    }

    // T2
    func testFULLSIR_ClosedTextCandidatePickShowsPlaceName() {
        XCTAssertEqual(PlaceLine.closedSearchText(chosen: "Ferry Building", confirmedPlace: ferry, favorites: favs,
                                                  pickedFromCandidate: true), "Ferry Building")
        for flag in [false, true] {
            XCTAssertEqual(PlaceLine.closedSearchText(chosen: nil, confirmedPlace: ferry, favorites: favs,
                                                      pickedFromCandidate: flag), "")
            XCTAssertEqual(PlaceLine.closedSearchText(chosen: PlaceTokens.currentLocation, confirmedPlace: nil,
                                                      favorites: favs, pickedFromCandidate: flag), "Current Location")
            XCTAssertEqual(PlaceLine.closedSearchText(chosen: PlaceTokens.noPlace, confirmedPlace: nil,
                                                      favorites: favs, pickedFromCandidate: flag), "No place")
            XCTAssertEqual(PlaceLine.closedSearchText(chosen: other.name, confirmedPlace: other, favorites: favs,
                                                      pickedFromCandidate: flag), "Ferry Plaza Farmers Market")
            XCTAssertEqual(PlaceLine.closedSearchText(chosen: "work-value", confirmedPlace: nil, favorites: favs,
                                                      pickedFromCandidate: flag), "Work")
        }
    }

    // T3
    func testFULLSIR_FormMarkSetAndClearedByChoose() {
        var f = makeForm()
        let id = placeRow(f)
        f.choose(field: id, value: ferry.name, place: ferry)
        XCTAssertEqual(f.closedSearchText(field: id), "zzfavx")
        XCTAssertFalse(f.candidatePickedFields.contains(id))

        f.markCandidatePick(field: id)
        XCTAssertTrue(f.candidatePickedFields.contains(id))
        XCTAssertEqual(f.closedSearchText(field: id), "Ferry Building")
        XCTAssertEqual(f.confirmedPlaces[id], ferry, "the stored place is the picked place")
        XCTAssertEqual(f.card.fields.first { $0.id == id }?.chosen, "Ferry Building", "the stored value is the place name")

        f.choose(field: id, value: ferry.name, place: ferry)
        XCTAssertTrue(f.candidatePickedFields.isEmpty)
        XCTAssertEqual(f.closedSearchText(field: id), "zzfavx")

        f.markCandidatePick(field: id)
        f.choose(field: id, value: other.name, place: other)
        XCTAssertTrue(f.candidatePickedFields.isEmpty)
        XCTAssertEqual(f.closedSearchText(field: id), "Ferry Plaza Farmers Market")
    }

    // T4
    func testFULLSIR_FormMarkClearedByAbandonAndForget() {
        var f = makeForm()
        let id = placeRow(f)
        f.choose(field: id, value: ferry.name, place: ferry)
        f.markCandidatePick(field: id)
        f.abandonPlaceRow(field: id, note: nil)
        XCTAssertFalse(f.candidatePickedFields.contains(id))
        XCTAssertEqual(f.closedSearchText(field: id), "")

        var g = formWithOriginRow()
        let origin = originRow(g)
        g.choose(field: origin, value: ferry.name, place: ferry)
        g.markCandidatePick(field: origin)
        XCTAssertTrue(g.candidatePickedFields.contains(origin))
        g.choose(field: placeRow(g), value: PlaceTokens.noPlace)
        XCTAssertFalse(g.candidatePickedFields.contains(origin), "forgetPlaces releases the removed row's mark")
        XCTAssertTrue(g.candidatePickedFields.isEmpty)
    }

    // T5
    func testFULLSIR_FormMarkGuardAndPerField() {
        var f = makeForm()
        let id = placeRow(f)
        f.choose(field: id, value: "zzfavx")
        XCTAssertEqual(f.card.fields.first { $0.id == id }?.chosen, "zzfavx")
        XCTAssertNil(f.confirmedPlaces[id])
        f.markCandidatePick(field: id)
        XCTAssertTrue(f.candidatePickedFields.isEmpty, "a value without a confirmed place is not marked")

        f.choose(field: id, value: ferry.name, place: ferry)
        f.abandonPlaceRow(field: id, note: nil)
        f.markCandidatePick(field: id)
        XCTAssertTrue(f.candidatePickedFields.isEmpty, "an emptied row is not marked")

        var g = formWithOriginRow()
        let place = placeRow(g)
        let origin = originRow(g)
        g.choose(field: origin, value: ferry.name, place: ferry)
        g.markCandidatePick(field: place)
        XCTAssertEqual(g.candidatePickedFields, [place])
        XCTAssertEqual(g.closedSearchText(field: place), "Ferry Building")
        XCTAssertEqual(g.closedSearchText(field: origin), "zzfavx", "marking the Place row leaves the Origin row alone")
    }
}
