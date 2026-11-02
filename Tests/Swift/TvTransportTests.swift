import XCTest
@testable import Fusion
final class TvTransportTests:XCTestCase {
 func testOnlyExplicitPrivateTelevisionAddressesAreAccepted()throws{for s in ["192.168.1.2","http://10.0.0.2:18762/","172.31.1.1:1234"]{XCTAssertNoThrow(try TvTransport.address(s))};for s in ["127.0.0.1","8.8.8.8","example.com","192.168.1.2@8.8.8.8","192.168.001.1","172.32.1.1","192.168.1.1:80","192.168.1.1/else"]{XCTAssertThrowsError(try TvTransport.address(s),s)}}
}
