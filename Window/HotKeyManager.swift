import Carbon.HIToolbox
import Foundation

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

        var keyCode: UInt32 {
            switch self {
            case .maximize, .increaseHeight: UInt32(kVK_UpArrow)
            case .leftHalf, .decreaseWidth: UInt32(kVK_LeftArrow)
            case .rightHalf, .increaseWidth: UInt32(kVK_RightArrow)
            case .centered, .decreaseHeight: UInt32(kVK_DownArrow)
            }
        }

        var modifiers: UInt32 {
            switch self {
            case .increaseWidth, .increaseHeight, .decreaseWidth, .decreaseHeight: UInt32(cmdKey | optionKey)
            default: UInt32(cmdKey)
            }
        }

        func perform(using windows: WindowController) {
            switch self {
            case .maximize: windows.moveFocusedWindow(to: .maximize)
            case .leftHalf: windows.moveFocusedWindow(to: .leftHalf)
            case .rightHalf: windows.moveFocusedWindow(to: .rightHalf)
            case .centered: windows.moveFocusedWindow(to: .centered)
            case .increaseWidth: windows.resizeFocusedWindow(.width, by: 50)
            case .increaseHeight: windows.resizeFocusedWindow(.height, by: 50)
            case .decreaseWidth: windows.resizeFocusedWindow(.width, by: -50)
            case .decreaseHeight: windows.resizeFocusedWindow(.height, by: -50)
            }
        }
    }

    private static let signature: OSType = 0x57494E44 // WIND
    private let windows: WindowController
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    init(windows: WindowController) {
        self.windows = windows
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(), Self.handleEvent, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
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
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
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
        shortcut.perform(using: manager.windows)
        return noErr
    }
}
