import AppKit
import XCTest
@testable import ShotnixCore

@MainActor
final class AnnotationToolbarLayoutTests: XCTestCase {
    func testToolsRunVerticallyBesideTheCanvas() throws {
        let toolbar = AnnotationToolbar(frame: NSRect(x: 0, y: 0, width: 580, height: 520))
        let viewport = NSView()
        toolbar.installViewport(viewport)
        toolbar.layoutSubtreeIfNeeded()

        let groups = try AnnotationToolbar.toolGroups.map { group in
            try group.map { try XCTUnwrap(toolbar.toolButton(for: $0)).frame }
        }
        for group in groups {
            XCTAssertTrue(group.allSatisfy { toolbar.toolRail.bounds.contains($0) })
            for (above, below) in zip(group, group.dropFirst()) {
                XCTAssertEqual(above.midX, below.midX)
                XCTAssertEqual(above.minY - below.maxY, 2, accuracy: 0.01)
            }
        }
        for (above, below) in zip(groups, groups.dropFirst()) {
            XCTAssertEqual(try XCTUnwrap(above.last).minY - XCTUnwrap(below.first).maxY, 10, accuracy: 0.01)
        }
        XCTAssertLessThanOrEqual(toolbar.toolRail.frame.maxX, toolbar.convert(viewport.bounds, from: viewport).minX)
    }

    func testPressesScaleAboutTheCenterWhateverTheAnchor() {
        for anchor in [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 0)] {
            let layer = CALayer()
            layer.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
            layer.anchorPoint = anchor
            let transform = layer.scaledAboutCenter(0.92)
            // Points relative to the anchor, as Core Animation applies them.
            func mapped(_ point: CGPoint) -> CGPoint {
                let local = CGPoint(x: point.x - anchor.x * 34, y: point.y - anchor.y * 34)
                let m = transform
                let x = local.x * m.m11 + local.y * m.m21 + m.m41
                let y = local.x * m.m12 + local.y * m.m22 + m.m42
                return CGPoint(x: x + anchor.x * 34, y: y + anchor.y * 34)
            }
            let center = mapped(CGPoint(x: 17, y: 17))
            XCTAssertEqual(center.x, 17, accuracy: 0.0001, "anchor \(anchor): the center doesn't move")
            XCTAssertEqual(center.y, 17, accuracy: 0.0001)
            let corner = mapped(.zero)
            XCTAssertEqual(corner.x, 17 - 17 * 0.92, accuracy: 0.0001, "the corners move in evenly")
            XCTAssertEqual(corner.y, 17 - 17 * 0.92, accuracy: 0.0001)
        }
    }
}
