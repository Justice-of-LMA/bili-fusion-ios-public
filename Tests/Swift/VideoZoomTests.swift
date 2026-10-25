import XCTest
import UIKit
import AVFoundation
@testable import Fusion

final class VideoZoomTests:XCTestCase {
    @MainActor func testZoomChangesOnlyVideoSublayerAndClipsInsideItsWindow() {
        let surface=VideoSurface(frame:CGRect(x:15,y:20,width:640,height:360)),original=surface.frame
        surface.zoom(scale:2,x:60,y:-30)
        XCTAssertEqual(surface.frame,original);XCTAssertEqual(surface.bounds.size,CGSize(width:640,height:360));XCTAssertTrue(surface.clipsToBounds)
        XCTAssertEqual(surface.videoLayer.affineTransform().a,2,accuracy:0.001);XCTAssertEqual(surface.videoLayer.affineTransform().d,2,accuracy:0.001)
        XCTAssertEqual(surface.videoLayer.position.x,380,accuracy:0.001);XCTAssertEqual(surface.videoLayer.position.y,150,accuracy:0.001)
        XCTAssertEqual(surface.layer.affineTransform(),.identity,"Do not enlarge the whole A/B window or UI")
        surface.zoom(scale:4,x:99999,y:-99999)
        XCTAssertEqual(surface.videoX,960,accuracy:0.001);XCTAssertEqual(surface.videoY,-540,accuracy:0.001)
        XCTAssertEqual(surface.frame,original)
    }
    @MainActor func testResetRotationAndIndependentWindowsPreservePlayerLayout() {
        let a=NativePlayer(),b=NativePlayer()
        a.surface.frame=CGRect(x:0,y:0,width:500,height:280);b.surface.frame=CGRect(x:500,y:0,width:500,height:280)
        a.surface.zoom(scale:3,x:400,y:100)
        XCTAssertEqual(b.surface.videoScale,1);XCTAssertEqual(b.surface.videoX,0)
        a.surface.frame=CGRect(x:0,y:0,width:280,height:500);a.surface.setNeedsLayout();a.surface.layoutIfNeeded()
        XCTAssertEqual(a.surface.videoX,280,accuracy:0.001);XCTAssertEqual(a.surface.videoY,100,accuracy:0.001)
        let frame=a.surface.frame;a.close()
        XCTAssertEqual(a.surface.frame,frame);XCTAssertEqual(a.surface.videoScale,1);XCTAssertEqual(a.surface.videoX,0);XCTAssertEqual(a.surface.videoY,0)
        XCTAssertEqual(a.surface.videoLayer.affineTransform(),.identity);XCTAssertTrue(a.surface.clipsToBounds)
    }
}
