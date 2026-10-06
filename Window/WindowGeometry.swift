import AppKit

// AppKit uses a bottom-left origin; Accessibility uses the primary screen's top-left.
struct ScreenArea: Equatable {
    let identifier: UInt32
    let frame: CGRect
    let workArea: CGRect

    static var current: [ScreenArea] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        return screens.map { screen in
            ScreenArea(
                identifier: (screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as! NSNumber).uint32Value,
                frame: accessibilityFrame(screen.frame, primaryTop: primary.frame.maxY),
                workArea: accessibilityFrame(screen.visibleFrame, primaryTop: primary.frame.maxY)
            )
        }
    }

    static func accessibilityFrame(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY,
               width: frame.width, height: frame.height)
    }

    static func containing(_ frame: CGRect, in screens: [ScreenArea]) -> ScreenArea? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let screen = screens.first(where: { $0.frame.contains(center) }) {
            return screen
        }
        // A straddling window can have its center in the gap between displays.
        guard let screen = screens.max(by: {
            $0.frame.intersection(frame).area < $1.frame.intersection(frame).area
        }) else { return nil }
        return screen.frame.intersects(frame) ? screen : screens.first
    }
}

enum WindowPlacement: UInt32, CaseIterable {
    case maximize = 1
    case leftHalf
    case rightHalf
    case centered

    func frame(in area: CGRect) -> CGRect {
        let leftWidth = floor(area.width / 2)
        switch self {
        case .maximize:
            return area
        case .leftHalf:
            return CGRect(x: area.minX, y: area.minY,
                          width: leftWidth, height: area.height)
        case .rightHalf:
            return CGRect(x: area.minX + leftWidth, y: area.minY,
                          width: area.width - leftWidth, height: area.height)
        case .centered:
            return CGRect(x: (area.midX - 499).rounded(), y: (area.midY - 418).rounded(),
                          width: 998, height: 836)
        }
    }
}

enum WindowMovement: CaseIterable {
    case left
    case right
    case up
    case down

    func frame(from frame: CGRect, in area: CGRect, by distance: CGFloat = 50) -> CGRect? {
        guard [frame.minX, frame.minY, frame.width, frame.height,
               area.minX, area.minY, area.width, area.height].allSatisfy({ $0.isFinite }),
              distance.isFinite, distance > 0,
              frame.width > 0, frame.height > 0, area.contains(frame) else { return nil }
        let target: CGRect
        switch self {
        case .left:
            target = frame.offsetBy(dx: -min(distance, frame.minX - area.minX), dy: 0)
        case .right:
            target = frame.offsetBy(dx: min(distance, area.maxX - frame.maxX), dy: 0)
        case .up:
            target = frame.offsetBy(dx: 0, dy: -min(distance, frame.minY - area.minY))
        case .down:
            target = frame.offsetBy(dx: 0, dy: min(distance, area.maxY - frame.maxY))
        }
        return target == frame ? nil : target
    }
}

enum WindowResize {
    case width
    case height

    func frame(from frame: CGRect, in area: CGRect, by amount: CGFloat) -> CGRect? {
        switch self {
        case .width:
            let available = 2 * min(frame.midX - area.minX, area.maxX - frame.midX)
            let width = amount > 0 ? min(frame.width + amount, available) : max(1, frame.width + amount)
            guard amount > 0 ? width > frame.width : width < frame.width else { return nil }
            return CGRect(x: frame.midX - width / 2, y: frame.minY,
                          width: width, height: frame.height)
        case .height:
            let available = 2 * min(frame.midY - area.minY, area.maxY - frame.midY)
            let height = amount > 0 ? min(frame.height + amount, available) : max(1, frame.height + amount)
            guard amount > 0 ? height > frame.height : height < frame.height else { return nil }
            return CGRect(x: frame.minX, y: frame.midY - height / 2,
                          width: frame.width, height: height)
        }
    }
}

extension CGRect {
    fileprivate var area: CGFloat { isNull ? 0 : width * height }

    func matches(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }

    func aligns(with area: CGRect) -> Bool {
        // AX omits part of the bottom shadow. One point short is visually flush.
        abs(minX - area.minX) <= 0.5
            && abs(minY - area.minY) <= 0.5
            && abs(width - area.width) <= 0.5
            && maxY - area.maxY <= 0.5
            && maxY - area.maxY >= -1
    }

    func resemblesMaximized(in screen: ScreenArea) -> Bool {
        let area = screen.workArea
        let full = screen.frame
        // Only the edge occupied by the Dock may drift while the Dock resizes.
        return abs(minY - area.minY) <= 4
            && abs(minX - area.minX) <= (area.minX - full.minX > 4 ? 120 : 4)
            && abs(maxX - area.maxX) <= (full.maxX - area.maxX > 4 ? 120 : 4)
            && abs(maxY - area.maxY) <= (full.maxY - area.maxY > 4 ? 120 : 4)
    }

    func interpolated(to target: CGRect, progress: Double) -> CGRect {
        CGRect(x: minX + (target.minX - minX) * progress,
               y: minY + (target.minY - minY) * progress,
               width: width + (target.width - width) * progress,
               height: height + (target.height - height) * progress)
    }

    func correctingResidual(actual: CGRect, target: CGRect) -> CGRect {
        CGRect(x: minX + target.minX - actual.minX,
               y: minY + target.minY - actual.minY,
               width: max(1, width + target.width - actual.width),
               height: max(1, height + target.height - actual.height))
    }
}
