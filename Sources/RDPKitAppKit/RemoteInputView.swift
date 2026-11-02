#if os(macOS)
import AppKit
import Carbon.HIToolbox
import RDPKit

/// Where `RDPRemoteInputView` sends input: the session's `RDPInputSession`, or a test's stand-in.
public protocol RDPInputEventSending: AnyObject {
    /// Whether `send` delivers `.unicode` events; without them, text goes as the keys pressed.
    var supportsUnicodeInput: Bool { get }
    /// The toggle keys the server last said are on, nil when it has not said; the view
    /// synchronizes them again when the server's Caps Lock changes away from the Mac's.
    var serverToggleKeys: RDPToggleKeyFlags? { get }
    func send(_ events: [RDPSlowPathInputEvent])
}

extension RDPInputEventSending {
    public var serverToggleKeys: RDPToggleKeyFlags? {
        nil
    }
}

extension RDPInputSession: RDPInputEventSending {}

/// A view that sends the Mac's keyboard, mouse and scroll input to the server, over the remote
/// desktop it lies on:
/// - keys go as scancodes where the server's layout types what the Mac's does, and as Unicode
///   otherwise, with dead keys, Option's characters and Japanese input handled as `keyboard`
///   needs;
/// - Command goes as the Windows key, held back until another key, button or wheel event goes
///   with it, or sent as a tap when released alone; right Option is held back likewise;
/// - modifiers are reconciled with each event's flags, pressed from their own side bits and
///   released when the flags show them up, and held keys and buttons are released when the view
///   loses focus, its window resigns key or a menu opens, with no session too;
/// - a button goes up only if the server saw it go down, and a drag past the shown desktop
///   stops on its edge;
/// - the toggle keys are synchronized when the view gains focus ([MS-RDPBCGR] 2.2.8.1.1.3.1.1.5),
///   and again when an event shows a Caps Lock change the view missed, or after the server
///   says its Caps Lock changed away from the Mac's (`serverToggleKeys`).
///
/// Set `rdpFrame` to the latest frame, so points map onto the desktop as the view, filling its
/// window, shows it, or `pointMapping` for a view that shows part of it; `keyboard` to what the
/// session announced; and `inputSession` once the session has one. `claimsCommandShortcuts`
/// gives ⌘ and ⌃ chords to the server ahead of the menus. The view does not hide the Mac's
/// cursor.
public final class RDPRemoteInputView: NSView {
    /// The latest frame, whose whole desktop the view's points map onto as the view, filling
    /// its window, shows it (`RDPRemoteDisplayViewport(frame:view:)`), unless `pointMapping`
    /// is set. No point maps without either.
    public var rdpFrame: RDPFrameMetadata?
    /// Maps the view's points onto the desktop in place of `rdpFrame`, for a view that shows
    /// part of it, such as chosen monitors, so pointer events land where the video shows them.
    /// A change releases nothing: keys and buttons are still down on the Mac, and the next event
    /// maps through the new mapping.
    public var pointMapping: (any RDPRemotePointMapping)?
    /// The keyboard the session announced; it decides which keys can go as scancodes.
    public var keyboard = RDPKeyboard.unitedStates
    /// Whether ⌘ and ⌃ chords on keys with a scancode go to the server before the menu bar's
    /// key equivalents can take them, while the view is first responder with a session. Off,
    /// the menus get them first and the server gets those they leave.
    public var claimsCommandShortcuts = false
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
    /// accent, which the server never asked for, so the next key, if a character key, is composed
    /// with it here.
    private var deadKeyAfterChordedDeadKey: (keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags)?
    /// The toggle-key state the server was last synchronized with.
    private var synchronizedToggleFlags: RDPToggleKeyFlags?
    /// The toggle keys the server said were on when the view last looked.
    private var lastServerToggleKeys: RDPToggleKeyFlags?
    private var commandKeyUpMonitor: Any?

    /// A server that takes no Unicode input gets every key as its scancode, so its own layout
    /// types the text, including what its dead keys compose; the Mac's text never goes.
    private var isUnicodeInputSupported: Bool {
        inputSession?.supportsUnicodeInput ?? true
    }

    /// A view released while still in its window was never told to stop observing it. The
    /// notification observers go with the view, but the key-up monitor must be removed.
    deinit {
        MainActor.assumeIsolated {
            if let commandKeyUpMonitor {
                NSEvent.removeMonitor(commandKeyUpMonitor)
            }
        }
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
        syncModifierKeys(forButtonDown: event)
        sendPointerButton(.left, isDown: true, event: event)
    }

    override public func mouseUp(with event: NSEvent) {
        releaseModifiers(missingFrom: event.modifierFlags)
        sendPointerButton(.left, isDown: false, event: event)
    }

