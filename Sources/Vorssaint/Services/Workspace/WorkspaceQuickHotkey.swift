import Carbon.HIToolbox
import AppKit

final class WorkspaceQuickHotkey {
    static let shared = WorkspaceQuickHotkey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func start() {
        guard AppFeature.reminders.isAvailable, ref == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == 0x5655_5753 else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<WorkspaceQuickHotkey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { service.activate() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x5655_5753, id: 1)
        RegisterEventHotKey(17, UInt32(cmdKey | optionKey), id, GetEventDispatcherTarget(), 0, &newRef)
        ref = newRef
    }

    func stop() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }

    private func activate() {
        (NSApp.delegate as? AppDelegate)?.openWorkspaceTaskComposer()
    }
}
