import ApplicationServices

nonisolated struct AccessibleWindow: Hashable {
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }

    static func focused(in application: AXUIElement) -> AccessibleWindow? {
        guard let value = application.attribute(kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AccessibleWindow(element: value as! AXUIElement)
    }

    static func all(in application: AXUIElement) -> [AccessibleWindow] {
        (application.attribute(kAXWindowsAttribute) as? [AXUIElement] ?? [])
            .map { AccessibleWindow(element: $0) }
    }

    var isStandardUnminimized: Bool {
        element.attribute(kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
            && element.attribute(kAXMinimizedAttribute) as? Bool != true
    }

    var canResize: Bool {
        guard element.attribute("AXFullScreen") as? Bool != true,
              element.attribute(kAXMinimizedAttribute) as? Bool != true else { return false }
        return isSettable(kAXSizeAttribute) && isSettable(kAXPositionAttribute)
    }

    var canMove: Bool {
        isStandardUnminimized
            && element.attribute("AXFullScreen") as? Bool != true
            && isSettable(kAXPositionAttribute)
    }

    private func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    var frame: CGRect? {
        guard let positionValue = axValue(kAXPositionAttribute, type: .cgPoint),
              let sizeValue = axValue(kAXSizeAttribute, type: .cgSize) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    var size: CGSize? {
        guard let value = axValue(kAXSizeAttribute, type: .cgSize) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    // One AX round trip validates geometry and state during a continuous move.
    var movableFrame: CGRect? {
        let attributes = [kAXPositionAttribute, kAXSizeAttribute, kAXSubroleAttribute,
                          kAXMinimizedAttribute, "AXFullScreen"] as CFArray
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &result) == .success,
              let values = result as? [CFTypeRef], values.count == 5,
              values[2] as? String == kAXStandardWindowSubrole,
              values[3] as? Bool == false, values[4] as? Bool != true,
              CFGetTypeID(values[0]) == AXValueGetTypeID(),
              CFGetTypeID(values[1]) == AXValueGetTypeID() else { return nil }
        let positionValue = values[0] as! AXValue
        let sizeValue = values[1] as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func axValue(_ attribute: String, type: AXValueType) -> AXValue? {
        guard let value = element.attribute(attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        return AXValueGetType(axValue) == type ? axValue : nil
    }

    func setFrame(_ frame: CGRect) {
        // Resize first so apps do not clamp the old, oversized frame onscreen.
        setSize(frame.size)
        setPosition(frame.origin)
    }

    @discardableResult
    func setPosition(_ position: CGPoint) -> AXError {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    @discardableResult
    func setSize(_ size: CGSize) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }
}

extension AXUIElement {
    nonisolated func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success
            ? value : nil
    }
}
