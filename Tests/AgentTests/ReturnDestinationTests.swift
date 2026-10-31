import XCTest
@testable import besir

/// SPEC-RETDEST-001 (card t81): the Destination row of the return leg offers "Current Location" like the Origin row.
/// Pure tests on the card model (`LegCardForm`, `PlaceLine.rows`, `PlaceLineResolve.permissionNote(for:)`,
/// `LegSavePlanner.ops`); nothing here uses the network or the `Store`. The SwiftUI routing of the two screens and the
/// place-search count are not reachable from a unit test; the static gates and the simulator walk cover them.
@MainActor
final class ReturnDestinationTests: XCTestCase {
    private let cal = Calendar.current

    /// A searched place far from the simulator location.
    private let place = Place(name: "Equinox Union Street", address: "1980 Union St, San Francisco, CA 94123",
                              latitude: 37.7973, longitude: -122.4318)
    /// The shape `PlaceLineResolve.availablePlace` builds when the location manager has no place name.
    private let here = Place(name: "Current Location", address: "", latitude: 37.7955, longitude: -122.3937)
    private let candidate = Place(name: "Ferry Building", address: "1 Ferry Building, San Francisco, CA 94111",
                                  latitude: 37.7956, longitude: -122.3935)

    /// A favorite that holds a place, and one without a place.
    private var favs: [EditField.Option] {
        [EditField.Option(label: "zzfavx", value: "zzfavx", place: place),
         EditField.Option(label: "Work", value: "work-value")]
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 18) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func field(_ f: LegCardForm, _ key: String) -> EditField {
        f.card.fields.first { $0.key == key }!
    }

    private func rowId(_ f: LegCardForm, _ key: String) -> UUID {
        field(f, key).id
    }

    /// The New Activity form the app builds: title, a chosen place, start and end; the Return Travel toggle (and the
    /// Outbound Travel toggle when asked) turned on through the real transition, so the leg rows are born by it.
    private func makeForm(outboundOn: Bool = false, returnOn: Bool = true) -> LegCardForm {
        let start = at(2026, 11, 4, 18)
        let rows = LegCardForm.manualNewActivityRows(favorites: favs, defaultDay: start, now: at(2026, 11, 4, 9),
                                                     presetStart: nil)
        var f = LegCardForm(card: EditCard(fields: rows), favoriteOptions: favs)
        f.setTitleText(field: rowId(f, "title"), text: "zzt81a")
        f.choosePlainTime(field: rowId(f, "start_iso"), date: start)
        f.choosePlainTime(field: rowId(f, "end_iso"), date: cal.date(byAdding: .hour, value: 1, to: start)!)
        f.choose(field: rowId(f, "location_query"), value: place.name, place: place)
        if outboundOn { f.choose(field: rowId(f, LegRowKeys.outboundEnabled), value: "true") }
        if returnOn { f.choose(field: rowId(f, LegRowKeys.returnEnabled), value: "true") }
        return f
    }

    /// The form Edit Activity builds for an activity with a place and no legs.
    private func seededForm() -> LegCardForm {
        let activity = ActivityBlock(title: "zzt81a", location: place, startDate: at(2026, 11, 4, 18),
                                     endDate: at(2026, 11, 4, 19), recurrenceId: nil, syncToCalendar: nil)
        return LegCardForm.seeded(activity: activity, outbound: nil, returnLeg: nil,
                                  noPlaceValue: PlaceTokens.noPlace, placeOptions: [], favoriteOptions: favs)
    }

    private func offersChip(_ row: EditField) -> Bool {
        row.options.contains { $0.value == PlaceTokens.currentLocation && $0.label == "Current Location" }
    }

    // MARK: AC-001

