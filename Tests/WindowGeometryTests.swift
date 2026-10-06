import AppKit

@main
struct WindowGeometryTests {
    @MainActor static func main() {
        testCoordinateConversion()
        testScreenSelection()
        testPlacements()
        testCenteredResizing()
        testMovement()
        testMaximizedEdges()
        testAnimationGeometry()
        print("Window geometry: all checks passed")
    }

    static func testCoordinateConversion() {
        let primaryTop: CGFloat = 900
        let cases: [(CGRect, CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 0, width: 1440, height: 900)),
            (CGRect(x: -1920, y: 100, width: 1920, height: 1080), CGRect(x: -1920, y: -280, width: 1920, height: 1080)),
            (CGRect(x: 0, y: 900, width: 1920, height: 1080), CGRect(x: 0, y: -1080, width: 1920, height: 1080)),
            (CGRect(x: 200, y: -1080, width: 1920, height: 1080), CGRect(x: 200, y: 900, width: 1920, height: 1080)),
            (CGRect(x: 70, y: 60, width: 1370, height: 815), CGRect(x: 70, y: 25, width: 1370, height: 815))
        ]
        for (appKit, ax) in cases {
            precondition(ScreenArea.accessibilityFrame(appKit, primaryTop: primaryTop) == ax)
            precondition(ScreenArea.accessibilityFrame(ax, primaryTop: primaryTop) == appKit)
        }
    }

    static func testScreenSelection() {
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                      CGRect(x: -1920, y: -280, width: 1920, height: 1080),
                      CGRect(x: 0, y: -1200, width: 1440, height: 1080),
                      CGRect(x: 200, y: 900, width: 1920, height: 1080)]
        let screens = frames.enumerated().map {
            ScreenArea(identifier: UInt32($0.offset), frame: $0.element, workArea: $0.element.insetBy(dx: 20, dy: 30))
        }
        for screen in screens {
            precondition(ScreenArea.containing(screen.frame.insetBy(dx: 100, dy: 100), in: screens) == screen)
        }
        // Center falls in a gap; use the display containing most of the window.
        let gap = CGRect(x: 1100, y: -180, width: 400, height: 220)
        precondition(ScreenArea.containing(gap, in: screens) == screens[2])
        precondition(ScreenArea.containing(CGRect(x: 9000, y: 9000, width: 500, height: 500), in: screens) == screens[0])
        precondition(ScreenArea.containing(.zero, in: []) == nil)
    }

    static func testPlacements() {
        // Odd widths, fractional origins, negative coordinates and small displays.
        for width in [640.0, 998, 1281, 1440, 1921, 2560, 3440] {
            for height in [480.0, 836, 900, 1080, 1440] {
                for origin in [CGPoint.zero, CGPoint(x: -1920, y: -1080), CGPoint(x: 60.5, y: 25)] {
                    let area = CGRect(origin: origin, size: CGSize(width: width, height: height))
                    let left = WindowPlacement.leftHalf.frame(in: area)
                    let right = WindowPlacement.rightHalf.frame(in: area)
                    precondition(WindowPlacement.maximize.frame(in: area) == area)
                    precondition(left.union(right) == area)
                    precondition(left.maxX == right.minX)
                    precondition(left.width + right.width == area.width)
                    precondition(left.height == area.height && right.height == area.height)
                    let centered = WindowPlacement.centered.frame(in: area)
                    precondition(centered.size == CGSize(width: 998, height: 836))
                    precondition(abs(centered.midX - area.midX) <= 0.5 && abs(centered.midY - area.midY) <= 0.5)
                }
            }
        }
    }

    static func testCenteredResizing() {
        for origin in [CGPoint.zero, CGPoint(x: -1920, y: -1080), CGPoint(x: 60.5, y: 25)] {
            let area = CGRect(origin: origin, size: CGSize(width: 1440, height: 900))
            let start = CGRect(x: area.midX - 400, y: area.midY - 300, width: 800, height: 600)
            let wider = WindowResize.width.frame(from: start, in: area, by: 50)!
            let taller = WindowResize.height.frame(from: start, in: area, by: 50)!
            precondition(wider.width == 850 && wider.height == start.height)
            precondition(taller.height == 650 && taller.width == start.width)
            for target in [wider, taller] {
                precondition(target.midX == start.midX && target.midY == start.midY)
                precondition(area.contains(target))
            }
            let narrower = WindowResize.width.frame(from: start, in: area, by: -50)!
            let shorter = WindowResize.height.frame(from: start, in: area, by: -50)!
            precondition(narrower.width == 750 && narrower.height == start.height)
            precondition(shorter.height == 550 && shorter.width == start.width)
            for target in [narrower, shorter] {
                precondition(target.midX == start.midX && target.midY == start.midY)
            }
            precondition(WindowResize.width.frame(from: wider, in: area, by: -50) == start)
            precondition(WindowResize.height.frame(from: taller, in: area, by: -50) == start)
            let small = CGRect(x: area.midX - 10, y: area.midY - 10, width: 20, height: 20)
            let smallestWidth = WindowResize.width.frame(from: small, in: area, by: -50)!
            let smallestHeight = WindowResize.height.frame(from: small, in: area, by: -50)!
            precondition(smallestWidth.width == 1 && smallestWidth.midX == small.midX)
            precondition(smallestHeight.height == 1 && smallestHeight.midY == small.midY)
            precondition(WindowResize.width.frame(from: smallestWidth, in: area, by: -50) == nil)
            precondition(WindowResize.height.frame(from: smallestHeight, in: area, by: -50) == nil)
            precondition(WindowResize.width.frame(from: area, in: area, by: -50)!.width == area.width - 50)
            precondition(WindowResize.height.frame(from: area, in: area, by: -50)!.height == area.height - 50)
            // A rapid sequence accumulates requested increments rather than animation samples.
            var requested = start
            for _ in 0..<4 { requested = WindowResize.width.frame(from: requested, in: area, by: 50)! }
            precondition(requested.width == 1000 && requested.midX == start.midX)

            let nearLeft = CGRect(x: area.minX + 10, y: start.minY, width: 800, height: 600)
            let cappedWidth = WindowResize.width.frame(from: nearLeft, in: area, by: 50)!
            precondition(cappedWidth.width == 820 && cappedWidth.minX == area.minX)
            precondition(cappedWidth.midX == nearLeft.midX && cappedWidth.midY == nearLeft.midY)
            precondition(WindowResize.width.frame(from: cappedWidth, in: area, by: 50) == nil)
            let nearBottom = CGRect(x: start.minX, y: area.maxY - 610, width: 800, height: 600)
            let cappedHeight = WindowResize.height.frame(from: nearBottom, in: area, by: 50)!
            precondition(cappedHeight.height == 620 && cappedHeight.maxY == area.maxY)
            precondition(cappedHeight.midX == nearBottom.midX && cappedHeight.midY == nearBottom.midY)
            precondition(WindowResize.height.frame(from: cappedHeight, in: area, by: 50) == nil)

            precondition(WindowResize.width.frame(from: area, in: area, by: 50) == nil)
            precondition(WindowResize.height.frame(from: area, in: area, by: 50) == nil)
            precondition(WindowResize.width.frame(from: start.offsetBy(dx: -1000, dy: 0), in: area, by: 50) == nil)
            precondition(WindowResize.height.frame(from: start.offsetBy(dx: 0, dy: 1000), in: area, by: 50) == nil)
        }
    }

    static func testMovement() {
        for origin in [CGPoint.zero, CGPoint(x: -1920, y: -1080), CGPoint(x: 60.5, y: 25)] {
            let area = CGRect(origin: origin, size: CGSize(width: 1440, height: 900))
            let start = CGRect(x: area.minX + 100, y: area.minY + 100, width: 800, height: 600)
            precondition(WindowMovement.left.frame(from: start, in: area) == start.offsetBy(dx: -50, dy: 0))
            precondition(WindowMovement.right.frame(from: start, in: area) == start.offsetBy(dx: 50, dy: 0))
            precondition(WindowMovement.up.frame(from: start, in: area) == start.offsetBy(dx: 0, dy: -50))
            precondition(WindowMovement.down.frame(from: start, in: area) == start.offsetBy(dx: 0, dy: 50))
            // Different frame rates cover the same distance over the same elapsed time.
            for rate in [30, 60, 120] {
                var frame = start
                for _ in 0..<rate {
                    frame = WindowMovement.right.frame(from: frame, in: area, by: 500 / CGFloat(rate))!
                }
                precondition(abs(frame.minX - start.minX - 500) < 0.001)
                precondition(frame.size == start.size && frame.minY == start.minY)
            }
            precondition(WindowMovement.left.frame(from: start, in: area, by: 0) == nil)
            precondition(WindowMovement.left.frame(from: start, in: area, by: -.infinity) == nil)
            let nearEdges: [(WindowMovement, CGRect, CGRect)] = [
                (.left, CGRect(x: area.minX + 10, y: start.minY, width: 800, height: 600),
                 CGRect(x: area.minX, y: start.minY, width: 800, height: 600)),
                (.right, CGRect(x: area.maxX - 810, y: start.minY, width: 800, height: 600),
                 CGRect(x: area.maxX - 800, y: start.minY, width: 800, height: 600)),
                (.up, CGRect(x: start.minX, y: area.minY + 10, width: 800, height: 600),
                 CGRect(x: start.minX, y: area.minY, width: 800, height: 600)),
                (.down, CGRect(x: start.minX, y: area.maxY - 610, width: 800, height: 600),
                 CGRect(x: start.minX, y: area.maxY - 600, width: 800, height: 600))
            ]
            for (direction, frame, expected) in nearEdges {
                precondition(direction.frame(from: frame, in: area) == expected)
                precondition(direction.frame(from: expected, in: area) == nil)
            }
            for direction in WindowMovement.allCases {
                var frame = start
                var steps = 0
                while let target = direction.frame(from: frame, in: area) {
                    precondition(target.size == start.size && area.contains(target))
                    frame = target
                    steps += 1
                    precondition(steps < 30)
                }
                precondition(direction.frame(from: area, in: area) == nil)
                precondition(direction.frame(from: start.offsetBy(dx: -101, dy: 0), in: area) == nil)
                precondition(direction.frame(from: area.insetBy(dx: -1, dy: -1), in: area) == nil)
                precondition(direction.frame(from: CGRect(origin: origin, size: .zero), in: area) == nil)
                precondition(direction.frame(from: .infinite, in: area) == nil)
            }
        }
    }

    static func testMaximizedEdges() {
        let full = CGRect(x: -1440, y: -900, width: 1440, height: 900)
        let areas = [CGRect(x: -1440, y: -875, width: 1440, height: 815),
                     CGRect(x: -1370, y: -875, width: 1370, height: 875),
                     CGRect(x: -1440, y: -875, width: 1370, height: 875)]
        for (index, area) in areas.enumerated() {
            let screen = ScreenArea(identifier: UInt32(index), frame: full, workArea: area)
            precondition(area.aligns(with: area) && area.resemblesMaximized(in: screen))
            var shortened = area
            shortened.size.height -= 1
            precondition(shortened.aligns(with: area))
            shortened.size.height -= 0.1
            precondition(!shortened.aligns(with: area))
            var overhanging = area
            overhanging.size.height += 1
            precondition(!overhanging.aligns(with: area))
            var dockDrift = area
            switch index {
            case 0: dockDrift.size.height -= 80
            case 1: dockDrift.origin.x += 80; dockDrift.size.width -= 80
            default: dockDrift.size.width -= 80
            }
            precondition(dockDrift.resemblesMaximized(in: screen))
            precondition(!dockDrift.offsetBy(dx: 0, dy: 10).resemblesMaximized(in: screen))
        }
    }

    static func testAnimationGeometry() {
        let start = CGRect(x: -1920, y: 20, width: 998, height: 836)
        let target = CGRect(x: 0, y: -1080, width: 1920, height: 1055)
        precondition(start.interpolated(to: target, progress: 0) == start)
        precondition(start.interpolated(to: target, progress: 1) == target)
        for step in 0...60 {
            let frame = start.interpolated(to: target, progress: Double(step) / 60)
            precondition(frame.minX >= start.minX && frame.minX <= target.minX)
            precondition(frame.minY <= start.minY && frame.minY >= target.minY)
            precondition(frame.width >= start.width && frame.width <= target.width)
        }
        let actual = CGRect(x: target.minX + 1, y: target.minY - 1,
                            width: target.width - 1, height: target.height - 1)
        let corrected = target.correctingResidual(actual: actual, target: target)
        precondition(corrected.origin == CGPoint(x: target.minX - 1, y: target.minY + 1))
        precondition(corrected.size == CGSize(width: target.width + 1, height: target.height + 1))
    }
}