    override public func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        syncModifierKeys(forButtonDown: event)
        sendPointerButton(.right, isDown: true, event: event)
    }

    override public func rightMouseUp(with event: NSEvent) {
        releaseModifiers(missingFrom: event.modifierFlags)
        sendPointerButton(.right, isDown: false, event: event)
    }

    override public func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        syncModifierKeys(forButtonDown: event)
        guard let button = pointerButton(for: event) else {
            return
        }
        sendPointerButton(button, isDown: true, event: event)
    }

    override public func otherMouseUp(with event: NSEvent) {
        releaseModifiers(missingFrom: event.modifierFlags)
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
        // Held-back keys go down first, as they do ahead of a click, so Alt-scroll and
        // Command-scroll reach the server as Alt and Windows with the wheel.
        let move = RDPMacScrollWheel.pointerMove(to: point, inputState: &inputState)
        sendInput(deferredModifierKeys.flush(&inputState) + move + events)
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        // With `claimsCommandShortcuts`, ⌘/⌃ chords belong to the remote session while the
        // user controls it, so they are claimed here before the menu bar's key equivalents.
        guard claimsCommandShortcuts,
              inputSession != nil,
              window?.firstResponder === self,
              event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control]).isEmpty == false,
              let scancode = RDPMacKeyboardMapping.scancode(forKeyCode: event.keyCode)
        else {
            // A chord the remote never sees, such as one on a key with no
            // scancode that a menu may take, must not leave the release of
            // Command or right Option to tap the Windows key or Alt there.
            if event.modifierFlags.isDisjoint(with: [.command, .control]) == false {
                deferredModifierKeys.noteChordedElsewhere()
            }
            return false
        }
        syncModifierKeys(with: event)
        sendKeyboardScancode(scancode, isReleased: false)
        return true
    }

    override public func keyDown(with event: NSEvent) {
        syncModifierKeys(with: event)
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
        } else if let deadKey, RDPMacKeyboardMapping.isCharacterKey(uncomposed: uncomposedOutput(event.keyCode, event.modifierFlags)) {
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
            // a repeat types it no more, and text never goes with Command or Control.
            if isUnicodeInputSupported, event.isARepeat == false, isComposedByChordedDeadKey == false,
               event.modifierFlags.isDisjoint(with: [.command, .control]),
               let text = RDPMacKeyboardMapping.deadKeyText(aheadOf: characters)
            {
                sendInput(RDPMacKeyboardMapping.unicodeEvents(for: text))
            }
            sendKeyboardScancode(scancode, isReleased: false)
            // A dead key that went as a chord, as left Option-E goes as Alt-E.
            followsChordedDeadKey = characters?.isEmpty == true && isDeadKey(event.keyCode, event.modifierFlags)
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
        var events: [RDPSlowPathInputEvent] = []
        if Int(event.keyCode) == kVK_CapsLock {
            events += toggleKeySynchronizationEvents(event.modifierFlags)
        } else if let modifier = RDPMacModifierKey(keyCode: event.keyCode) {
            // The key code names the side that changed, so on keyboards that
            // report no side bits the side-independent flag tells its state.
            let isDown = modifier.isDown(in: event.modifierFlags)
            if isDown != isModifierPressed(modifier.scancode) {
                // Before a press, a modifier whose release the view missed goes up, so that
                // Command or right Option pressed after it is not taken for part of a chord.
                if isDown {
                    events += modifierReleaseEvents(missingFrom: event.modifierFlags)
                }
                events += modifierEvents(modifier.scancode, isDown: isDown)
            }
        }
        // After the change itself, so that Command or right Option released
        // alone still sends its deferred tap. Once the shared flag clears,
        // this also releases the other side of a keyboard that reports no
        // side bits.
        events += modifierSyncEvents(for: event.modifierFlags)
        sendInput(events)
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

    /// A menu, such as the menu bar or the ⋯ menu, takes the keyboard while it tracks without the
    /// window resigning key, so the key-ups of keys held as it opens go to the menu. They are
    /// released as on focus loss, and the next key, click or modifier presses the modifiers still
    /// held. With no session, nothing is sent, but the keys are no longer tracked as held, so the
    /// next session's attach does not press them there.
    @objc private func menuDidBeginTracking(_: Notification) {
        releasePressedInputs()
    }

    @objc private func windowDidBecomeKey(_: Notification) {
        if window?.firstResponder === self {
            synchronizeToggleKeys(NSEvent.modifierFlags)
        }
    }

    private func forwardCommandKeyUp(_ event: NSEvent) {
        guard event.modifierFlags.contains(.command),
              event.window === window,
              window?.firstResponder === self
        else {
            return
        }
        // The key went to the server, or a shortcut the system took, such as ⌘⌥D, used it;
        // either way releasing Command or right Option is no tap.
        deferredModifierKeys.noteChordedElsewhere()
        keyUp(with: event)
    }

    /// Reconciles every modifier key with the event's flags, so a modifier
    /// transition the view never saw (window was not key at the time) cannot
    /// leave the remote state inverted. A key the flags show up is released;
    /// a key is pressed only when its own side bit shows it down, since a
    /// keyboard that reports no side bits does not say which side is held.
    private func modifierSyncEvents(for modifierFlags: NSEvent.ModifierFlags) -> [RDPSlowPathInputEvent] {
        modifierReleaseEvents(missingFrom: modifierFlags) + modifierPressEvents(for: modifierFlags)
    }

    /// AppKit does not deliver every modifier release to the view, for
    /// example one made while a menu is open or while another app such as
    /// Spotlight has the keyboard, so every event releases the modifiers its
    /// flags show up. Only key-down, button-down and modifier events press
    /// the ones they show held: those are input the user aims at the remote.
    private func releaseModifiers(missingFrom modifierFlags: NSEvent.ModifierFlags) {
        let events = modifierReleaseEvents(missingFrom: modifierFlags)
        if events.isEmpty == false {
            sendInput(events)
        }
    }

    private func modifierReleaseEvents(missingFrom modifierFlags: NSEvent.ModifierFlags) -> [RDPSlowPathInputEvent] {
        RDPMacModifierKey.all.compactMap { modifier in
            let scancode = modifier.scancode
            guard modifier.isDown(in: modifierFlags) == false else {
                return nil
            }
            // A held-back Windows key or right Alt whose release the view
            // missed never reached the server, so it is dropped without a tap.
            deferredModifierKeys.discard(scancode)
            return inputState.isScancodePressed(scancode) ? inputState.keyboard(scancode: scancode, isReleased: true) : nil
        }
    }

    private func modifierPressEvents(for modifierFlags: NSEvent.ModifierFlags) -> [RDPSlowPathInputEvent] {
        RDPMacModifierKey.all.flatMap { modifier -> [RDPSlowPathInputEvent] in
            let scancode = modifier.scancode
            guard isModifierPressed(scancode) == false, modifier.isSideDown(in: modifierFlags) else {
                return []
            }
            let events = modifierEvents(scancode, isDown: true)
            // Command or right Option found held, not seen going down, may be
            // left over from a Cmd-Tab into this window; releasing it alone is
            // no tap.
            if deferredModifierKeys.isHeld(scancode) {
                deferredModifierKeys.noteChordedElsewhere()
            }
            return events
        }
    }

    private func isModifierPressed(_ scancode: RDPKeyboardScancode) -> Bool {
        inputState.isScancodePressed(scancode) || deferredModifierKeys.isHeld(scancode)
    }

    /// The events that press or release a modifier. A Windows key not yet on the server is held
    /// back by `deferredModifierKeys`, and so is right Alt while the server takes Unicode input;
    /// any other press sends the held-back Windows keys down first. Right Alt stays held back,
    /// since Shift-Option types characters too, but releasing it is no longer a tap.
    private func modifierEvents(_ scancode: RDPKeyboardScancode, isDown: Bool) -> [RDPSlowPathInputEvent] {
        if RDPMacDeferredModifierKeys.isDeferred(scancode, holdsBackAlt: isUnicodeInputSupported),
           inputState.isScancodePressed(scancode) == false
        {
            if isDown {
                deferredModifierKeys.press(scancode, inputState: inputState)
                return []
            }
            return deferredModifierKeys.release(scancode)
        }
        if isDown {
            return deferredModifierKeys.flushWindowsKeys(&inputState) + [inputState.keyboard(scancode: scancode, isReleased: false)]
        }
        return [inputState.keyboard(scancode: scancode, isReleased: true)]
    }

    /// A Caps Lock toggle the view never saw, such as one made while a menu was open, leaves the
    /// server's Caps Lock stale, and the letters it shifts go as scancodes, so the toggle-key
    /// state is synchronized first when the event's differs.
    private func syncModifierKeys(with event: NSEvent) {
        sendInput(staleToggleKeyEvents(event.modifierFlags) + modifierSyncEvents(for: event.modifierFlags))
    }

    /// A Command-click on a window in the background reaches the view without making the window
    /// key, so the release of a modifier held for it goes to another app. Such a click only
    /// releases the modifiers its flags show up; it presses none. Caps Lock is the Mac's either
    /// way, so a stale one is synchronized all the same.
    private func syncModifierKeys(forButtonDown event: NSEvent) {
        guard window?.isKeyWindow == true else {
            sendInput(staleToggleKeyEvents(event.modifierFlags) + modifierReleaseEvents(missingFrom: event.modifierFlags))
            return
        }
        syncModifierKeys(with: event)
    }

    /// The toggle keys are stale when the Mac's changed since the last synchronization, or when
    /// the server newly says its Caps Lock is not the Mac's, as another client of the session or
    /// a server setting can change it. A server that keeps saying the same gets one
    /// synchronization for it, not one per key.
    private func staleToggleKeyEvents(_ modifierFlags: NSEvent.ModifierFlags) -> [RDPSlowPathInputEvent] {
        let toggleFlags = RDPMacKeyboardMapping.toggleFlags(for: modifierFlags)
        let isStaleOnTheMac = synchronizedToggleFlags.map { $0 != toggleFlags } ?? false
        let serverToggleKeys = inputSession?.serverToggleKeys
        let isStaleOnTheServer = serverToggleKeys.map {
            $0 != lastServerToggleKeys && $0.contains(.capsLock) != toggleFlags.contains(.capsLock)
        } ?? false
        lastServerToggleKeys = serverToggleKeys
        guard isStaleOnTheMac || isStaleOnTheServer else {
            return []
        }
        return toggleKeySynchronizationEvents(modifierFlags)
    }

    /// MS-RDPBCGR 2.2.8.1.1.3.1.1.5: on focus gain, send the toggle-key state followed by the
    /// keys still held, since the server's state may have changed while focus was elsewhere.
    private func synchronizeToggleKeys(_ modifierFlags: NSEvent.ModifierFlags) {
        sendInput(toggleKeySynchronizationEvents(modifierFlags))
    }

    private func toggleKeySynchronizationEvents(_ modifierFlags: NSEvent.ModifierFlags) -> [RDPSlowPathInputEvent] {
        let toggleFlags = RDPMacKeyboardMapping.toggleFlags(for: modifierFlags)
        synchronizedToggleFlags = toggleFlags
        lastServerToggleKeys = inputSession?.serverToggleKeys
        return inputState.synchronizationEvents(toggleFlags: toggleFlags)
    }

    /// A drag that leaves the shown area holds the pointer on its nearest shown pixel, so a drag
    /// still reaches the desktop's edge; a plain move there sends nothing.
    private func sendPointerMove(_ event: NSEvent, isDragging: Bool = false) {
        releaseModifiers(missingFrom: event.modifierFlags)
        guard let point = remotePoint(from: event, clampingToShownArea: isDragging) else {
            return
        }
        sendInput([inputState.pointerMove(to: point)])
    }

    /// A press off the shown area goes nowhere. A release goes only for a button the server
    /// saw go down, so a press dropped in a gap never sends a stray release; off the shown area
    /// it goes at the nearest shown pixel, where the drag that led there stopped.
    private func sendPointerButton(_ button: RDPPointerButton, isDown: Bool, event: NSEvent) {
        guard isDown || inputState.isPointerButtonPressed(button) else {
            return
        }
        let point = remotePoint(from: event, clampingToShownArea: isDown == false)
        guard let inputEvent = inputState.pointerButton(button, isDown: isDown, at: point) else {
            return
        }
        let deferredKeyEvents = isDown ? deferredModifierKeys.flush(&inputState) : []
        sendInput(deferredKeyEvents + [inputEvent])
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
        let deferredKeyEvents = isReleased ? [] : deferredModifierKeys.flush(&inputState)
        sendInput(deferredKeyEvents + [inputState.keyboard(scancode: scancode, isReleased: isReleased)])
    }

    /// Every send goes through here, not `inputSession?.send(...)`, so that its events are built,
    /// and the key and button state updated, with no session too: the optional chain skips both,
    /// which left a modifier the view saw released pressed for the next session.
    private func sendInput(_ events: [RDPSlowPathInputEvent]) {
        inputSession?.send(events)
    }

    /// A Windows key or right Alt still held back never reached the server, so nothing is sent
    /// for it.
    private func releasePressedInputs() {
        deferredModifierKeys.reset()
        followsChordedDeadKey = false
        deadKeyAfterChordedDeadKey = nil
        sendInput(inputState.releasePressedInputs())
    }

    /// `clampingToShownArea` moves a point off the shown area, such as a drag's past the
    /// letterbox or into a gap between chosen displays, onto the nearest shown pixel.
    private func remotePoint(from event: NSEvent, clampingToShownArea: Bool = false) -> RDPRemotePoint? {
        guard let mapping = pointMapping ?? rdpFrame.map({ RDPRemoteDisplayViewport(frame: $0, view: self) }) else {
            return nil
        }
        let localPoint = convert(event.locationInWindow, from: nil)
        return clampingToShownArea
            ? mapping.nearestRemotePoint(to: localPoint)
            : mapping.remotePoint(at: localPoint)
    }
}
#endif
