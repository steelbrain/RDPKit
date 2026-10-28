import AppKit
import Carbon.HIToolbox
import RDPKit

final class RemoteInputCaptureNSView: NSView {
    var rdpFrame: RDPFrameMetadata?
    var inputSession: RDPInputSession? {
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
        sendPointerMove(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPointerMove(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendPointerMove(event)
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
        guard let point = remotePoint(from: event) else {
            return
        }
        inputState.updatePointerLocation(point)
        let events = wheelAccumulator.events(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            at: point
        )
        guard events.isEmpty == false else {
            return
        }
        inputSession?.send(events)
    }

    override func keyDown(with event: NSEvent) {
        if let scancode = MacRDPKeyboardMapping.scancode(forKeyCode: event.keyCode),
           MacRDPKeyboardMapping.shouldSendScancode(forKeyCode: event.keyCode, modifierFlags: event.modifierFlags)
        {
            sendKeyboardScancode(scancode, isReleased: false, isRepeat: event.isARepeat)
            return
        }
        guard event.modifierFlags.isDisjoint(with: [.command, .control]) else {
            return
        }
        let events = MacRDPKeyboardMapping.unicodeEvents(for: event.characters ?? "")
        guard events.isEmpty == false else {
            return
        }
        inputSession?.send(events)
    }

    override func keyUp(with event: NSEvent) {
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
            return
        }
        guard let modifier = MacRDPModifierKey(keyCode: event.keyCode) else {
            return
        }
        let isDown = modifier.isDown(in: event.modifierFlags)
        guard isDown != inputState.isScancodePressed(modifier.scancode) else {
            return
        }
        sendKeyboardScancode(modifier.scancode, isReleased: !isDown)
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
        keyUp(with: event)
    }

    private func sendPointerMove(_ event: NSEvent) {
        guard let point = remotePoint(from: event) else {
            return
        }
        inputSession?.send(inputState.pointerMove(to: point))
    }

    private func sendPointerButton(_ button: RDPPointerButton, isDown: Bool, event: NSEvent) {
        guard let inputEvent = inputState.pointerButton(button, isDown: isDown, at: remotePoint(from: event)) else {
            return
        }
        inputSession?.send(inputEvent)
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

    private func sendKeyboardScancode(_ scancode: RDPKeyboardScancode, isReleased: Bool, isRepeat: Bool = false) {
        inputSession?.send(inputState.keyboard(scancode: scancode, isReleased: isReleased, isRepeat: isRepeat))
    }

    private func releasePressedInputs() {
        inputSession?.send(inputState.releasePressedInputs())
    }

    private func remotePoint(from event: NSEvent) -> RDPRemotePoint? {
        guard let rdpFrame else {
            return nil
        }
        let localPoint = convert(event.locationInWindow, from: nil)
        return RDPRemoteDisplayViewport(
            frame: rdpFrame,
            bounds: bounds,
            coordinateOrigin: .bottomLeft
        ).remotePoint(from: localPoint)
    }
}

/// Converts AppKit scroll deltas into RDP wheel rotations (120 units per wheel notch).
struct RDPScrollWheelAccumulator {
    private static let unitsPerLine = 120.0
    private static let unitsPerPoint = 10.0
    // MS-RDPBCGR 2.2.8.1.1.3.1.1.3: the rotation is a 9-bit two's complement value.
    private static let maximumRotation = 255

    private var verticalRemainder = 0.0
    private var horizontalRemainder = 0.0

    /// AppKit reports positive `deltaX` for scrolling left, while RDP horizontal rotation is
    /// positive to the right, so the horizontal axis is negated.
    mutating func events(
        deltaX: CGFloat,
        deltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        at point: RDPRemotePoint
    ) -> [RDPSlowPathInputEvent] {
        let scale = hasPreciseScrollingDeltas ? Self.unitsPerPoint : Self.unitsPerLine
        let vertical = Self.rotations(Double(deltaY) * scale, remainder: &verticalRemainder)
            .map { RDPSlowPathInputEvent.verticalWheel(rotation: $0, x: point.x, y: point.y) }
        let horizontal = Self.rotations(-Double(deltaX) * scale, remainder: &horizontalRemainder)
            .map { RDPSlowPathInputEvent.horizontalWheel(rotation: $0, x: point.x, y: point.y) }
        return vertical + horizontal
    }

    private static func rotations(_ units: Double, remainder: inout Double) -> [Int] {
        guard units.isFinite else {
            return []
        }
        let total = remainder + units
        var whole = Int(total.rounded(.towardZero))
        remainder = total - Double(whole)
        var rotations: [Int] = []
        while whole != 0 {
            let rotation = max(-maximumRotation, min(maximumRotation, whole))
            rotations.append(rotation)
            whole -= rotation
        }
        return rotations
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

    let scancode: RDPKeyboardScancode
    private let flag: NSEvent.ModifierFlags
    private let deviceMask: UInt
    private let pairDeviceMask: UInt

    init?(keyCode: UInt16) {
        switch Int(keyCode) {
        case kVK_Shift:
            self.init(0x2A, flag: .shift, deviceMask: Self.leftShift, pair: Self.rightShift)
        case kVK_RightShift:
            self.init(0x36, flag: .shift, deviceMask: Self.rightShift, pair: Self.leftShift)
        case kVK_Control:
            self.init(0x1D, flag: .control, deviceMask: Self.leftControl, pair: Self.rightControl)
        case kVK_RightControl:
            self.init(0x1D, isExtended: true, flag: .control, deviceMask: Self.rightControl, pair: Self.leftControl)
        case kVK_Option:
            self.init(0x38, flag: .option, deviceMask: Self.leftOption, pair: Self.rightOption)
        case kVK_RightOption:
            self.init(0x38, isExtended: true, flag: .option, deviceMask: Self.rightOption, pair: Self.leftOption)
        case kVK_Command:
            self.init(0x5B, isExtended: true, flag: .command, deviceMask: Self.leftCommand, pair: Self.rightCommand)
        case kVK_RightCommand:
            self.init(0x5C, isExtended: true, flag: .command, deviceMask: Self.rightCommand, pair: Self.leftCommand)
        default:
            return nil
        }
    }

    private init(_ code: UInt16, isExtended: Bool = false, flag: NSEvent.ModifierFlags, deviceMask: UInt, pair: UInt) {
        scancode = RDPKeyboardScancode(code: code, isExtended: isExtended)
        self.flag = flag
        self.deviceMask = deviceMask
        pairDeviceMask = deviceMask | pair
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

    static func scancode(forKeyCode keyCode: UInt16) -> RDPKeyboardScancode? {
        scancodes[Int(keyCode)]
    }

    static func shouldSendScancode(forKeyCode keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        nonCharacterKeyCodes.contains(Int(keyCode))
            || modifierFlags.isDisjoint(with: [.command, .control, .option]) == false
    }

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
    ]

    private static let nonCharacterScancodes: [Int: RDPKeyboardScancode] = [
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
        kVK_ANSI_KeypadClear: RDPKeyboardScancode(code: 0x45),
        kVK_ANSI_KeypadEquals: RDPKeyboardScancode(code: 0x0D),
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

    private static let nonCharacterKeyCodes = Set(nonCharacterScancodes.keys)

    private static let scancodes = nonCharacterScancodes.merging(
        characterScancodes.mapValues { RDPKeyboardScancode(code: $0) }
    ) { nonCharacter, _ in nonCharacter }
}
