import Network
import XCTest
@testable import ImmichSwiftUI

/// L-26: a change of network is a different path signature; the first reading is not.
final class SystemNetworkPathMonitorTests: XCTestCase {
    private func signature(
        _ status: NWPath.Status = .satisfied,
        _ interfaces: [(name: String, type: NWInterface.InterfaceType)] = [("en0", .wiredEthernet)],
        gateways: [String] = ["192.168.1.1"]
    ) -> String {
        SystemNetworkPathMonitor.signature(status: status, interfaces: interfaces, gateways: gateways)
    }

    func test_AC_236_firstReadingIsTheReferenceNotAChange() {
        var detector = NetworkPathChangeDetector()
        XCTAssertFalse(detector.changed(to: signature()))
        XCTAssertFalse(detector.changed(to: signature()), "same signature: no call")
    }

    func test_AC_236_otherWiFiWithAnotherGatewayIsAChange() {
        var detector = NetworkPathChangeDetector()
        _ = detector.changed(to: signature(.satisfied, [("en0", .wifi)], gateways: ["192.168.1.1"]))
        XCTAssertTrue(detector.changed(to: signature(.satisfied, [("en0", .wifi)], gateways: ["10.0.0.1"])))
    }

    func test_AC_236_lostThenBackIsTwoChanges() {
        var detector = NetworkPathChangeDetector()
        _ = detector.changed(to: signature(.satisfied))
        XCTAssertTrue(detector.changed(to: signature(.unsatisfied, [], gateways: [])))
        XCTAssertTrue(detector.changed(to: signature(.satisfied)))
    }

    func test_AC_236_interfaceOrderDoesNotMatter() {
        let a = signature(.satisfied, [("en0", .wifi), ("pdp_ip0", .cellular)])
        let b = signature(.satisfied, [("pdp_ip0", .cellular), ("en0", .wifi)])
        XCTAssertEqual(a, b)
    }

    func test_AC_236_gatewayOrderDoesNotMatter() {
        let a = signature(.satisfied, [("en0", .wifi)], gateways: ["192.168.1.1", "fe80::1"])
        let b = signature(.satisfied, [("en0", .wifi)], gateways: ["fe80::1", "192.168.1.1"])
        XCTAssertEqual(a, b)
        var detector = NetworkPathChangeDetector()
        _ = detector.changed(to: a)
        XCTAssertFalse(detector.changed(to: b))
    }

    func test_AC_236_statusAloneIsAChange() {
        var detector = NetworkPathChangeDetector()
        _ = detector.changed(to: signature(.satisfied, [("en0", .wifi)]))
        XCTAssertTrue(detector.changed(to: signature(.requiresConnection, [("en0", .wifi)])))
        XCTAssertTrue(detector.changed(to: signature(.unsatisfied, [("en0", .wifi)])))
    }

    func test_AC_236_interfacesAloneAreAChange() {
        var added = NetworkPathChangeDetector()
        _ = added.changed(to: signature(.satisfied, [("en0", .wifi)]))
        XCTAssertTrue(added.changed(to: signature(.satisfied, [("en0", .wifi), ("pdp_ip0", .cellular)])))

        var retyped = NetworkPathChangeDetector()
        _ = retyped.changed(to: signature(.satisfied, [("en0", .wifi)]))
        XCTAssertTrue(retyped.changed(to: signature(.satisfied, [("en0", .wiredEthernet)])), "same name, other type")
    }
}