    // T1
    func testRETDEST_DestinationRowOffersCurrentLocation() {
        let both = makeForm(outboundOn: true)
        let dest = field(both, LegRowKeys.returnQuery)
        XCTAssertEqual(dest.placeSpecials, PlaceLineSpecials.currentLocation)
        XCTAssertEqual(dest.placeSpecials, field(both, LegRowKeys.originQuery).placeSpecials,
                       "the two rows take their list from the same constant")
        XCTAssertTrue(offersChip(dest))

        // The reborn row: Return Travel off and on again builds the row anew.
        var reborn = makeForm()
        reborn.choose(field: rowId(reborn, LegRowKeys.returnEnabled), value: "false")
        XCTAssertNil(reborn.card.fields.first { $0.key == LegRowKeys.returnQuery })
        reborn.choose(field: rowId(reborn, LegRowKeys.returnEnabled), value: "true")
        let again = field(reborn, LegRowKeys.returnQuery)
        XCTAssertEqual(again.placeSpecials, PlaceLineSpecials.currentLocation)
        XCTAssertTrue(offersChip(again))

        // The Edit Activity form, Return Travel turned on.
        var seeded = seededForm()
        seeded.choose(field: rowId(seeded, LegRowKeys.returnEnabled), value: "true")
        let editDest = field(seeded, LegRowKeys.returnQuery)
        XCTAssertEqual(editDest.placeSpecials, PlaceLineSpecials.currentLocation)
        XCTAssertTrue(offersChip(editDest))
    }

    // T2
    func testRETDEST_DestinationListOrder() {
        let f = makeForm(outboundOn: true)
        let dest = field(f, LegRowKeys.returnQuery)
        let origin = field(f, LegRowKeys.originQuery)
        func rows(_ row: EditField, _ query: String) -> [PlaceLine.Row] {
            PlaceLine.rows(query: query, specials: row.placeSpecials, favorites: row.options, candidates: [candidate])
        }

        XCTAssertEqual(rows(dest, ""), [.special(PlaceTokens.currentLocation),
                                        .favorite(label: "zzfavx", place: place),
                                        .favorite(label: "Work", place: nil),
                                        .candidate(candidate)])
        XCTAssertEqual(rows(dest, ""), rows(origin, ""), "the same order the Origin row uses")

        XCTAssertEqual(rows(dest, "zzf"), [.favorite(label: "zzfavx", place: place), .candidate(candidate)],
                       "typed text lists no Current Location row")
        XCTAssertEqual(rows(dest, "zzf"), rows(origin, "zzf"))
    }

    // MARK: AC-002

    // T3
    func testRETDEST_OnlyOfferingRowsOfferCurrentLocation() {
        let f = makeForm(outboundOn: true)
        XCTAssertGreaterThanOrEqual(f.card.fields.count, 14, "the loop below must not be vacuous")
        let offering = Set(f.card.fields.filter(\.offersCurrentLocation).map(\.key))
        XCTAssertEqual(offering, [LegRowKeys.originQuery, "location_query", LegRowKeys.returnQuery])
        for key in ["title", "start_iso", "end_iso", LegRowKeys.outboundEnabled, LegRowKeys.returnEnabled,
                    LegRowKeys.outboundMode, LegRowKeys.returnMode, LegRowKeys.bufferMinutes,
                    LegRowKeys.notifyEnabled, LegRowKeys.notifyLeadMinutes, RecurrenceLine.key] {
            XCTAssertFalse(field(f, key).offersCurrentLocation, key)
        }

        // The rule itself, on rows that are not in any form: it reads the special-row list and nothing else.
        func synthetic(_ specials: [String]) -> EditField {
            EditField(key: "synthetic_place", kind: .place, label: "Synthetic", options: [], allowsCustom: true,
                      placeSpecials: specials)
        }
        XCTAssertFalse(synthetic([]).offersCurrentLocation)
        XCTAssertFalse(synthetic([PlaceTokens.noPlace]).offersCurrentLocation)
        XCTAssertTrue(synthetic([PlaceTokens.noPlace, PlaceTokens.currentLocation]).offersCurrentLocation)
    }

