import AppKit
import Carbon.HIToolbox

/// Minimal global hotkey wrapper (Carbon `RegisterEventHotKey`).
///
/// Deliberately not using `NSEvent.addGlobalMonitorForEvents`: that requires
/// Accessibility permission, while `RegisterEventHotKey` does not.
///
/// The Carbon callback lands on the main run loop, so handlers always run on the
/// main thread — hence the `@MainActor` handler type.
final class HotKey {
    private let handler: @MainActor @Sendable () -> Void
    private let id: UInt32

    // Carbon refs are not Sendable, but they are only touched on the main
    // thread (construction, deallocation during teardown).
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var eventHandler: EventHandlerRef?

    /// Carbon's C callback cannot capture context, so handlers are looked up by
    /// hotkey id.
    private nonisolated(unsafe) static var handlers: [UInt32: @MainActor @Sendable () -> Void] = [:]
    private nonisolated(unsafe) static var nextID: UInt32 = 1

    init?(
        keyCode: UInt32,
        modifiers: NSEvent.ModifierFlags,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        self.handler = handler
        self.id = Self.nextID
        Self.nextID += 1

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return noErr }
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
                guard status == noErr else { return status }
                HotKey.invoke(hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x44524B52), id: id)  // 'DRKR'
        let registerStatus = RegisterEventHotKey(
            keyCode,
            Self.carbonModifiers(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            return nil
        }

        Self.handlers[id] = handler
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        Self.handlers[id] = nil
    }

    /// Dispatch a stored handler for `id` on the main actor.
    private nonisolated static func invoke(_ id: UInt32) {
        guard let handler = handlers[id] else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { handler() }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handler() }
            }
        }
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
