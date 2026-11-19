import XCTest
import CoreGraphics
@testable import ImmichSwiftUI

final class RoadTripFramePlanTests: XCTestCase {

    private func makeAsset(id: String, time: String = "2024-07-01T00:00:00.000Z") -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 1.0, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: nil,
            createdAt: time, fileCreatedAt: time,
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil,
            projectionType: nil, city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private func makeCluster(id: String, count: Int, lat: Double = 48.85, lon: Double = 2.29) -> RoadTripCluster {
        let assets = (0..<count).map { makeAsset(id: "\(id)-\($0)") }
        return RoadTripCluster(
            id: id, assets: assets, latitude: lat, longitude: lon,
            placeName: nil,
            startDate: ISO8601.immichFormatter.date(from: "2024-07-01T00:00:00.000Z"),
            endDate: nil
        )
    }

    // MARK: - Timeline builder

    func test_build_singleCluster_noTravel() {
        let clusters = [makeCluster(id: "c1", count: 4)]
        let timeline = RoadTripTimelineBuilder.build(clusters: clusters, legs: [])
        XCTAssertNotNil(timeline)
        let kinds = timeline!.segments.map { seg -> String in
            switch seg {
            case .opening: return "opening"
            case .slideshow: return "slideshow"
            case .travel: return "travel"
            case .ending: return "ending"
            }
        }
        XCTAssertEqual(kinds, ["opening", "slideshow", "ending"])
    }

    func test_build_twoClusters_interleavesTravel() {
        let clusters = [makeCluster(id: "c1", count: 3), makeCluster(id: "c2", count: 3)]
        let leg = RoadTripLeg(
            fromClusterID: "c1", toClusterID: "c2", distanceMeters: 5000,
            route: [RoutePoint(latitude: 48.85, longitude: 2.29), RoutePoint(latitude: 48.86, longitude: 2.30)]
        )
        let timeline = RoadTripTimelineBuilder.build(clusters: clusters, legs: [leg])
        XCTAssertNotNil(timeline)
        let kinds = timeline!.segments.map { seg -> String in
            switch seg {
            case .opening: return "opening"
            case .slideshow: return "slideshow"
            case .travel: return "travel"
            case .ending: return "ending"
            }
        }
        XCTAssertEqual(kinds, ["opening", "slideshow", "travel", "slideshow", "ending"])
    }

    func test_build_keepsPhotosPerCluster() {
        // 5 clusters × 6 photos, 4 short legs (2 s each): a hero per stop,
        // then the 9 photos left of the 14 go to the climax stops first —
        // [3,3,3,3,2] — and the film stays a short clip.
        let clusters = (0..<5).map { makeCluster(id: "c\($0)", count: 6) }
        var legs: [RoadTripLeg] = []
        for i in 0..<4 {
            legs.append(RoadTripLeg(
                fromClusterID: "c\(i)", toClusterID: "c\(i+1)", distanceMeters: 4000,
                route: [RoutePoint(latitude: 48.85, longitude: 2.29), RoutePoint(latitude: 48.86, longitude: 2.30)]
            ))
        }
        let timeline = RoadTripTimelineBuilder.build(clusters: clusters, legs: legs)
        XCTAssertNotNil(timeline)
        let slideshowCounts = timeline!.segments.compactMap { seg -> Int? in
            if case .slideshow(let s) = seg { return s.assetIndices.count }
            return nil
        }
        XCTAssertEqual(slideshowCounts, [3, 3, 3, 3, 2])
        XCTAssertEqual(timeline!.totalDuration, 30.5, accuracy: 0.001)
        XCTAssertLessThanOrEqual(timeline!.totalDuration, RoadTripTimelineBuilder.targetDuration)
    }

    func test_build_everyDurationLandsOnTheBeat() throws {
        let clusters = (0..<4).map { makeCluster(id: "c\($0)", count: 5) }
        let legs = (0..<3).map { i in
            RoadTripLeg(
                fromClusterID: "c\(i)", toClusterID: "c\(i + 1)", distanceMeters: 30_000,
                route: [RoutePoint(latitude: 48.85, longitude: 2.29), RoutePoint(latitude: 48.85 + 0.1 * Double(i + 1), longitude: 2.5)]
            )
        }
        let timeline = try XCTUnwrap(RoadTripTimelineBuilder.build(clusters: clusters, legs: legs))
        let beat = RoadTripTimelineBuilder.beat
        for start in timeline.segmentStartTimes {
            let beats = start / beat
            XCTAssertEqual(beats, beats.rounded(), accuracy: 1e-9, "a cut at \(start) s is off the beat")
        }
        for case let .slideshow(slideshow) in timeline.segments {
            XCTAssertEqual(slideshow.photoDurations.first, RoadTripTimelineBuilder.heroPhotoDuration, "a stop opens on its hero photo")
        }
    }

