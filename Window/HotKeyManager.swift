import AppKit
import Carbon.HIToolbox

final class HotKeyManager {
    private enum Action: UInt32, CaseIterable {
        case maximize = 1
        case leftHalf
        case rightHalf
        case centeredSize
        case hideOthers

        var keyCode: UInt32 {
            switch self {
            case .maximize: return UInt32(kVK_UpArrow)
            case .leftHalf: return UInt32(kVK_LeftArrow)
            case .rightHalf: return UInt32(kVK_RightArrow)
            case .centeredSize: return UInt32(kVK_DownArrow)
            case .hideOthers: return UInt32(kVK_DownArrow)
            }
        }

        var modifiers: UInt32 {
            switch self {
            case .hideOthers: return UInt32(cmdKey | optionKey)
            default: return UInt32(cmdKey)
            }
        }
    }

    private static let signature: OSType = 0x57494E44 // "WIND"
    private var hotKeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    init() {
        installEventHandler()
        registerHotKeys()
    }

    deinit {
        for hotKey in hotKeys {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == HotKeyManager.signature,
                      let action = Action(rawValue: hotKeyID.id) else {
                    return status
                }

                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.perform(action)
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func registerHotKeys() {
        for action in Action.allCases {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let status = RegisterEventHotKey(
                action.keyCode,
                action.modifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                hotKeys.append(reference)
            }
        }
    }

    private func perform(_ action: Action) {
        switch action {
        case .maximize:
            WindowController.moveFocusedWindow(to: .maximize)
        case .leftHalf:
            WindowController.moveFocusedWindow(to: .leftHalf)
        case .rightHalf:
            WindowController.moveFocusedWindow(to: .rightHalf)
        case .centeredSize:
            WindowController.moveFocusedWindow(to: .centered(width: 998, height: 836))
        case .hideOthers:
            WindowController.hideOtherApplications()
        }
    }
}
