#if os(macOS)
import AppKit
import Carbon.HIToolbox
import RDPKit

/// Where `RDPRemoteInputView` sends input: the session's `RDPInputSession`, or a test's stand-in.
public protocol RDPInputEventSending: AnyObject {
    /// Whether `send` delivers `.unicode` events; without them, text goes as the keys pressed.
    var supportsUnicodeInput: Bool { get }
    func send(_ events: [RDPSlowPathInputEvent])
}

extension RDPInputSession: RDPInputEventSending {}

/// A view that sends the Mac's keyboard, mouse and scroll input to the server, over the remote
/// desktop it lies on:
/// - keys go as scancodes where the server's layout types what the Mac's does, and as Unicode
///   otherwise, with dead keys, Option's characters and Japanese input handled as `keyboard`
///   needs;
/// - Command goes as the Windows key, held back until another key, button or wheel event goes
///   with it, or sent as a tap when released alone; right Option is held back likewise;
/// - modifiers are reconciled with each event's flags, and held keys and buttons are released
///   when the view loses focus, its window resigns key or a menu opens;
/// - the toggle keys are synchronized when the view gains focus ([MS-RDPBCGR] 2.2.8.1.1.3.1.1.5).
///
/// Set `rdpFrame` to the latest frame, so points map onto the desktop as the view, filling its
/// window, shows it, `keyboard` to what the session announced, and `inputSession` once the
/// session has one. The view does not hide the Mac's cursor.
public final class RDPRemoteInputView: NSView {
    /// The latest frame, whose desktop the view's points map onto; no point maps without one.
    public var rdpFrame: RDPFrameMetadata?
    /// The keyboard the session announced; it decides which keys can go as scancodes.
    public var keyboard = RDPKeyboard.unitedStates
    /// Whether the Mac's layout makes a key a dead key with these modifiers; tests replace it.
    var isDeadKey: @MainActor (UInt16, NSEvent.ModifierFlags) -> Bool = RDPMacDeadKeys.isDeadKey(keyCode:modifierFlags:)
    /// What the Mac's layout types for a key with no dead key pending; tests replace it.
    var uncomposedOutput: @MainActor (UInt16, NSEvent.ModifierFlags) -> String? = RDPMacDeadKeys.output(keyCode:modifierFlags:)
    /// What the Mac's layout types for a key (the first two arguments) right after a dead key
    /// (the last two) with nothing else pending; tests replace it.
    var composedOutput: @MainActor (UInt16, NSEvent.ModifierFlags, UInt16, NSEvent.ModifierFlags) -> String? =
        RDPMacDeadKeys.output(keyCode:modifierFlags:afterDeadKey:deadKeyModifierFlags:)
    /// Where input goes; nil sends nothing. Replacing it releases what the old one holds.
    public var inputSession: (any RDPInputEventSending)? {
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
    private var deferredModifierKeys = RDPMacDeferredModifierKeys()
    private var wheelAccumulator = RDPScrollWheelAccumulator()
    /// A dead key went to the server as an Alt chord, so macOS composes the next key with its accent.
    private var followsChordedDeadKey = false
    /// A dead key typed right after one that went as a chord. macOS may spend it on that one's
    /// accent, which the server never asked for, so the next key is composed with it here.
    private var deadKeyAfterChordedDeadKey: (keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags)?
    /// The toggle-key state the server was last synchronized with.
    private var synchronizedToggleFlags: RDPToggleKeyFlags?
    private var commandKeyUpMonitor: Any?

    /// A server that takes no Unicode input gets every key as its scancode, so its own layout
    /// types the text, including what its dead keys compose; the Mac's text never goes.
    private var isUnicodeInputSupported: Bool {
        inputSession?.supportsUnicodeInput ?? true
    }

    override public var acceptsFirstResponder: Bool {
        true
    }

    override public func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override public func updateTrackingAreas() {
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

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        releasePressedInputs()
        stopObservingWindow()
        super.viewWillMove(toWindow: newWindow)
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObservingWindow()
    }

    override public func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            synchronizeToggleKeys(NSEvent.modifierFlags)
        }
        return didBecomeFirstResponder
    }

    override public func resignFirstResponder() -> Bool {
        releasePressedInputs()
        return super.resignFirstResponder()
    }

    override public func mouseMoved(with event: NSEvent) {
        sendPointerMove(event)
    }

    override public func mouseDragged(with event: NSEvent) {
        sendPointerMove(event, isDragging: true)
    }

    override public func rightMouseDragged(with event: NSEvent) {
        sendPointerMove(event, isDragging: true)
    }

    override public func otherMouseDragged(with event: NSEvent) {
        sendPointerMove(event, isDragging: true)
    }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointerButton(.left, isDown: true, event: event)
    }

    override public func mouseUp(with event: NSEvent) {
        sendPointerButton(.left, isDown: false, event: event)
    }

    override public func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointerButton(.right, isDown: true, event: event)
    }

    override public func rightMouseUp(with event: NSEvent) {
        sendPointerButton(.right, isDown: false, event: event)
    }

    override public func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let button = pointerButton(for: event) else {
            return
        }
        sendPointerButton(button, isDown: true, event: event)
    }

    override public func otherMouseUp(with event: NSEvent) {
        guard let button = pointerButton(for: event) else {
            return
        }
        sendPointerButton(button, isDown: false, event: event)
    }

    override public func scrollWheel(with event: NSEvent) {
        releaseModifiers(missingFrom: event.modifierFlags)
        guard let point = remotePoint(from: event) else {
            return
        }
        let events = wheelAccumulator.events(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas,
            at: point
        )
        guard events.isEmpty == false else {
            return
        }
        let move = RDPMacScrollWheel.pointerMove(to: point, inputState: &inputState)
        sendInput(deferredModifierKeys.flush(&inputState) + move + events)
    }

    override public func keyDown(with event: NSEvent) {
        releaseModifiers(missingFrom: event.modifierFlags)
        synchronizeToggleKeysIfChanged(event.modifierFlags)
        let isComposedByChordedDeadKey = followsChordedDeadKey && event.isARepeat == false
        followsChordedDeadKey = false
        let deadKey = event.isARepeat ? nil : deadKeyAfterChordedDeadKey
        if event.isARepeat == false {
            deadKeyAfterChordedDeadKey = nil
        }
        let characters = if isComposedByChordedDeadKey {
            RDPMacKeyboardMapping.characters(
                afterChordedDeadKey: event.characters,
                uncomposed: uncomposedOutput(event.keyCode, event.modifierFlags)
            )
        } else if let deadKey {
            composedOutput(event.keyCode, event.modifierFlags, deadKey.keyCode, deadKey.modifierFlags) ?? event.characters
        } else {
            event.characters
        }
        if let scancode = RDPMacKeyboardMapping.scancode(forKeyCode: event.keyCode),
           RDPMacKeyboardMapping.shouldSendScancode(
               forKeyCode: event.keyCode,
               characters: characters,
               charactersIgnoringModifiers: event.charactersIgnoringModifiers,
               modifierFlags: event.modifierFlags,
               isHeldAsScancode: inputState.isScancodePressed(scancode),
               isAltPressed: RDPMacModifierKey.altScancodes.contains(where: inputState.isScancodePressed),
               isDeadKey: { isDeadKey(event.keyCode, event.modifierFlags) }
           ) || RDPMacKeyboardMapping.windowsTypes(
               characters,
               charactersIgnoringModifiers: event.charactersIgnoringModifiers,
               for: scancode,
               modifierFlags: event.modifierFlags,
               keyboard: keyboard
           ) || isUnicodeInputSupported == false
        {
            // A dead key's accent ahead of Return or Tab, unless that dead key went as a chord;
            // text never goes with Command or Control.
            if isUnicodeInputSupported, event.isARepeat == false, isComposedByChordedDeadKey == false,
               event.modifierFlags.isDisjoint(with: [.command, .control]),
               let text = RDPMacKeyboardMapping.deadKeyText(aheadOf: characters)
            {
                sendInput(RDPMacKeyboardMapping.unicodeEvents(for: text))
            }
            sendKeyboardScancode(scancode, isReleased: false)
            // A dead key that went as a chord, as left Option-E goes as Alt-E.
            if characters?.isEmpty == true, isDeadKey(event.keyCode, event.modifierFlags) {
                followsChordedDeadKey = true
            }
            return
        }
        guard event.modifierFlags.isDisjoint(with: [.command, .control]), isUnicodeInputSupported else {
            return
        }
        // Right Option, if held back, typed this or started a dead key, so it is no Alt tap.
        deferredModifierKeys.noteChordedElsewhere()
        if isComposedByChordedDeadKey, characters?.isEmpty == true, isDeadKey(event.keyCode, event.modifierFlags) {
            deadKeyAfterChordedDeadKey = (event.keyCode, event.modifierFlags)
        }
        let events = RDPMacKeyboardMapping.unicodeEvents(for: characters ?? "")
        guard events.isEmpty == false else {
            return
        }
        sendInput(events)
    }

    override public func keyUp(with event: NSEvent) {
        releaseModifiers(missingFrom: event.modifierFlags)
        guard let scancode = RDPMacKeyboardMapping.scancode(forKeyCode: event.keyCode),
              inputState.isScancodePressed(scancode)
        else {
            return
        }
        sendKeyboardScancode(scancode, isReleased: true)
    }

    override public func flagsChanged(with event: NSEvent) {
        if Int(event.keyCode) == kVK_CapsLock {
            synchronizeToggleKeys(event.modifierFlags)
        } else if let modifier = RDPMacModifierKey(keyCode: event.keyCode) {
            sendChanges(of: modifier, in: event.modifierFlags)
        }
        // After the change itself, so that Command released alone still sends its deferred tap.
        releaseModifiers(missingFrom: event.modifierFlags)
    }

    private func sendChanges(of modifier: RDPMacModifierKey, in modifierFlags: NSEvent.ModifierFlags) {
        let changes = modifier.changes(in: modifierFlags) {
            inputState.isScancodePressed($0) || deferredModifierKeys.isHeld($0)
        }
        for change in changes {
            if RDPMacDeferredModifierKeys.isDeferred(change.scancode, holdsBackAlt: isUnicodeInputSupported),
               inputState.isScancodePressed(change.scancode) == false
            {
                if change.isDown {
                    deferredModifierKeys.press(change.scancode, inputState: inputState)
                } else {
                    sendInput(deferredModifierKeys.release(change.scancode))
                }
            } else if change.isDown {
                sendInput(
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
        // A menu tracking the mouse or keyboard takes the key-ups of keys held meanwhile, which
        // would stay down on the server.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
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
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        if let commandKeyUpMonitor {
            NSEvent.removeMonitor(commandKeyUpMonitor)
            self.commandKeyUpMonitor = nil
        }
    }

    @objc private func windowDidResignKey(_: Notification) {
        releasePressedInputs()
    }

    @objc private func menuDidBeginTracking(_: Notification) {
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
        let toggleFlags = RDPMacKeyboardMapping.toggleFlags(for: modifierFlags)
        synchronizedToggleFlags = toggleFlags
        sendInput(inputState.synchronizationEvents(toggleFlags: toggleFlags))
    }

    /// A Caps Lock toggle the view never saw, such as one made while a menu was open, leaves the
    /// server's Caps Lock stale, and the letters it shifts go as scancodes, so a key or click
    /// whose flags show another toggle-key state synchronizes it first.
    private func synchronizeToggleKeysIfChanged(_ modifierFlags: NSEvent.ModifierFlags) {
        if let synchronizedToggleFlags,
           synchronizedToggleFlags != RDPMacKeyboardMapping.toggleFlags(for: modifierFlags)
        {
            synchronizeToggleKeys(modifierFlags)
        }
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
        for modifier in RDPMacModifierKey.all where modifier.isDown(in: modifierFlags) == false {
            if inputState.isScancodePressed(modifier.scancode) {
                events.append(inputState.keyboard(scancode: modifier.scancode, isReleased: true))
            }
            // A held-back key whose release went elsewhere never reached the server.
            deferredModifierKeys.discard(modifier.scancode)
        }
        if events.isEmpty == false {
            sendInput(events)
        }
    }

    private func sendPointerMove(_ event: NSEvent, isDragging: Bool = false) {
        releaseModifiers(missingFrom: event.modifierFlags)
        guard let point = remotePoint(from: event, clampingToDesktop: isDragging) else {
            return
        }
        sendInput([inputState.pointerMove(to: point)])
    }

    private func sendPointerButton(_ button: RDPPointerButton, isDown: Bool, event: NSEvent) {
        releaseModifiers(missingFrom: event.modifierFlags)
        if isDown {
            synchronizeToggleKeysIfChanged(event.modifierFlags)
        }
        guard let inputEvent = inputState.pointerButton(button, isDown: isDown, at: remotePoint(from: event)) else {
            return
        }
        let heldKeyEvents = isDown ? deferredModifierKeys.flush(&inputState) : []
        sendInput(heldKeyEvents + [inputEvent])
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
        sendInput(heldKeyEvents + [inputState.keyboard(scancode: scancode, isReleased: isReleased)])
    }

    /// Every send goes through here, not `inputSession?.send(...)`, so that its events are built,
    /// and the key and button state updated, with no session too: the optional chain skips both,
    /// which left a key released with no session pressed for the next session.
    private func sendInput(_ events: [RDPSlowPathInputEvent]) {
        inputSession?.send(events)
    }

    /// A key still held back never reached the server, so nothing is sent for it.
    private func releasePressedInputs() {
        deferredModifierKeys.reset()
        followsChordedDeadKey = false
        deadKeyAfterChordedDeadKey = nil
        sendInput(inputState.releasePressedInputs())
    }

    /// `clampingToDesktop` moves a point outside the desktop, such as a drag's past the
    /// letterbox, onto the desktop's nearest edge.
    private func remotePoint(from event: NSEvent, clampingToDesktop: Bool = false) -> RDPRemotePoint? {
        guard let rdpFrame else {
            return nil
        }
        let viewport = RDPRemoteDisplayViewport(frame: rdpFrame, view: self)
        let localPoint = convert(event.locationInWindow, from: nil)
        return clampingToDesktop ? viewport.nearestRemotePoint(from: localPoint) : viewport.remotePoint(from: localPoint)
    }
}
#endif
