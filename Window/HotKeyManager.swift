import Carbon.HIToolbox
import AppKit

final class HotKeyManager {
    private enum Shortcut: UInt32, CaseIterable {
        case maximize = 1
        case leftHalf
        case rightHalf
        case centered
        case increaseWidth
        case increaseHeight
        case decreaseWidth
        case decreaseHeight
        case moveLeft
        case moveRight
        case moveUp
        case moveDown

        var keyCode: UInt32 {
            switch self {
            case .maximize, .increaseHeight, .moveUp: UInt32(kVK_UpArrow)
            case .leftHalf, .decreaseWidth, .moveLeft: UInt32(kVK_LeftArrow)
            case .rightHalf, .increaseWidth, .moveRight: UInt32(kVK_RightArrow)
            case .centered, .decreaseHeight, .moveDown: UInt32(kVK_DownArrow)
            }
        }

        var modifiers: UInt32 {
            switch self {
            case .increaseWidth, .increaseHeight, .decreaseWidth, .decreaseHeight: UInt32(cmdKey | optionKey)
            case .moveLeft, .moveRight, .moveUp, .moveDown: UInt32(controlKey | optionKey)
            default: UInt32(cmdKey)
            }
        }

        var resize: (axis: WindowResize, speed: CGFloat)? {
            switch self {
            case .increaseWidth: (.width, 500)
            case .increaseHeight: (.height, 500)
            case .decreaseWidth: (.width, -500)
            case .decreaseHeight: (.height, -500)
            default: nil
            }
        }

        var movement: WindowMovement? {
            switch self {
            case .moveLeft: .left
            case .moveRight: .right
            case .moveUp: .up
            case .moveDown: .down
            default: nil
            }
        }

        var isHeld: Bool {
            let modifiers = CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
            let required: CGEventFlags = self.modifiers == UInt32(controlKey | optionKey)
                ? [.maskControl, .maskAlternate] : [.maskCommand, .maskAlternate]
            return modifiers == required
                && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
        }

        func perform(using windows: WindowController) {
            switch self {
            case .maximize: windows.moveFocusedWindow(to: .maximize)
            case .leftHalf: windows.moveFocusedWindow(to: .leftHalf)
            case .rightHalf: windows.moveFocusedWindow(to: .rightHalf)
            case .centered: windows.moveFocusedWindow(to: .centered)
            case .increaseWidth, .increaseHeight, .decreaseWidth, .decreaseHeight,
                 .moveLeft, .moveRight, .moveUp, .moveDown: break // Handled by a continuous task.
            }
        }
    }

    private static let signature: OSType = 0x57494E44 // WIND
    private let windows: WindowController
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var heldShortcut: Shortcut?
    private var repeatTask: Task<Void, Never>?

    init(windows: WindowController) {
        self.windows = windows
        let eventTypes = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        let status = eventTypes.withUnsafeBufferPointer { types in
            InstallEventHandler(
                GetApplicationEventTarget(), Self.handleEvent, types.count, types.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(), &handler
            )
        }
        guard status == noErr else {
            NSLog("Window: could not install hotkey handler (%d)", status)
            return
        }
        for shortcut in Shortcut.allCases {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode, shortcut.modifiers,
                EventHotKeyID(signature: Self.signature, id: shortcut.rawValue),
                GetApplicationEventTarget(), 0, &reference
            )
            if status == noErr, let reference {
                hotKeys.append(reference)
            } else {
                NSLog("Window: could not register hotkey %u (%d)", shortcut.rawValue, status)
            }
        }
    }

    deinit {
        repeatTask?.cancel()
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func pressed(_ shortcut: Shortcut) {
        guard heldShortcut != shortcut else { return }
        stopRepeating()
        if shortcut.movement != nil || shortcut.resize != nil {
            heldShortcut = shortcut
            let whileHeld = { [weak self] in
                self?.heldShortcut == shortcut && shortcut.isHeld
            }
            let completion = { [weak self] in
                if self?.heldShortcut == shortcut { self?.stopRepeating() }
            }
            if let direction = shortcut.movement {
                repeatTask = windows.startMovingFocusedWindow(direction, whileHeld: whileHeld, completion: completion)
            } else if let resize = shortcut.resize {
                repeatTask = windows.startResizingFocusedWindow(resize.axis, speed: resize.speed,
                                                               whileHeld: whileHeld, completion: completion)
            }
            if repeatTask == nil { heldShortcut = nil }
            return
        }
        shortcut.perform(using: windows)
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
        heldShortcut = nil
    }

    private static let handleEvent: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
        )
        guard status == noErr else { return status }
        guard identifier.signature == signature,
              let shortcut = Shortcut(rawValue: identifier.id) else {
            return OSStatus(eventNotHandledErr)
        }
        let manager = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
        if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
            if manager.heldShortcut == shortcut { manager.stopRepeating() }
        } else {
            manager.pressed(shortcut)
        }
        return noErr
    }
}