    func test_build_capsPhotosPerCluster() {
        // 20 clusters × 20 photos → budget floor: one photo per stop, still
        // under the target duration.
        let clusters = (0..<20).map { makeCluster(id: "c\($0)", count: 20) }
        let timeline = RoadTripTimelineBuilder.build(clusters: clusters, legs: [])
        XCTAssertNotNil(timeline)
        for case let .slideshow(slideshow) in timeline!.segments {
            XCTAssertEqual(slideshow.assetIndices.count, 1)
        }
        XCTAssertLessThanOrEqual(timeline!.totalDuration, RoadTripTimelineBuilder.targetDuration)
    }

    func test_energy_arcPeaksInMiddle() {
        XCTAssertEqual(RoadTripTimelineBuilder.energy(at: 0, count: 5), 0.35, accuracy: 0.0001)
        XCTAssertEqual(RoadTripTimelineBuilder.energy(at: 2, count: 5), 1.0, accuracy: 0.0001)
        XCTAssertEqual(RoadTripTimelineBuilder.energy(at: 4, count: 5), 0.35, accuracy: 0.0001)
    }

    // MARK: - Credits dedupe

    func test_dedupedPlaceNames_collapsesDuplicates() {
        let names = ["Paris, France", "Paris, France", "Sineu, Spain", "PARIS, France", "Sóller, Spain"]
        XCTAssertEqual(RoadTripTimeline.dedupedPlaceNames(names), ["Paris, France", "Sineu, Spain", "Sóller, Spain"])
    }

    func test_dedupedPlaceNames_dropsEmptyAndKeepsOrder() {
        XCTAssertEqual(RoadTripTimeline.dedupedPlaceNames(["", "A", "", "B"]), ["A", "B"])
        XCTAssertEqual(RoadTripTimeline.dedupedPlaceNames([]), [])
    }

    func test_rank_favoritesFirstThenScore() {
        let assets = [
            makeAsset(id: "a"),
            makeAsset(id: "b"),
            makeAsset(id: "c"),
            makeAsset(id: "d")
        ]
        let cluster = RoadTripCluster(
            id: "c", assets: assets, latitude: nil, longitude: nil, placeName: nil,
            startDate: nil, endDate: nil
        )
        // "d" is a favorite → first; then best score among the rest.
        var favCluster = cluster
        favCluster = RoadTripCluster(
            id: "c",
            assets: [
                assets[0], assets[1], assets[2],
                AssetReactItem(
                    id: "d", ownerId: "owner", ratio: 1.0, isFavorite: true, visibility: "timeline",
                    isTrashed: false, isImage: true, thumbhash: nil,
                    createdAt: "2024-07-01T00:00:00.000Z", fileCreatedAt: "2024-07-01T00:00:00.000Z",
                    localOffsetHours: 0, duration: nil, livePhotoVideoId: nil,
                    projectionType: nil, city: nil, country: nil, latitude: nil, longitude: nil, stack: []
                )
            ],
            latitude: nil, longitude: nil, placeName: nil, startDate: nil, endDate: nil
        )
        let scores = ["a": 0.8, "b": 0.3, "c": 0.6, "d": 0.1]
        let rank = RoadTripTimelineBuilder.rank(for: favCluster, scores: scores)
        XCTAssertEqual(rank.first, 3)
        // Remaining sorted by score: a(0.8), c(0.6), b(0.3).
        XCTAssertEqual(Array(rank.dropFirst()), [0, 2, 1])
        // Selection keeps chronological order.
        let selected = RoadTripTimelineBuilder.selectedIndices(kept: 3, count: 4, rank: rank)
        XCTAssertEqual(selected, [0, 2, 3])
    }

    func test_build_emptyOrEmptyClusters_returnsNil() {
        XCTAssertNil(RoadTripTimelineBuilder.build(clusters: [], legs: []))
        let emptyCluster = RoadTripCluster(id: "x", assets: [], latitude: nil, longitude: nil, placeName: nil, startDate: nil, endDate: nil)
        XCTAssertNil(RoadTripTimelineBuilder.build(clusters: [emptyCluster], legs: []))
    }

