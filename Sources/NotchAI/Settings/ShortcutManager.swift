import AppKit
import Carbon.HIToolbox

/// Registers one system-wide hot key through Carbon, which needs no Accessibility permission.
@MainActor
final class ShortcutManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    private static let signature: OSType = 0x4E_54_43_48 // 'NTCH'
    private let identifier: UInt32

    init(identifier: UInt32 = 1) { self.identifier = identifier }

    func register(_ shortcut: KeyboardShortcut, handler: @escaping () -> Void) throws {
        unregister()
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
                var pressed = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard status == noErr, pressed.signature == 0x4E_54_43_48,
                      pressed.id == manager.identifier else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async {
                    manager.fire()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            throw ShortcutError.registrationFailed("event handler \(installStatus)")
        }

        let hotKeyID = EventHotKeyID(signature: ShortcutManager.signature, id: identifier)
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            unregister()
            throw ShortcutError.registrationFailed("hot key \(registerStatus)")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        handler = nil
    }

    private func fire() {
        handler?()
    }
}

enum ShortcutError: LocalizedError {
    case registrationFailed(String)
    case invalidShortcut

    var errorDescription: String? {
        switch self {
        case let .registrationFailed(detail):
            return "This shortcut could not be registered (\(detail)). Another app may already use it."
        case .invalidShortcut:
            return "Record a shortcut with at least one modifier key."
        }
    }
}

extension Notification.Name {
    static let notchAIShortcutRecordingBegan = Notification.Name("NotchAI.shortcutRecordingBegan")
    static let notchAIShortcutRecordingEnded = Notification.Name("NotchAI.shortcutRecordingEnded")
}
