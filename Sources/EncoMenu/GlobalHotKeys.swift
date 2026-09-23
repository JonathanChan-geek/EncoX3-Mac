import Carbon

/// RegisterEventHotKey needs no Accessibility or Input Monitoring grant. Registration conflicts
/// are surfaced; we never claim a shortcut is enabled if any registration failed.
@MainActor
final class GlobalHotKeys {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var action: ((UInt32) -> Void)?
    func enable() -> Bool {
        disable()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, user in
            guard let event, let user else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == 0x454E434F else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKeys>.fromOpaque(user).takeUnretainedValue()
            let key = id.id
            Task { @MainActor in owner.action?(key) }
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else { return false }
        // Control + Option + Command + E/N/1/2/3; disabled by default until user opts in.
        let keys: [UInt32] = [UInt32(kVK_ANSI_E), UInt32(kVK_ANSI_N), UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3)]
        for (index, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x454E434F, id: UInt32(index))
            guard RegisterEventHotKey(key, UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref else { disable(); return false }
            refs.append(ref)
        }
        return true
    }
    func disable() {
        refs.forEach { UnregisterEventHotKey($0) }; refs = []
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
