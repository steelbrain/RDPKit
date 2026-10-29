import AppKit
import Carbon.HIToolbox
import RDPKit

/// Where the capture view sends input: the session's `RDPInputSession`.
protocol RDPInputEventSending: AnyObject {
    func send(_ events: [RDPSlowPathInputEvent])
}

extension RDPInputSession: RDPInputEventSending {}

final class RemoteInputCaptureNSView: NSView {
    var rdpFrame: RDPFrameMetadata?
    /// The layout the session announced; it decides which keys can go as scancodes.
    var keyboardLayout = RDPKeyboardLayout.unitedStates
    var inputSession: (any RDPInputEventSending)? {
        willSet {
            if inputSession != nil, inputSession !== newValue {
                releasePressedInputs()
            }
        }
        didSet {
            if inputSession != nil, inputSession !== oldValue, window?.firstResponder === self {
                synchronizeToggleKeys(NSEvent.modifierFlags)
            }
        }
    }

    private var trackingArea: NSTrackingArea?
    private var inputState = RDPInputStateTracker()
    private var deferredModifierKeys = MacRDPDeferredModifierKeys()
    private var wheelAccumulator = RDPScrollWheelAccumulator()
    private var commandKeyUpMonitor: Any?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        releasePressedInputs()
        stopObservingWindow()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObservingWindow()
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            synchronizeToggleKeys(NSEvent.modifierFlags)
        }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        releasePressedInputs()
        return super.resignFirstResponder()
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointerMove(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointerMove(event, isDragging: true)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPointerMove(event, isDragging: true)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendPointerMove(event, isDragging: true)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointerButton(.left, isDown: true, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        sendPointerButton(.left, isDown: false, event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointerButton(.right, isDown: true, event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendPointerButton(.right, isDown: false, event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let button = pointerButton(for: event) else {
            return
        }
        sendPointerButton(button, isDown: true, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let button = pointerButton(for: event) else {
            return
        }
        sendPointerButton(button, isDown: false, event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        releaseModifiers(missingFrom: event.modifierFlags)
        guard let point = remotePoint(from: event) else {
            return
        }
        inputState.updatePointerLocation(point)
        let units = MacRDPScrollWheel.rotationUnits(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
        )
        let events = wheelAccumulator.events(vertical: units.vertical, horizontal: units.horizontal, at: point)
        guard events.isEmpty == false else {
            return
        }
        inputSession?.send(deferredModifierKeys.flush(&inputState) + events)
    }

    override func keyDown(with event: NSEvent) {
        releaseModifiers(missingFrom: event.modifierFlags)
        if let scancode = MacRDPKeyboardMapping.scancode(forKeyCode: event.keyCode),
           MacRDPKeyboardMapping.shouldSendScancode(
               forKeyCode: event.keyCode,
               characters: event.characters,
               charactersIgnoringModifiers: event.charactersIgnoringModifiers,
               modifierFlags: event.modifierFlags,
               isHeldAsScancode: inputState.isScancodePressed(scancode),
               isAltPressed: MacRDPModifierKey.altScancodes.contains(where: inputState.isScancodePressed)
           ) || MacRDPKeyboardMapping.windowsTypes(
               event.characters,
               charactersIgnoringModifiers: event.charactersIgnoringModifiers,
               for: scancode,
               modifierFlags: event.modifierFlags,
               layout: keyboardLayout
           )
        {
            sendKeyboardScancode(scancode, isReleased: false)
            return
        }
        guard event.modifierFlags.isDisjoint(with: [.command, .control]) else {
            return
        }
        // Right Option, if held back, typed this or started a dead key, so it is no Alt tap.
        deferredModifierKeys.noteChordedElsewhere()
        let events = MacRDPKeyboardMapping.unicodeEvents(for: event.characters ?? "")
        guard events.isEmpty == false else {
            return
        }
        inputSession?.send(events)
    }

    override func keyUp(with event: NSEvent) {
        releaseModifiers(missingFrom: event.modifierFlags)
        guard let scancode = MacRDPKeyboardMapping.scancode(forKeyCode: event.keyCode),
              inputState.isScancodePressed(scancode)
        else {
            return
        }
        sendKeyboardScancode(scancode, isReleased: true)
    }

    override func flagsChanged(with event: NSEvent) {
        if Int(event.keyCode) == kVK_CapsLock {
            synchronizeToggleKeys(event.modifierFlags)
        } else if let modifier = MacRDPModifierKey(keyCode: event.keyCode) {
            sendChanges(of: modifier, in: event.modifierFlags)
        }
        // After the change itself, so that Command released alone still sends its deferred tap.
        releaseModifiers(missingFrom: event.modifierFlags)
    }

    private func sendChanges(of modifier: MacRDPModifierKey, in modifierFlags: NSEvent.ModifierFlags) {
        let changes = modifier.changes(in: modifierFlags) {
            inputState.isScancodePressed($0) || deferredModifierKeys.isHeld($0)
        }
        for change in changes {
            if MacRDPDeferredModifierKeys.isDeferred(change.scancode),
               inputState.isScancodePressed(change.scancode) == false
            {
                if change.isDown {
                    deferredModifierKeys.press(change.scancode)
                } else {
                    inputSession?.send(deferredModifierKeys.release(change.scancode))
                }
            } else if change.isDown {
                inputSession?.send(
                    deferredModifierKeys.flushWindowsKeys(&inputState)
                        + [inputState.keyboard(scancode: change.scancode, isReleased: false)]
                )
            } else {
                sendKeyboardScancode(change.scancode, isReleased: true)
            }
        }
    }

    private func startObservingWindow() {
        guard let window else {
            return
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        // AppKit never dispatches keyUp to the window while Command is held, which would leave
        // keys pressed during a Command chord stuck down on the server.
        commandKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            MainActor.assumeIsolated {
                self?.forwardCommandKeyUp(event)
            }
            return event
        }
    }

    private func stopObservingWindow() {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
        }
        if let commandKeyUpMonitor {
            NSEvent.removeMonitor(commandKeyUpMonitor)
            self.commandKeyUpMonitor = nil
        }
    }

    @objc private func windowDidResignKey(_: Notification) {
        releasePressedInputs()
    }

    @objc private func windowDidBecomeKey(_: Notification) {
        if window?.firstResponder === self {
            synchronizeToggleKeys(NSEvent.modifierFlags)
        }
    }

    /// MS-RDPBCGR 2.2.8.1.1.3.1.1.5: on focus gain, send the toggle-key state followed by the
    /// keys still held, since the server's state may have changed while focus was elsewhere.
    private func synchronizeToggleKeys(_ modifierFlags: NSEvent.ModifierFlags) {
        inputSession?.send(inputState.synchronizationEvents(
            toggleFlags: MacRDPKeyboardMapping.toggleFlags(for: modifierFlags)
        ))
    }

    private func forwardCommandKeyUp(_ event: NSEvent) {
        guard event.modifierFlags.contains(.command),
              event.window === window,
              window?.firstResponder === self
        else {
            return
        }
        deferredModifierKeys.noteChordedElsewhere()
        keyUp(with: event)
    }

    /// AppKit does not deliver every modifier release to the view, for example one made while a menu
    /// is open, so a modifier the server still holds is released by the next event that shows it up.
    private func releaseModifiers(missingFrom modifierFlags: NSEvent.ModifierFlags) {
        var events: [RDPSlowPathInputEvent] = []
        for modifier in MacRDPModifierKey.all where modifier.isDown(in: modifierFlags) == false {
            if inputState.isScancodePressed(modifier.scancode) {
                events.append(inputState.keyboard(scancode: modifier.scancode, isReleased: true))
            }
            // A held-back key whose release went elsewhere never reached the server.
            deferredModifierKeys.discard(modifier.scancode)
        }
        if events.isEmpty == false {
            inputSession?.send(events)
        }
    }

    private func sendPointerMove(_ event: NSEvent, isDragging: Bool = false) {
        releaseModifiers(missingFrom: event.modifierFlags)
        guard let point = remotePoint(from: event, clampingToDesktop: isDragging) else {
            return
        }
        inputSession?.send([inputState.pointerMove(to: point)])
    }

    private func sendPointerButton(_ button: RDPPointerButton, isDown: Bool, event: NSEvent) {
        releaseModifiers(missingFrom: event.modifierFlags)
        guard let inputEvent = inputState.pointerButton(button, isDown: isDown, at: remotePoint(from: event)) else {
            return
        }
        let heldKeyEvents = isDown ? deferredModifierKeys.flush(&inputState) : []
        inputSession?.send(heldKeyEvents + [inputEvent])
    }

    private func pointerButton(for event: NSEvent) -> RDPPointerButton? {
        switch event.buttonNumber {
        case 2:
            .middle
        case 3:
            .extended1
        case 4:
            .extended2
        default:
            nil
        }
    }

    private func sendKeyboardScancode(_ scancode: RDPKeyboardScancode, isReleased: Bool) {
        let heldKeyEvents = isReleased ? [] : deferredModifierKeys.flush(&inputState)
        inputSession?.send(heldKeyEvents + [inputState.keyboard(scancode: scancode, isReleased: isReleased)])
    }

    /// A key still held back never reached the server, so nothing is sent for it.
    private func releasePressedInputs() {
        deferredModifierKeys.reset()
        inputSession?.send(inputState.releasePressedInputs())
    }

    /// `clampingToDesktop` moves a point outside the desktop, such as a drag's past the
    /// letterbox, onto the desktop's nearest edge.
    private func remotePoint(from event: NSEvent, clampingToDesktop: Bool = false) -> RDPRemotePoint? {
        guard let rdpFrame else {
            return nil
        }
        let viewport = RDPRemoteDisplayViewport(frame: rdpFrame, bounds: bounds, coordinateOrigin: .bottomLeft)
        // Where the canvas draws the desktop.
        let desktop = backingAlignedDesktopRect(of: viewport)
        var localPoint = convert(event.locationInWindow, from: nil)
        if clampingToDesktop {
            localPoint.x = min(max(localPoint.x, desktop.minX), desktop.maxX.nextDown)
            localPoint.y = min(max(localPoint.y, desktop.minY), desktop.maxY.nextDown)
        }
        return viewport.remotePoint(from: localPoint, contentRect: desktop)
    }
}

/// Converts AppKit scroll deltas into RDP wheel rotation units: a line (one wheel notch) is
/// 120 units and a precise (trackpad) point 10.
enum MacRDPScrollWheel {
    private static let unitsPerPoint = 10.0

    /// AppKit reports positive `deltaX` for scrolling left, while RDP horizontal rotation is
    /// positive to the right, so the horizontal axis is negated.
    static func rotationUnits(
        deltaX: CGFloat,
        deltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool
    ) -> (vertical: Double, horizontal: Double) {
        let scale = hasPreciseScrollingDeltas ? unitsPerPoint : RDPScrollWheelAccumulator.unitsPerNotch
        return (Double(deltaY) * scale, -Double(deltaX) * scale)
    }
}

/// Command is sent as the Windows key, and a Windows key pressed and released with nothing in
/// between opens the server's Start menu (GNOME Activities, the KDE launcher). Command chords the
/// server never sees, such as Cmd-Tab and menu shortcuts, must not reach it as such a tap, so Win
/// down is sent only before another key, button or wheel event goes to the server while Command
/// is held, or as a tap when Command is released alone.
///
/// Right Option is held back the same way as Alt, so that it can type what the Mac layout puts
/// on Option ("@" is Option-L on German) as Unicode, without Alt; releasing it after that sends
/// nothing. Another modifier pressed meanwhile sends the Windows keys but not Alt, since
/// Option-Shift types characters too. Left Option goes as Alt at once, for shortcuts.
struct MacRDPDeferredModifierKeys {
    private var heldScancodes: [RDPKeyboardScancode] = []
    private var isChordedElsewhere = false

    static func isDeferred(_ scancode: RDPKeyboardScancode) -> Bool {
        isWindowsKey(scancode) || scancode == RDPKeyboardScancode(code: 0x38, isExtended: true)
    }

    private static func isWindowsKey(_ scancode: RDPKeyboardScancode) -> Bool {
        scancode.isExtended && (scancode.code == 0x5B || scancode.code == 0x5C)
    }

    func isHeld(_ scancode: RDPKeyboardScancode) -> Bool {
        heldScancodes.contains(scancode)
    }

    /// Keys held back together are a chord, so releasing them sends nothing.
    mutating func press(_ scancode: RDPKeyboardScancode) {
        if heldScancodes.contains(scancode) == false {
            noteChordedElsewhere()
            heldScancodes.append(scancode)
        }
    }

    /// Sends the held keys down, ahead of another key, button or wheel event.
    mutating func flush(_ inputState: inout RDPInputStateTracker) -> [RDPSlowPathInputEvent] {
        defer {
            reset()
        }
        return heldScancodes.map { inputState.keyboard(scancode: $0, isReleased: false) }
    }

    /// Sends the held Windows keys down, ahead of another modifier. Alt stays held back, but
    /// releasing it is no longer a tap.
    mutating func flushWindowsKeys(_ inputState: inout RDPInputStateTracker) -> [RDPSlowPathInputEvent] {
        let windowsKeys = heldScancodes.filter(Self.isWindowsKey)
        heldScancodes.removeAll(where: Self.isWindowsKey)
        noteChordedElsewhere()
        return windowsKeys.map { inputState.keyboard(scancode: $0, isReleased: false) }
    }

    /// Another key was used with the held keys but never reached the server as a scancode: it
    /// was seen only as its key-up, for example a menu shortcut, or it went as the character
    /// Option typed. Releasing them then sends nothing.
    mutating func noteChordedElsewhere() {
        isChordedElsewhere = heldScancodes.isEmpty == false
    }

    mutating func release(_ scancode: RDPKeyboardScancode) -> [RDPSlowPathInputEvent] {
        guard let index = heldScancodes.firstIndex(of: scancode) else {
            return []
        }
        heldScancodes.remove(at: index)
        let isTap = isChordedElsewhere == false
        if heldScancodes.isEmpty {
            isChordedElsewhere = false
        }
        return isTap ? [.keyboard(scancode: scancode, isReleased: false), .keyboard(scancode: scancode, isReleased: true)] : []
    }

    mutating func discard(_ scancode: RDPKeyboardScancode) {
        heldScancodes.removeAll { $0 == scancode }
        if heldScancodes.isEmpty {
            isChordedElsewhere = false
        }
    }

    mutating func reset() {
        heldScancodes.removeAll()
        isChordedElsewhere = false
    }
}

struct MacRDPModifierKey {
    // Device-dependent modifier bits from IOKit's IOLLEvent.h (NX_DEVICE*KEYMASK).
    private static let leftControl: UInt = 0x0000_0001
    private static let leftShift: UInt = 0x0000_0002
    private static let rightShift: UInt = 0x0000_0004
    private static let leftCommand: UInt = 0x0000_0008
    private static let rightCommand: UInt = 0x0000_0010
    private static let leftOption: UInt = 0x0000_0020
    private static let rightOption: UInt = 0x0000_0040
    private static let rightControl: UInt = 0x0000_2000

    private static let leftShiftScancode = RDPKeyboardScancode(code: 0x2A)
    private static let rightShiftScancode = RDPKeyboardScancode(code: 0x36)
    private static let leftControlScancode = RDPKeyboardScancode(code: 0x1D)
    private static let rightControlScancode = RDPKeyboardScancode(code: 0x1D, isExtended: true)
    private static let leftOptionScancode = RDPKeyboardScancode(code: 0x38)
    private static let rightOptionScancode = RDPKeyboardScancode(code: 0x38, isExtended: true)
    private static let leftCommandScancode = RDPKeyboardScancode(code: 0x5B, isExtended: true)
    private static let rightCommandScancode = RDPKeyboardScancode(code: 0x5C, isExtended: true)

    static let all = [
        kVK_Shift, kVK_RightShift, kVK_Control, kVK_RightControl,
        kVK_Option, kVK_RightOption, kVK_Command, kVK_RightCommand,
    ].compactMap { MacRDPModifierKey(keyCode: UInt16($0)) }

    static let altScancodes = [leftOptionScancode, rightOptionScancode]

    let scancode: RDPKeyboardScancode
    /// The other side's key, which shares `flag`.
    private let pairScancode: RDPKeyboardScancode
    private let flag: NSEvent.ModifierFlags
    private let deviceMask: UInt
    private let pairDeviceMask: UInt

    init?(keyCode: UInt16) {
        switch Int(keyCode) {
        case kVK_Shift:
            self.init(Self.leftShiftScancode, Self.rightShiftScancode, .shift, Self.leftShift, Self.rightShift)
        case kVK_RightShift:
            self.init(Self.rightShiftScancode, Self.leftShiftScancode, .shift, Self.rightShift, Self.leftShift)
        case kVK_Control:
            self.init(Self.leftControlScancode, Self.rightControlScancode, .control, Self.leftControl, Self.rightControl)
        case kVK_RightControl:
            self.init(Self.rightControlScancode, Self.leftControlScancode, .control, Self.rightControl, Self.leftControl)
        case kVK_Option:
            self.init(Self.leftOptionScancode, Self.rightOptionScancode, .option, Self.leftOption, Self.rightOption)
        case kVK_RightOption:
            self.init(Self.rightOptionScancode, Self.leftOptionScancode, .option, Self.rightOption, Self.leftOption)
        case kVK_Command:
            self.init(Self.leftCommandScancode, Self.rightCommandScancode, .command, Self.leftCommand, Self.rightCommand)
        case kVK_RightCommand:
            self.init(Self.rightCommandScancode, Self.leftCommandScancode, .command, Self.rightCommand, Self.leftCommand)
        default:
            return nil
        }
    }

    private init(
        _ scancode: RDPKeyboardScancode,
        _ pairScancode: RDPKeyboardScancode,
        _ flag: NSEvent.ModifierFlags,
        _ deviceMask: UInt,
        _ pairSideMask: UInt
    ) {
        self.scancode = scancode
        self.pairScancode = pairScancode
        self.flag = flag
        self.deviceMask = deviceMask
        pairDeviceMask = deviceMask | pairSideMask
    }

    /// The key changes that bring the server in line with `modifierFlags`. Keyboards without side
    /// bits clear `flag` only once both sides are up, so both sides are released then.
    func changes(
        in modifierFlags: NSEvent.ModifierFlags,
        isPressed: (RDPKeyboardScancode) -> Bool
    ) -> [(scancode: RDPKeyboardScancode, isDown: Bool)] {
        guard modifierFlags.contains(flag) else {
            return [scancode, pairScancode].filter(isPressed).map { ($0, false) }
        }
        let isDown = isDown(in: modifierFlags)
        return isDown == isPressed(scancode) ? [] : [(scancode, isDown)]
    }

    /// Reads this key's own side bit so left and right modifiers track independently, falling
    /// back to the side-independent flag for keyboards that report no side bits.
    func isDown(in modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let rawValue = modifierFlags.rawValue
        if rawValue & pairDeviceMask != 0 {
            return rawValue & deviceMask != 0
        }
        return modifierFlags.contains(flag)
    }
}

enum MacRDPKeyboardMapping {
    /// Mac keypads always type digits, so the server's Num Lock is kept on for the keypad scancodes.
    static func toggleFlags(for modifierFlags: NSEvent.ModifierFlags) -> RDPToggleKeyFlags {
        modifierFlags.contains(.capsLock) ? [.numLock, .capsLock] : [.numLock]
    }

    /// `isISOKeyboard` defaults to the type of the keyboard in use.
    static func scancode(
        forKeyCode keyCode: UInt16,
        isISOKeyboard: Bool = KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
    ) -> RDPKeyboardScancode? {
        // On ISO keyboards macOS reports the key between left Shift and Z as kVK_ANSI_Grave; it
        // sits where PC ISO keyboards have their extra key (0x56).
        if isISOKeyboard, Int(keyCode) == kVK_ANSI_Grave {
            return RDPKeyboardScancode(code: 0x56)
        }
        return scancodes[Int(keyCode)]
    }

    /// A key the server holds keeps auto-repeating as its scancode after the modifier that sent it
    /// there is released; repeating it as text would type on top of the held key. With Option down
    /// but no Alt on the server, which is right Option held back (see MacRDPDeferredModifierKeys),
    /// a key Option types a character with goes as that character instead.
    static func shouldSendScancode(
        forKeyCode keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags,
        isHeldAsScancode: Bool,
        isAltPressed: Bool
    ) -> Bool {
        if isHeldAsScancode
            || scancodeOnlyKeyCodes.contains(Int(keyCode))
            || modifierFlags.isDisjoint(with: [.command, .control]) == false
        {
            return true
        }
        return modifierFlags.contains(.option)
            && (isAltPressed || optionTypes(characters, charactersIgnoringModifiers: charactersIgnoringModifiers) == false)
    }

    /// Whether Option typed what the Mac layout puts on the key: printable characters other than
    /// the key's own, or nothing, for a dead key such as Option-E on US, whose accent the next key
    /// types.
    static func optionTypes(_ characters: String?, charactersIgnoringModifiers: String?) -> Bool {
        guard let characters, characters != charactersIgnoringModifiers else {
            return false
        }
        return characters.utf16.contains(where: functionKeyCharacters.contains) == false
            && characters.unicodeScalars.contains { $0.properties.generalCategory == .control } == false
    }

    /// Whether Windows, with `layout`, types what the Mac typed for a character key: then the key
    /// goes as its scancode, which a remote IME sees, rather than as Unicode, which reaches
    /// applications as VK_PACKET. The table is keyed by the scancode sent, so a key the
    /// layouts place differently, such as the ISO key sent as 0x56, still goes as Unicode, as
    /// does a character a dead key composed (`characters` differs from
    /// `charactersIgnoringModifiers`). Space types a space on every layout, and a remote IME
    /// commits its candidate with it, so it goes as its scancode unless a dead key composed
    /// with it, as "^" then Space types "^".
    static func windowsTypes(
        _ characters: String?,
        charactersIgnoringModifiers: String?,
        for scancode: RDPKeyboardScancode,
        modifierFlags: NSEvent.ModifierFlags,
        layout: RDPKeyboardLayout
    ) -> Bool {
        guard let characters, characters == charactersIgnoringModifiers else {
            return false
        }
        if scancode == spaceScancode {
            return true
        }
        guard let typed = MacRDPWindowsKeyboardLayout.layout(layout)?.character(
                  for: scancode,
                  isShifted: modifierFlags.contains(.shift),
                  isCapsLocked: modifierFlags.contains(.capsLock)
              )
        else {
            return false
        }
        return characters.unicodeScalars.elementsEqual(CollectionOfOne(typed))
    }

    private static let spaceScancode = RDPKeyboardScancode(code: 0x39)

    static func unicodeEvents(for characters: String) -> [RDPSlowPathInputEvent] {
        characters.utf16
            .filter { functionKeyCharacters.contains($0) == false }
            .flatMap { codeUnit in
                [
                    RDPSlowPathInputEvent.unicode(codeUnit: codeUnit, isReleased: false),
                    RDPSlowPathInputEvent.unicode(codeUnit: codeUnit, isReleased: true),
                ]
            }
    }

    /// AppKit reports unmapped function keys as private-use characters (NSF1FunctionKey...).
    private static let functionKeyCharacters: ClosedRange<UInt16> = 0xF700 ... 0xF8FF

    private static let characterScancodes: [Int: UInt16] = [
        kVK_ANSI_A: 0x1E, kVK_ANSI_B: 0x30, kVK_ANSI_C: 0x2E, kVK_ANSI_D: 0x20,
        kVK_ANSI_E: 0x12, kVK_ANSI_F: 0x21, kVK_ANSI_G: 0x22, kVK_ANSI_H: 0x23,
        kVK_ANSI_I: 0x17, kVK_ANSI_J: 0x24, kVK_ANSI_K: 0x25, kVK_ANSI_L: 0x26,
        kVK_ANSI_M: 0x32, kVK_ANSI_N: 0x31, kVK_ANSI_O: 0x18, kVK_ANSI_P: 0x19,
        kVK_ANSI_Q: 0x10, kVK_ANSI_R: 0x13, kVK_ANSI_S: 0x1F, kVK_ANSI_T: 0x14,
        kVK_ANSI_U: 0x16, kVK_ANSI_V: 0x2F, kVK_ANSI_W: 0x11, kVK_ANSI_X: 0x2D,
        kVK_ANSI_Y: 0x15, kVK_ANSI_Z: 0x2C,
        kVK_ANSI_1: 0x02, kVK_ANSI_2: 0x03, kVK_ANSI_3: 0x04, kVK_ANSI_4: 0x05, kVK_ANSI_5: 0x06,
        kVK_ANSI_6: 0x07, kVK_ANSI_7: 0x08, kVK_ANSI_8: 0x09, kVK_ANSI_9: 0x0A, kVK_ANSI_0: 0x0B,
        kVK_ANSI_Minus: 0x0C, kVK_ANSI_Equal: 0x0D, kVK_ANSI_LeftBracket: 0x1A, kVK_ANSI_RightBracket: 0x1B,
        kVK_ANSI_Semicolon: 0x27, kVK_ANSI_Quote: 0x28, kVK_ANSI_Grave: 0x29, kVK_ANSI_Backslash: 0x2B,
        kVK_ANSI_Comma: 0x33, kVK_ANSI_Period: 0x34, kVK_ANSI_Slash: 0x35, kVK_Space: 0x39,
        // macOS reports the ISO key left of "1" as kVK_ISO_Section; it occupies the grave key's position.
        kVK_ISO_Section: 0x29,
        kVK_JIS_Yen: 0x7D, kVK_JIS_Underscore: 0x73,
        // PC keypads have no "="; the main "=" key's scancode types it only on some layouts
        // (German has a dead key there), so the layout check decides.
        kVK_ANSI_KeypadEquals: 0x0D,
    ]

    /// Keys that always go as their scancodes.
    private static let scancodeOnlyKeys: [Int: RDPKeyboardScancode] = [
        kVK_Escape: RDPKeyboardScancode(code: 0x01),
        kVK_Delete: RDPKeyboardScancode(code: 0x0E),
        kVK_Tab: RDPKeyboardScancode(code: 0x0F),
        kVK_Return: RDPKeyboardScancode(code: 0x1C),
        kVK_F1: RDPKeyboardScancode(code: 0x3B), kVK_F2: RDPKeyboardScancode(code: 0x3C),
        kVK_F3: RDPKeyboardScancode(code: 0x3D), kVK_F4: RDPKeyboardScancode(code: 0x3E),
        kVK_F5: RDPKeyboardScancode(code: 0x3F), kVK_F6: RDPKeyboardScancode(code: 0x40),
        kVK_F7: RDPKeyboardScancode(code: 0x41), kVK_F8: RDPKeyboardScancode(code: 0x42),
        kVK_F9: RDPKeyboardScancode(code: 0x43), kVK_F10: RDPKeyboardScancode(code: 0x44),
        kVK_F11: RDPKeyboardScancode(code: 0x57), kVK_F12: RDPKeyboardScancode(code: 0x58),
        kVK_F13: RDPKeyboardScancode(code: 0x64), kVK_F14: RDPKeyboardScancode(code: 0x65),
        kVK_F15: RDPKeyboardScancode(code: 0x66), kVK_F16: RDPKeyboardScancode(code: 0x67),
        kVK_F17: RDPKeyboardScancode(code: 0x68), kVK_F18: RDPKeyboardScancode(code: 0x69),
        kVK_F19: RDPKeyboardScancode(code: 0x6A), kVK_F20: RDPKeyboardScancode(code: 0x6B),
        // kVK_ANSI_KeypadClear stays unmapped: it sits where PC keypads have Num Lock (0x45), which
        // would turn off the Num Lock state that focus synchronization keeps on.
        kVK_ANSI_KeypadDivide: RDPKeyboardScancode(code: 0x35, isExtended: true),
        kVK_ANSI_KeypadMultiply: RDPKeyboardScancode(code: 0x37),
        kVK_ANSI_KeypadMinus: RDPKeyboardScancode(code: 0x4A),
        kVK_ANSI_KeypadPlus: RDPKeyboardScancode(code: 0x4E),
        kVK_ANSI_KeypadEnter: RDPKeyboardScancode(code: 0x1C, isExtended: true),
        kVK_ANSI_KeypadDecimal: RDPKeyboardScancode(code: 0x53),
        kVK_JIS_KeypadComma: RDPKeyboardScancode(code: 0x7E),
        kVK_ANSI_Keypad7: RDPKeyboardScancode(code: 0x47), kVK_ANSI_Keypad8: RDPKeyboardScancode(code: 0x48),
        kVK_ANSI_Keypad9: RDPKeyboardScancode(code: 0x49), kVK_ANSI_Keypad4: RDPKeyboardScancode(code: 0x4B),
        kVK_ANSI_Keypad5: RDPKeyboardScancode(code: 0x4C), kVK_ANSI_Keypad6: RDPKeyboardScancode(code: 0x4D),
        kVK_ANSI_Keypad1: RDPKeyboardScancode(code: 0x4F), kVK_ANSI_Keypad2: RDPKeyboardScancode(code: 0x50),
        kVK_ANSI_Keypad3: RDPKeyboardScancode(code: 0x51), kVK_ANSI_Keypad0: RDPKeyboardScancode(code: 0x52),
        kVK_Help: RDPKeyboardScancode(code: 0x52, isExtended: true),
        kVK_Home: RDPKeyboardScancode(code: 0x47, isExtended: true),
        kVK_PageUp: RDPKeyboardScancode(code: 0x49, isExtended: true),
        kVK_ForwardDelete: RDPKeyboardScancode(code: 0x53, isExtended: true),
        kVK_End: RDPKeyboardScancode(code: 0x4F, isExtended: true),
        kVK_PageDown: RDPKeyboardScancode(code: 0x51, isExtended: true),
        kVK_LeftArrow: RDPKeyboardScancode(code: 0x4B, isExtended: true),
        kVK_RightArrow: RDPKeyboardScancode(code: 0x4D, isExtended: true),
        kVK_DownArrow: RDPKeyboardScancode(code: 0x50, isExtended: true),
        kVK_UpArrow: RDPKeyboardScancode(code: 0x48, isExtended: true),
        kVK_ContextualMenu: RDPKeyboardScancode(code: 0x5D, isExtended: true),
    ]

    private static let scancodeOnlyKeyCodes = Set(scancodeOnlyKeys.keys)

    private static let scancodes = scancodeOnlyKeys.merging(
        characterScancodes.mapValues { RDPKeyboardScancode(code: $0) }
    ) { scancodeOnly, _ in scancodeOnly }
}
