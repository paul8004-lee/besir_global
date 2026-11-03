import XCTest
import CoreLocation
@testable import besir

/// SPEC-UBERLINK-001 (card t120), T01-T08: the link the trip screen's Open in Uber button opens. Pure tests on
/// `UberLink.url(for:)`; nothing here opens a link or touches the network. Written before the rule: on the stub
/// (`url(for:)` answers nil) every test fails on its first unwrap or on its valid rows.
final class UberLinkTests: XCTestCase {
    private let ferry = Place(name: "Ferry Building", address: "1 Ferry Building, San Francisco, CA 94105",
                              latitude: 37.7955, longitude: -122.3937)
    private let opera = Place(name: "Opera House", address: "Bennelong Point, Sydney NSW 2000",
                              latitude: -33.8688, longitude: 151.2093)

    private static let fiveNames = ["action", "pickup", "dropoff[latitude]", "dropoff[longitude]", "dropoff[nickname]"]

    // MARK: Helpers

    private func place(_ name: String, _ latitude: Double = 37.7955, _ longitude: Double = -122.3937) -> Place {
        Place(name: name, address: "", latitude: latitude, longitude: longitude)
    }

    private func link(_ place: Place, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        try XCTUnwrap(UberLink.url(for: place), "a link for \(place.name)", file: file, line: line)
    }

    /// The query items as `URLComponents` decodes them.
    private func items(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> [URLQueryItem] {
        try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, "query items",
                      file: file, line: line)
    }

    /// The query read the way an HTML form decoder reads it: split on `&`, then on the first `=`, `+` read as a space,
    /// then percent-decoded.
    private func formDecoded(_ url: URL) -> [(name: String, value: String)] {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        func decode(_ s: Substring) -> String {
            String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "<undecodable>"
        }
        return query.split(separator: "&", omittingEmptySubsequences: false).map { part in
            guard let eq = part.firstIndex(of: "=") else { return (decode(part), "") }
            return (decode(part[..<eq]), decode(part[part.index(after: eq)...]))
        }
    }

    private func value(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first { $0.name == name }?.value
    }

    private func formValue(_ url: URL, _ name: String) -> String? {
        formDecoded(url).first { $0.name == name }?.value
    }

    private func matchesSixDecimals(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.range(of: "^-?[0-9]{1,3}\\.[0-9]{6}$", options: .regularExpression) != nil
    }

    // MARK: AC-001