    // MARK: - Helpers

    func test_travelDuration_shortBurstOnTheBeat() {
        // (1.5 + 0.6·log2(1 + km/5)) · (1 − 0.15·energy), snapped to 0.5 s, within 2…3.5 s.
        XCTAssertEqual(RoadTripTimelineBuilder.travelDuration(arcMeters: 0, energy: 0), 2.0)
        XCTAssertEqual(RoadTripTimelineBuilder.travelDuration(arcMeters: 2_000, energy: 0), 2.0)
        XCTAssertEqual(RoadTripTimelineBuilder.travelDuration(arcMeters: 20_000, energy: 0), 3.0)
        XCTAssertEqual(RoadTripTimelineBuilder.travelDuration(arcMeters: 1_000_000, energy: 0), 3.5)
        // Climax (energy = 1) trims the leg.
        XCTAssertEqual(RoadTripTimelineBuilder.travelDuration(arcMeters: 20_000, energy: 1), 2.5)
    }

    func test_selectedIndices_evenlySpaced() {
        XCTAssertEqual(RoadTripTimelineBuilder.selectedIndices(kept: 1, count: 10), [0])
        XCTAssertEqual(RoadTripTimelineBuilder.selectedIndices(kept: 10, count: 10), Array(0..<10))
        let five = RoadTripTimelineBuilder.selectedIndices(kept: 5, count: 10)
        XCTAssertEqual(five.count, 5)
        XCTAssertEqual(five.first, 0)
        XCTAssertEqual(five.last, 9)
    }

    func test_photoDurations_heroThenTwoBeats() {
        XCTAssertEqual(RoadTripTimelineBuilder.photoDurations(kept: 4), [1.5, 1.0, 1.0, 1.0])
        XCTAssertEqual(RoadTripTimelineBuilder.photoDurations(kept: 1), [1.5])
        XCTAssertEqual(RoadTripTimelineBuilder.photoDurations(kept: 0), [])
    }

    // MARK: - Road counter

    func test_drivenMeters_countsLegsBehindAndTheCarsShareOfTheCurrentOne() {
        let first = RoadTripTimeline.Travel(
            fromClusterID: "a", toClusterID: "b", distanceMeters: 1_000,
            route: [RoutePoint(latitude: 0, longitude: 0), RoutePoint(latitude: 0, longitude: 0.1)], duration: 2
        )
        let second = RoadTripTimeline.Travel(
            fromClusterID: "b", toClusterID: "c", distanceMeters: 1_000,
            route: [RoutePoint(latitude: 0, longitude: 0.1), RoutePoint(latitude: 0, longitude: 0.3)], duration: 2
        )
        func stop(_ id: String) -> RoadTripTimeline.Segment {
            .slideshow(RoadTripTimeline.Slideshow(clusterID: id, assetIndices: [0], photoDurations: [1], recipeOffset: 0, energy: 0.5))
        }
        // opening 1 | a 1 | leg 2 (2…4) | b 1 | leg 2 (5…7) | c 1 | ending 1
        let timeline = RoadTripTimeline(segments: [
            .opening(duration: 1), stop("a"), .travel(first), stop("b"), .travel(second), stop("c"), .ending(duration: 1)
        ])
        let firstArc = RoadTripTimeline.arcMeters(first)
        let secondArc = RoadTripTimeline.arcMeters(second)
        XCTAssertEqual(firstArc, 11_120, accuracy: 50, "0.1° of longitude at the equator")
        XCTAssertEqual(timeline.drivenMeters(at: 0.5), 0)
        XCTAssertEqual(timeline.drivenMeters(at: 3), firstArc / 2, accuracy: 1, "half the first leg at its middle")
        XCTAssertEqual(timeline.drivenMeters(at: 4.5), firstArc, accuracy: 1)
        XCTAssertEqual(timeline.drivenMeters(at: 6), firstArc + secondArc / 2, accuracy: 1)
        XCTAssertEqual(timeline.drivenMeters(at: 100), firstArc + secondArc, accuracy: 1)
        XCTAssertEqual(timeline.totalDrivenMeters, firstArc + secondArc, accuracy: 1)
    }

