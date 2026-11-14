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

    func test_AC_49_firstReadingIsTheReferenceNotAChange() {
        var detector = NetworkPathChangeDetector()
        XCTAssertFalse(detector.changed(to: signature()))
        XCTAssertFalse(detector.changed(to: signature()), "same signature: no call")
    }

    func test_AC_49_otherWiFiWithAnotherGatewayIsAChange() {
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

    func test_AC_49_interfaceOrderDoesNotMatter() {
        let a = signature(.satisfied, [("en0", .wifi), ("pdp_ip0", .cellular)])
        let b = signature(.satisfied, [("pdp_ip0", .cellular), ("en0", .wifi)])
        XCTAssertEqual(a, b)
    }
}