    func testUBER_T01_theFerryBuildingLinkHasTheCardShape() throws {
        let url = try link(ferry)
        XCTAssertEqual(url.absoluteString,
                       "https://m.uber.com/ul/?action=setPickup&pickup=my_location&dropoff%5Blatitude%5D=37.795500&dropoff%5Blongitude%5D=-122.393700&dropoff%5Bnickname%5D=Ferry%20Building")
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "https")
        XCTAssertEqual(parts.host, "m.uber.com")
        XCTAssertEqual(parts.path, "/ul/")
        let decoded = try items(url)
        XCTAssertEqual(decoded.map(\.name), Self.fiveNames)
        XCTAssertEqual(decoded.map(\.value), ["setPickup", "my_location", "37.795500", "-122.393700", "Ferry Building"])
    }

    func testUBER_T02_theLinkCarriesNoRiderPositionAndNoOtherKey() throws {
        for p in [ferry, opera, place("", 0, 0)] {
            let url = try link(p)
            let names = try items(url).map(\.name)
            for name in names {
                XCTAssertTrue(Self.fiveNames.contains(name), "\(p.name): unexpected item \(name)")
                XCTAssertEqual(names.filter { $0 == name }.count, 1, "\(p.name): \(name) appears once")
                XCTAssertFalse(name.hasPrefix("pickup["), "\(p.name): no pickup coordinate item")
            }
            XCTAssertEqual(value(try items(url), "pickup"), "my_location", "\(p.name): the pickup is left to Uber")
            XCTAssertFalse(url.absoluteString.contains("client_id"), "\(p.name): no client id")
            XCTAssertFalse(url.absoluteString.contains("pickup%5B"), "\(p.name): no encoded pickup coordinate")
        }
    }

    // MARK: AC-002

    func testUBER_T03_coordinatesAreSixDecimalsWithAPoint() throws {
        let rows: [(Double, Double, String, String)] = [
            (0.00001, -0.00001, "0.000010", "-0.000010"),
            (-33.8688, 151.2093, "-33.868800", "151.209300"),
            (37.7749, -122.4194, "37.774900", "-122.419400"),
            (90, -180, "90.000000", "-180.000000"),
        ]
        for (lat, lon, latText, lonText) in rows {
            let decoded = try items(try link(place("Spot", lat, lon)))
            let gotLat = value(decoded, "dropoff[latitude]")
            let gotLon = value(decoded, "dropoff[longitude]")
            XCTAssertEqual(gotLat, latText, "latitude of (\(lat), \(lon))")
            XCTAssertEqual(gotLon, lonText, "longitude of (\(lat), \(lon))")
            XCTAssertTrue(matchesSixDecimals(gotLat), "latitude form of (\(lat), \(lon)): \(gotLat ?? "nil")")
            XCTAssertTrue(matchesSixDecimals(gotLon), "longitude form of (\(lat), \(lon)): \(gotLon ?? "nil")")
        }
    }

    // MARK: AC-003

    func testUBER_T04_symbolsInTheNameSurviveAComponentAndAFormDecoder() throws {
        for name in ["Joe's Cafe & Bar #1 + more", "a=b?c/d", "100% Pure"] {
            let url = try link(place(name))
            XCTAssertEqual(value(try items(url), "dropoff[nickname]"), name, "component decoder: \(name)")
            XCTAssertEqual(formValue(url, "dropoff[nickname]"), name, "form decoder: \(name)")
            XCTAssertFalse(url.absoluteString.contains("+"), "no raw plus: \(url.absoluteString)")
            XCTAssertFalse(url.absoluteString.contains("#"), "no fragment mark: \(url.absoluteString)")
            let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
            XCTAssertEqual(raw.split(separator: "&", omittingEmptySubsequences: false).count, 5, "five query parts: \(raw)")
        }
    }

    func testUBER_T05_accentsAndEmojiAreSentAsPercentEncodedUTF8() throws {
        let rows = [("Café Belén", "Caf%C3%A9%20Bel%C3%A9n"), ("🍕 Pizza", "%F0%9F%8D%95%20Pizza")]
        for (name, encoded) in rows {
            let url = try link(place(name))
            XCTAssertTrue(url.absoluteString.contains(encoded), "\(name) is sent as \(encoded): \(url.absoluteString)")
            XCTAssertTrue(url.absoluteString.allSatisfy(\.isASCII), "ASCII only: \(url.absoluteString)")
            XCTAssertEqual(value(try items(url), "dropoff[nickname]"), name, "component decoder: \(name)")
            XCTAssertEqual(formValue(url, "dropoff[nickname]"), name, "form decoder: \(name)")
        }
    }

    func testUBER_T06_aBlankNameLeavesTheNicknameOutAndANameIsTrimmed() throws {
        for blank in ["", "   ", " \n\t "] {
            let names = try items(try link(place(blank))).map(\.name)
            XCTAssertEqual(names, ["action", "pickup", "dropoff[latitude]", "dropoff[longitude]"],
                           "a blank name \(blank.debugDescription) leaves the nickname out")
        }
        let url = try link(place("  Ferry Building \n"))
        XCTAssertEqual(value(try items(url), "dropoff[nickname]"), "Ferry Building")
        XCTAssertTrue(url.absoluteString.hasSuffix("dropoff%5Bnickname%5D=Ferry%20Building"), url.absoluteString)
    }

    func testUBER_T07_aLongNameIsSentWhole() throws {
        let letters = Array("abcdef ")
        let name = String((0..<599).map { letters[$0 % letters.count] })
        XCTAssertEqual(name.count, 599)
        XCTAssertFalse(name.last?.isWhitespace ?? true, "the name has no trailing space to trim")
        let url = try link(place(name))
        XCTAssertEqual(value(try items(url), "dropoff[nickname]"), name, "component decoder keeps all 599 characters")
        XCTAssertEqual(formValue(url, "dropoff[nickname]"), name, "form decoder keeps all 599 characters")
    }

    // MARK: AC-004

    func testUBER_T08_aLinkExistsExactlyForAMapFramingValidCoordinate() {
        let rows: [(latitude: Double, longitude: Double, valid: Bool)] = [
            (.nan, -122.3937, false),
            (37.7955, .nan, false),
            (.infinity, -122.3937, false),
            (37.7955, -.infinity, false),
            (90.000001, 0, false),
            (-90.000001, 0, false),
            (0, 180.000001, false),
            (90, 180, true),
            (-90, -180, true),
            (0, 0, true),
            (37.7955, -122.3937, true),
        ]
        XCTAssertEqual(rows.count, 11)
        for row in rows {
            let label = "(\(row.latitude), \(row.longitude))"
            XCTAssertEqual(UberLink.url(for: place("Spot", row.latitude, row.longitude)) != nil, row.valid,
                           "a link exactly for a valid coordinate: \(label)")
            XCTAssertEqual(MapFraming.isValid(CLLocationCoordinate2D(latitude: row.latitude, longitude: row.longitude)),
                           row.valid, "MapFraming agrees: \(label)")
        }
    }
}
