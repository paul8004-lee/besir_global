import Foundation
import MapKit

/// 장소 검색(자동완성). 카카오 로컬 키워드 검색을 우선 쓰고,
/// 키가 없으면 MapKit MKLocalSearch 로 폴백한다.
struct PlaceSearch {
    let config: AppConfig

    func search(_ query: String, near center: CLLocationCoordinate2D?) async -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        if config.hasProxy {
            if let kakao = try? await kakaoKeyword(trimmed), !kakao.isEmpty {
                return kakao
            }
        }
        return await mapKitSearch(trimmed, near: center)
    }

    // MARK: - 카카오 로컬 키워드 검색(프록시 경유)

    private func kakaoKeyword(_ query: String) async throws -> [Place] {
        guard let req = config.proxyRequest("/kakao/local/keyword", query: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "size", value: "10")
        ]) else { throw URLError(.badURL) }

        let (data, _) = try await URLSession.shared.data(for: req)
        struct Resp: Decodable {
            struct Doc: Decodable {
                let place_name: String
                let road_address_name: String?
                let address_name: String?
                let x: String   // 경도(lng)
                let y: String   // 위도(lat)
            }
            let documents: [Doc]
        }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        return resp.documents.compactMap { d in
            guard let lng = Double(d.x), let lat = Double(d.y) else { return nil }
            return Place(name: d.place_name,
                         address: d.road_address_name ?? d.address_name ?? "",
                         latitude: lat, longitude: lng)
        }
    }

    // MARK: - 주변 음식점 추천 (be full sir)

    /// 좌표 주변의 음식점·카페를 가까운 순으로 찾는다.
    /// 카카오 로컬의 `category_group_code`(FD6 음식점 / CE7 카페) + `x/y/radius` 조합을 쓴다 —
    /// 새 외부 API를 붙이지 않고 이미 있는 장소 검색 프록시를 그대로 재사용한다.
    /// 프록시가 없거나 결과가 없으면 빈 배열(호출부가 빈 상태 UI를 보여준다).
    /// - `keyword`: "일식", "초밥"처럼 구체적인 메뉴·업종.
    /// - `category`: nil이면 업종을 가리지 않고 검색한다(자유 입력 검색용).
    func nearbyPlaces(category: MealCategoryFilter?,
                      keyword: String? = nil,
                      near center: CLLocationCoordinate2D,
                      radiusMeters: Int = 1000,
                      sort: NearbySort = .distance,
                      limit: Int = 5) async -> [NearbyPlace] {
        guard config.hasProxy else { return [] }
        let term = keyword?.trimmingCharacters(in: .whitespaces)
        // 카카오는 query가 비면 안 된다 — 키워드가 없으면 카테고리 이름으로 대신한다.
        let query = (term?.isEmpty == false) ? term! : (category?.query ?? "맛집")
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "x", value: String(center.longitude)),
            URLQueryItem(name: "y", value: String(center.latitude)),
            // 카카오는 최대 20km까지 허용한다.
            URLQueryItem(name: "radius", value: String(min(max(radiusMeters, 100), 20_000))),
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "size", value: String(min(max(limit, 1), 15)))
        ]
        if let category { items.append(URLQueryItem(name: "category_group_code", value: category.code)) }
        guard let req = config.proxyRequest("/kakao/local/keyword", query: items) else { return [] }

        struct Resp: Decodable {
            struct Doc: Decodable {
                let place_name: String
                let category_name: String?
                let road_address_name: String?
                let address_name: String?
                let phone: String?
                let place_url: String?
                let distance: String?
                let x: String
                let y: String
            }
            let documents: [Doc]
        }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let resp = try? JSONDecoder().decode(Resp.self, from: data) else { return [] }
        return resp.documents.compactMap { d in
            guard let lng = Double(d.x), let lat = Double(d.y) else { return nil }
            return NearbyPlace(
                place: Place(name: d.place_name,
                             address: d.road_address_name ?? d.address_name ?? "",
                             latitude: lat, longitude: lng),
                // "음식점 > 한식 > 국밥"에서 마지막 조각만 쓴다(앞은 어차피 다 "음식점").
                category: d.category_name?.split(separator: ">").last.map {
                    $0.trimmingCharacters(in: .whitespaces)
                } ?? "",
                distanceMeters: d.distance.flatMap { Int($0) },
                phone: (d.phone?.isEmpty == false) ? d.phone : nil,
                url: d.place_url)
        }
    }

    // MARK: - MapKit 폴백

    private func mapKitSearch(_ query: String, near center: CLLocationCoordinate2D?) async -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let center {
            request.region = MKCoordinateRegion(center: center,
                                                latitudinalMeters: 30_000,
                                                longitudinalMeters: 30_000)
        }
        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start() else { return [] }
        return response.mapItems.prefix(10).map { item in
            let p = item.placemark
            let parts = [p.thoroughfare, p.subThoroughfare, p.locality].compactMap { $0 }
            return Place(name: item.name ?? p.name ?? query,
                         address: p.title ?? parts.joined(separator: " "),
                         latitude: p.coordinate.latitude,
                         longitude: p.coordinate.longitude)
        }
    }
}