    // T4
    func testRETDEST_PermissionNoteWording() {
        let f = makeForm(outboundOn: true)
        let origin = PlaceLineResolve.permissionNote(for: field(f, LegRowKeys.originQuery))
        XCTAssertEqual(origin, PlaceLineResolve.locationPermissionNote)
        for key in [LegRowKeys.returnQuery, "location_query", "title"] {
            XCTAssertEqual(PlaceLineResolve.permissionNote(for: field(f, key)),
                           PlaceLineResolve.locationPermissionNoteForPlace, key)
        }
        XCTAssertEqual(PlaceLineResolve.locationPermissionNote,
                       "Location permission is off. Allow it in Settings, or search for an origin yourself.")
        XCTAssertEqual(PlaceLineResolve.locationPermissionNoteForPlace,
                       "Location permission is off. Allow it in Settings, or search for a place yourself.")
    }

    // MARK: AC-003

    // T5
    func testRETDEST_PickOnDestinationRowStoresTokenAndPlace() {
        var f = makeForm()
        let dest = rowId(f, LegRowKeys.returnQuery)
        XCTAssertEqual(f.card.unchosenLabels, ["Destination"])
        f.choose(field: dest, value: PlaceTokens.currentLocation, place: here)
        XCTAssertEqual(field(f, LegRowKeys.returnQuery).chosen, PlaceTokens.currentLocation)
        XCTAssertEqual(f.confirmedPlaces[dest], here)
        XCTAssertEqual(f.closedSearchText(field: dest), "Current Location")
        XCTAssertEqual(field(f, LegRowKeys.returnQuery).chosenLabel, "Current Location")
        XCTAssertNil(field(f, LegRowKeys.returnQuery).note)
        XCTAssertTrue(f.card.isReady)

        // The premise of the screens' routing: the card cannot tell a bare token from a picked place, so a tap that
        // reaches the model without the place leaves a ready card with no place behind it.
        var bare = makeForm()
        let bareDest = rowId(bare, LegRowKeys.returnQuery)
        bare.choose(field: bareDest, value: PlaceTokens.currentLocation, place: nil)
        XCTAssertTrue(bare.card.isReady)
        XCTAssertNil(bare.confirmedPlaces[bareDest])
    }

    // T6
    func testRETDEST_ReturnOffOnRestoresTokenAndPlace() {
        var f = makeForm()
        let dest = rowId(f, LegRowKeys.returnQuery)
        f.choose(field: dest, value: PlaceTokens.currentLocation, place: here)

        f.choose(field: rowId(f, LegRowKeys.returnEnabled), value: "false")
        XCTAssertEqual(f.rememberedReturnTo, PlaceTokens.currentLocation)
        XCTAssertEqual(f.rememberedReturnToPlace, here)
        XCTAssertNil(f.card.fields.first { $0.key == LegRowKeys.returnQuery })

        f.choose(field: rowId(f, LegRowKeys.returnEnabled), value: "true")
        let reborn = field(f, LegRowKeys.returnQuery)
        XCTAssertNotEqual(reborn.id, dest, "the reborn row has a new identity")
        XCTAssertEqual(reborn.chosen, PlaceTokens.currentLocation)
        XCTAssertEqual(f.confirmedPlaces[reborn.id], here)
        XCTAssertEqual(f.closedSearchText(field: reborn.id), "Current Location")
    }

    // T7
    func testRETDEST_EditActivitySavePlanUsesPickedPlace() {
        let seed = seededForm()
        var current = seed
        current.choose(field: rowId(current, LegRowKeys.returnEnabled), value: "true")
        current.choose(field: rowId(current, LegRowKeys.returnQuery), value: PlaceTokens.currentLocation, place: here)

        let ops = LegSavePlanner.ops(seed: seed, current: current, outboundLeg: nil, returnLeg: nil)
        XCTAssertEqual(ops.count, 1)
        guard let op = ops.first, case let .add(role, outerPlace, _, _, _, _) = op else {
            return XCTFail("expected one add op, got \(ops)")
        }
        XCTAssertEqual(role, .departure)
        XCTAssertEqual(outerPlace, here, "the leg's destination is the picked place, with no lookup in the plan")
    }
}