    func test_distanceText_kilometersOrMilesByLocale() {
        let french = RoadTripTimeline.distanceText(meters: 142_400, locale: Locale(identifier: "fr_FR"))
        XCTAssertTrue(french.hasPrefix("142"), french)
        XCTAssertTrue(french.contains("km"), french)
        let american = RoadTripTimeline.distanceText(meters: 160_934, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(american.hasPrefix("100"), american)
        XCTAssertTrue(american.contains("mi"), american)
        let short = RoadTripTimeline.distanceText(meters: 2_500, locale: Locale(identifier: "en_GB"))
        XCTAssertTrue(short.hasPrefix("1.6"), "under 10, one decimal (and miles on British roads): \(short)")
    }

    // MARK: - Ken Burns

    func test_kenBurns_identityWhenReduceMotion() {
        let t = KenBurnsRecipe.transform(motion: .zoomIn, progress: 0.5, reduceMotion: true)
        XCTAssertEqual(t, .identity)
    }

    func test_kenBurns_scaleBounds() {
        for motion in KenBurnsMotion.allCases {
            for p in stride(from: 0.0, through: 1.0, by: 0.1) {
                let t = KenBurnsRecipe.transform(motion: motion, progress: p, reduceMotion: false)
                XCTAssertGreaterThanOrEqual(t.scale, 1.0)
                XCTAssertLessThanOrEqual(t.scale, 1.13)
                XCTAssertGreaterThanOrEqual(t.offsetX, -0.07)
                XCTAssertLessThanOrEqual(t.offsetX, 0.07)
            }
        }
    }

    func test_kenBurns_motionDeterministic() {
        XCTAssertEqual(KenBurnsRecipe.motion(at: 0, offset: 7), KenBurnsRecipe.motion(at: 0, offset: 7))
    }

    // MARK: - Slide timing

    func test_slideTiming_walksPhotos() {
        let slideshow = RoadTripTimeline.Slideshow(
            clusterID: "c", assetIndices: [0, 1, 2],
            photoDurations: [2.4, 2.6, 2.4], recipeOffset: 0, energy: 1.0
        )
        let f0 = RoadTripSlideTiming.frame(slideshow: slideshow, localTime: 0, reduceMotion: false)
        XCTAssertEqual(f0.currentIndex, 0)
        let f1 = RoadTripSlideTiming.frame(slideshow: slideshow, localTime: 3.0, reduceMotion: false)
        XCTAssertEqual(f1.currentIndex, 1)
        let f2 = RoadTripSlideTiming.frame(slideshow: slideshow, localTime: 5.1, reduceMotion: false)
        XCTAssertEqual(f2.currentIndex, 2)
    }

    func test_slideTiming_crossfadeAtTail() {
        let slideshow = RoadTripTimeline.Slideshow(
            clusterID: "c", assetIndices: [0, 1],
            photoDurations: [2.4, 2.4], recipeOffset: 0, energy: 1.0
        )
        let mid = RoadTripSlideTiming.frame(slideshow: slideshow, localTime: 1.0, reduceMotion: false)
        XCTAssertNil(mid.nextIndex)
        XCTAssertEqual(mid.crossfade, 0)
        let tail = RoadTripSlideTiming.frame(slideshow: slideshow, localTime: 2.3, reduceMotion: false)
        XCTAssertEqual(tail.nextIndex, 1)
        XCTAssertGreaterThan(tail.crossfade, 0)
        // Last slide: no crossfade.
        let last = RoadTripSlideTiming.frame(slideshow: slideshow, localTime: 3.0, reduceMotion: false)
        XCTAssertNil(last.nextIndex)
    }

    // MARK: - Travel timing

    func test_travelTiming_interpolates() {
        let travel = RoadTripTimeline.Travel(
            fromClusterID: "a", toClusterID: "b", distanceMeters: 1000,
            route: [
                RoutePoint(latitude: 0, longitude: 0),
                RoutePoint(latitude: 0, longitude: 0.1)
            ],
            duration: 4
        )
        let start = RoadTripTravelTiming.frame(travel: travel, localTime: 0)
        XCTAssertEqual(start.carCoordinate, RoutePoint(latitude: 0, longitude: 0))
        let end = RoadTripTravelTiming.frame(travel: travel, localTime: 4)
        XCTAssertEqual(end.carCoordinate.longitude, 0.1, accuracy: 0.0001)
        XCTAssertEqual(end.routeDrawnFraction, 1, accuracy: 0.001)
        let mid = RoadTripTravelTiming.frame(travel: travel, localTime: 2)
        XCTAssertGreaterThan(mid.carCoordinate.longitude, 0)
        XCTAssertLessThan(mid.carCoordinate.longitude, 0.1)
        // Eased (not linear) at the midpoint.
        XCTAssertEqual(mid.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(mid.carCoordinate.longitude, 0.05, accuracy: 0.01)
    }

    func test_travelTiming_trimmedRouteGrows() {
        let route = (0...10).map { RoutePoint(latitude: 0, longitude: Double($0) * 0.01) }
        let travel = RoadTripTimeline.Travel(fromClusterID: "a", toClusterID: "b", distanceMeters: 1000, route: route, duration: 4)
        let half = RoadTripTravelTiming.frame(travel: travel, localTime: 2)
        XCTAssertGreaterThan(half.trimmedRoute.count, 1)
        XCTAssertLessThanOrEqual(half.trimmedRoute.count, route.count + 1)
    }

    // MARK: - Segment transitions

    func test_segue_diveProgressWindow() {
        XCTAssertEqual(RoadTripSegue.diveProgress(localTime: 0, legDuration: 4), 0)
        XCTAssertEqual(RoadTripSegue.diveProgress(localTime: 3.4, legDuration: 4), 0)
        XCTAssertEqual(RoadTripSegue.diveProgress(localTime: 3.7, legDuration: 4), 0.5, accuracy: 0.001)
        XCTAssertEqual(RoadTripSegue.diveProgress(localTime: 4, legDuration: 4), 1)
        XCTAssertEqual(RoadTripSegue.diveProgress(localTime: 0, legDuration: 0.3), 0)
        XCTAssertEqual(RoadTripSegue.diveProgress(localTime: 0.3, legDuration: 0.3), 0.5, accuracy: 0.001)
    }

    func test_segue_mapFadeMonotonic() {
        XCTAssertEqual(RoadTripSegue.mapFade(0), 0)
        XCTAssertEqual(RoadTripSegue.mapFade(RoadTripSegue.thumbRevealFraction), 0, accuracy: 0.0001)
        XCTAssertEqual(RoadTripSegue.mapFade(1), 1)
        var prev = RoadTripSegue.mapFade(0.35)
        for x in stride(from: 0.4, through: 1.0, by: 0.05) {
            let f = RoadTripSegue.mapFade(x)
            XCTAssertGreaterThanOrEqual(f, prev - 0.0001, "map fade must be monotonic")
            prev = f
        }
    }

    func test_segue_pinPopOvershootsThenSettles() {
        XCTAssertEqual(RoadTripSegue.pinPop(0), 1.35, accuracy: 0.001)
        XCTAssertEqual(RoadTripSegue.pinPop(1), 1, accuracy: 0.001)
        var prev = RoadTripSegue.pinPop(0)
        for x in stride(from: 0.05, through: 1.0, by: 0.05) {
            let p = RoadTripSegue.pinPop(x)
            XCTAssertLessThanOrEqual(p, prev + 0.0001, "pin pop must settle monotonically")
            prev = p
        }
    }

    func test_segue_thumbnailRectInterpolates() {
        let canvas = CGSize(width: 1000, height: 2000)
        let pin = CGPoint(x: 100, y: 100)
        let size = CGSize(width: 50, height: 40)
        let start = RoadTripSegue.thumbnailRect(pinCenter: pin, pinSize: size, canvas: canvas, dive: 0)
        XCTAssertEqual(start, CGRect(x: 75, y: 80, width: 50, height: 40))
        let mid = RoadTripSegue.thumbnailRect(pinCenter: pin, pinSize: size, canvas: canvas, dive: 0.5)
        XCTAssertEqual(mid.midX, 300, accuracy: 0.001)
        XCTAssertEqual(mid.width, 525, accuracy: 0.001)
        let end = RoadTripSegue.thumbnailRect(pinCenter: pin, pinSize: size, canvas: canvas, dive: 1)
        XCTAssertEqual(end, CGRect(origin: .zero, size: canvas))
    }

    func test_segue_outgoingPhotoFadesOut() {
        XCTAssertEqual(RoadTripSegue.outgoingPhotoAlpha(localTime: 0), 1)
        XCTAssertEqual(RoadTripSegue.outgoingPhotoAlpha(localTime: RoadTripSegue.photoFadeOutDuration), 0, accuracy: 0.0001)
        XCTAssertEqual(RoadTripSegue.outgoingPhotoAlpha(localTime: 10), 0)
        XCTAssertGreaterThan(RoadTripSegue.outgoingPhotoAlpha(localTime: 0.1), 0.5)
    }

    // MARK: - Curvature-aware speed

    /// Straight east half (~2 km) followed by a ±50 m zigzag half (~2 km).
    private func makeZigzagRoute() -> [RoutePoint] {
        let degPerMeter = 1.0 / (111_320.0 * cos(48.85 * .pi / 180))
        let latDeg = 1.0 / 111_320.0
        var route: [RoutePoint] = []
        for i in 0..<20 { route.append(RoutePoint(latitude: 48.85, longitude: 2.29 + Double(i) * 100 * degPerMeter)) }
        for i in 0..<20 {
            let zig = i % 2 == 0 ? 50.0 : -50.0
            route.append(RoutePoint(latitude: 48.85 + zig * latDeg, longitude: 2.29 + Double(20 + i) * 100 * degPerMeter))
        }
        return route
    }

    private func makeStraightRoute() -> [RoutePoint] {
        (0..<30).map { RoutePoint(latitude: 48.85, longitude: 2.29 + Double($0) * 0.001) }
    }

    func test_twistiness_straightRouteIsZero() {
        XCTAssertEqual(RoadTripTravelTiming.twistiness(makeStraightRoute()), 0)
    }

    func test_twistiness_windingRouteIsPositive() {
        XCTAssertGreaterThan(RoadTripTravelTiming.twistiness(makeZigzagRoute()), 0)
    }

    func test_arcFraction_slowsThroughCorners() {
        // Straight first half (fast) + winding second half (slow): by the
        // halfway TIME mark the car is past the halfway ARC mark.
        let route = makeZigzagRoute()
        let mid = RoadTripTravelTiming.arcFraction(atTimeFraction: 0.5, route: route)
        XCTAssertGreaterThan(mid, 0.5, "the car covers the cheap straight faster than the winding half")

        // A perfectly straight route maps time 1:1 to arc.
        let straight = makeStraightRoute()
        XCTAssertEqual(RoadTripTravelTiming.arcFraction(atTimeFraction: 0.5, route: straight), 0.5, accuracy: 0.001)
    }

    // MARK: - Collage

    /// A stop of `count` photos taken a minute apart (no burst).
    private func spacedCluster(id: String, count: Int) -> RoadTripCluster {
        let assets = (0..<count).map { makeAsset(id: "\(id)-\($0)", time: String(format: "2024-07-01T10:%02d:00.000Z", $0)) }
        return RoadTripCluster(id: id, assets: assets, latitude: 48.85, longitude: 2.29, placeName: nil, startDate: nil, endDate: nil)
    }

    private func slideshows(_ timeline: RoadTripTimeline?) -> [RoadTripTimeline.Slideshow] {
        (timeline?.segments ?? []).compactMap {
            if case .slideshow(let slideshow) = $0 { return slideshow }
            return nil
        }
    }

    func test_collage_opensAStopOnItsGoodPhotos() {
        let cluster = spacedCluster(id: "c", count: 4)
        // The bar is relative: 80 % of the stop's best (0.9) — 0.75 is in.
        let scores = ["c-0": 0.2, "c-1": 0.9, "c-2": 0.8, "c-3": 0.75]
        let aspects = ["c-0": 1.5, "c-1": 1.5, "c-2": 1.5, "c-3": 1.5]
        let slideshow = try? XCTUnwrap(slideshows(RoadTripTimelineBuilder.build(clusters: [cluster], legs: [], scores: scores, aspects: aspects)).first)

        XCTAssertEqual(slideshow?.collageCount, 3, "the three good photos, not the weak one")
        XCTAssertEqual(Set(slideshow.map { Array($0.assetIndices.prefix(3)) } ?? []), [1, 2, 3])
        XCTAssertEqual(slideshow?.photoDurations.first, RoadTripCollage.duration(tiles: 3))
        XCTAssertEqual(RoadTripCollage.duration(tiles: 3), 2.5)
        for duration in slideshow?.photoDurations ?? [] {
            XCTAssertEqual((duration / RoadTripTimelineBuilder.beat).rounded(), duration / RoadTripTimelineBuilder.beat, accuracy: 1e-9)
        }
        XCTAssertEqual(slideshow?.photoDurations.count, (slideshow?.assetIndices.count ?? 0) - 2, "one duration per slide")
    }

    func test_collage_needsAGoodBestPhotoAndSkipsBursts() {
        let weak = spacedCluster(id: "w", count: 3)
        let weakScores = ["w-0": 0.3, "w-1": 0.3, "w-2": 0.2]
        XCTAssertEqual(slideshows(RoadTripTimelineBuilder.build(clusters: [weak], legs: [], scores: weakScores)).first?.collageCount, 1)

        // Three shots of one burst (seconds apart) and one later photo.
        let times = ["2024-07-01T10:00:00.000Z", "2024-07-01T10:00:03.000Z", "2024-07-01T10:00:06.000Z", "2024-07-01T10:30:00.000Z"]
        let assets = times.enumerated().map { makeAsset(id: "b-\($0.offset)", time: $0.element) }
        let burst = RoadTripCluster(id: "b", assets: assets, latitude: nil, longitude: nil, placeName: nil, startDate: nil, endDate: nil)
        let scores = ["b-0": 0.9, "b-1": 0.85, "b-2": 0.8, "b-3": 0.75]
        let candidates = RoadTripTimelineBuilder.collageCandidates(
            in: burst, rank: RoadTripTimelineBuilder.rank(for: burst, scores: scores), scores: scores
        )
        XCTAssertEqual(candidates, [0, 3], "one photo of the burst, then the later one")
    }

    func test_collageModesAndPhotosPerStop() {
        let cluster = spacedCluster(id: "c", count: 4)
        let scores = ["c-0": 0.9, "c-1": 0.5, "c-2": 0.4, "c-3": 0.3]
        func first(_ options: RoadTripTimelineBuilder.Options) -> RoadTripTimeline.Slideshow? {
            slideshows(RoadTripTimelineBuilder.build(clusters: [cluster], legs: [], scores: scores, options: options)).first
        }
        XCTAssertEqual(first(.init(collages: .auto))?.collageCount, 1, "0.5 is far below the stop's 0.9")
        XCTAssertEqual(first(.init(collages: .max))?.collageCount, 4, "every usable photo joins")
        XCTAssertEqual(first(.init(collages: .off))?.collage, [])
        XCTAssertEqual(first(.init(collages: .max, maxPhotosPerStop: 2))?.assetIndices.count, 2)
        XCTAssertEqual(first(.init(collages: .off, maxPhotosPerStop: 1))?.assetIndices, [0])
        let longer = RoadTripTimelineBuilder.build(clusters: [cluster], legs: [], options: .init(targetDuration: 60))
        XCTAssertNotNil(longer)
    }

    func test_pinnedPhotosAreShownFirst() {
        let cluster = spacedCluster(id: "c", count: 5)
        let scores = ["c-0": 0.9, "c-1": 0.8, "c-2": 0.1, "c-3": 0.7, "c-4": 0.05]
        let options = RoadTripTimelineBuilder.Options(maxPhotosPerStop: 2, pinned: ["c-2", "c-4"])
        let slideshow = slideshows(RoadTripTimelineBuilder.build(clusters: [cluster], legs: [], scores: scores, options: options)).first
        XCTAssertEqual(Set(slideshow?.assetIndices ?? []), [2, 4], "the pinned photos, however weak")
        XCTAssertEqual(slideshow?.collageCount, 2, "pinned together, they open the stop")
    }

    func test_collage_noScoresNoCollage() {
        let timeline = RoadTripTimelineBuilder.build(clusters: [spacedCluster(id: "c", count: 4)], legs: [])
        XCTAssertTrue(slideshows(timeline).allSatisfy { $0.collage.isEmpty })
    }

    func test_collageLayouts_fitTheirPhotos() {
        func tileAspect(_ tile: RoadTripCollage.Tile) -> Double {
            Double(tile.rect.width / tile.rect.height) * RoadTripCollage.canvasAspect
        }
        // Two landscapes: stacked, each wide.
        let two = RoadTripCollage.layout(aspects: [1.5, 1.33])
        XCTAssertEqual(two.tiles.count, 2)
        XCTAssertTrue(two.tiles.allSatisfy { tileAspect($0) > 1 })
        // Two portraits: one full screen, one framed print over it.
        let prints = RoadTripCollage.layout(aspects: [0.75, 0.75])
        XCTAssertEqual(prints.tiles[0].rect, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertTrue(prints.tiles[1].framed)
        XCTAssertNotEqual(prints.tiles[1].rotation, 0)
        // A landscape first, a portrait second: the portrait takes the top.
        let mixed = RoadTripCollage.layout(aspects: [1.5, 0.75])
        XCTAssertEqual(mixed.order, [1, 0])
        XCTAssertLessThan(tileAspect(mixed.tiles[0]), tileAspect(mixed.tiles[1]))
        // Three landscapes: three wide bands.
        let bands = RoadTripCollage.layout(aspects: [1.5, 1.5, 1.5])
        XCTAssertTrue(bands.tiles.allSatisfy { tileAspect($0) > 1.5 })
        // Two portraits and a landscape: the landscape across the top.
        let three = RoadTripCollage.layout(aspects: [0.75, 0.75, 1.5])
        XCTAssertEqual(three.order.first, 2)
        XCTAssertGreaterThan(tileAspect(three.tiles[0]), 1)
        XCTAssertTrue(three.tiles.dropFirst().allSatisfy { tileAspect($0) < 1 })
        // Four portraits: a 2 × 2 grid.
        let grid = RoadTripCollage.layout(aspects: [0.75, 0.75, 0.75, 0.75])
        XCTAssertEqual(grid.tiles.count, 4)
        XCTAssertTrue(grid.tiles.allSatisfy { tileAspect($0) < 1 })
        // Every layout stays on the canvas, every photo used once.
        for layout in [two, prints, mixed, bands, three, grid] {
            XCTAssertEqual(layout.order.sorted(), Array(0..<layout.tiles.count))
            for tile in layout.tiles {
                XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -1e-9, dy: -1e-9).contains(tile.rect))
            }
        }
    }

    func test_collageTiles_allTogetherPushingIn() {
        let layout = RoadTripCollage.layout(aspects: [1.5, 1.5, 1.5])
        let slideshow = RoadTripTimeline.Slideshow(
            clusterID: "c", assetIndices: [0, 1, 2, 3], photoDurations: [RoadTripCollage.duration(tiles: 3), 1],
            recipeOffset: 0, energy: 0.5, collage: layout.tiles
        )
        let canvas = CGSize(width: 90, height: 160)
        let opening = RoadTripCollage.drawnTiles(slideshow: slideshow, localTime: 0, canvas: canvas, reduceMotion: false)
        XCTAssertEqual(opening.map(\.position), [0, 1, 2], "every tile from the first frame")
        XCTAssertTrue(opening.allSatisfy { $0.alpha == 1 && $0.zoom == 1 })
        XCTAssertEqual(opening[1].rect.minY, layout.tiles[1].rect.minY * 160, accuracy: 1e-6)
        let closing = RoadTripCollage.drawnTiles(slideshow: slideshow, localTime: 2.5, canvas: canvas, reduceMotion: false)
        XCTAssertEqual(closing[0].zoom, 1 + RoadTripCollage.pushIn, accuracy: 1e-9, "each photo pushes in")
        XCTAssertEqual(closing[0].rect, opening[0].rect, "the tiles themselves stay put")
        let still = RoadTripCollage.drawnTiles(slideshow: slideshow, localTime: 2.5, canvas: canvas, reduceMotion: true)
        XCTAssertTrue(still.allSatisfy { $0.zoom == 1 })

        // Slides: the collage, then the stop's fourth photo.
        XCTAssertEqual(slideshow.positions(ofSlide: 0), 0..<3)
        XCTAssertEqual(slideshow.positions(ofSlide: 1), 3..<4)
        XCTAssertEqual(RoadTripSlideTiming.frame(slideshow: slideshow, localTime: 2.6, reduceMotion: false).currentIndex, 1)

        // The dive lands on the collage; the slideshow ends on its photo.
        let first = RoadTripSlideTiming.edgeTiles(slideshow: slideshow, first: true, reduceMotion: false, canvas: canvas)
        XCTAssertEqual(first.map(\.position), [0, 1, 2])
        XCTAssertEqual(first[0].rect.height, layout.tiles[0].rect.height * 160, accuracy: 1e-6)
        let last = RoadTripSlideTiming.edgeTiles(slideshow: slideshow, first: false, reduceMotion: false, canvas: canvas)
        XCTAssertEqual(last.map(\.position), [3])
    }
}
