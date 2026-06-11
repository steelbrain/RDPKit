import AppKit
import RDPKit

final class RemoteInputCaptureNSView: NSView {
    var rdpFrame: RDPFrameMetadata?
    var inputSession: RDPInputSession? {
        willSet {
            if inputSession != nil, inputSession !== newValue {
                releasePressedInputs()
            }
        }
    }

    private var trackingArea: NSTrackingArea?
    private var inputState = RDPInputStateTracker()

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
        if newWindow == nil {
            releasePressedInputs()
        }
        super.viewWillMove(toWindow: newWindow)
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
        let multiplier = event.hasPreciseScrollingDeltas ? 10.0 : 120.0
        let verticalRotation = Int((event.scrollingDeltaY * multiplier).rounded())
        let horizontalRotation = Int((event.scrollingDeltaX * multiplier).rounded())
        var events: [RDPSlowPathInputEvent] = []
        if verticalRotation != 0 {
            events.append(.verticalWheel(rotation: verticalRotation, x: point.x, y: point.y))
        }
        if horizontalRotation != 0 {
            events.append(.horizontalWheel(rotation: horizontalRotation, x: point.x, y: point.y))
        }
        guard events.isEmpty == false else {
            return
        }
        inputSession?.send(events)
    }

    override func keyDown(with event: NSEvent) {
        if let scancode = MacRDPKeyboardMapping.scancode(forKeyCode: event.keyCode),
           MacRDPKeyboardMapping.shouldSendScancode(for: event)
        {
            sendKeyboardScancode(scancode, isReleased: false, trackRelease: true, isRepeat: event.isARepeat)
            return
        }
        guard event.modifierFlags.intersection([.command, .control]).isEmpty else {
            return
        }
        guard let characters = event.characters, characters.isEmpty == false else {
            return
        }
        let events = characters.utf16.flatMap { codeUnit in
            [
                RDPSlowPathInputEvent.unicode(codeUnit: codeUnit, isReleased: false),
                RDPSlowPathInputEvent.unicode(codeUnit: codeUnit, isReleased: true),
            ]
        }
        inputSession?.send(events)
    }

    override func keyUp(with event: NSEvent) {
        guard let scancode = MacRDPKeyboardMapping.scancode(forKeyCode: event.keyCode) else {
            return
        }
        guard inputState.isScancodePressed(scancode) else {
            return
        }
        sendKeyboardScancode(scancode, isReleased: true, trackRelease: true)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let scancode = MacRDPKeyboardMapping.modifierScancode(forKeyCode: event.keyCode) else {
            return
        }
        let isReleased = inputState.isScancodePressed(scancode)
        sendKeyboardScancode(scancode, isReleased: isReleased, trackRelease: true)
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

    private func sendKeyboardScancode(
        _ scancode: RDPKeyboardScancode,
        isReleased: Bool,
        trackRelease: Bool,
        isRepeat: Bool = false
    ) {
        inputSession?.send(inputState.keyboard(
            scancode: scancode,
            isReleased: isReleased,
            trackRelease: trackRelease,
            isRepeat: isRepeat
        ))
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

private enum MacRDPKeyboardMapping {
    static func shouldSendScancode(for event: NSEvent) -> Bool {
        if alwaysSendsScancode(forKeyCode: event.keyCode) {
            return true
        }
        return event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false
    }

    static func scancode(forKeyCode keyCode: UInt16) -> RDPKeyboardScancode? {
        switch keyCode {
        case 0:
            RDPKeyboardScancode(code: 0x001E)
        case 1:
            RDPKeyboardScancode(code: 0x001F)
        case 2:
            RDPKeyboardScancode(code: 0x0020)
        case 3:
            RDPKeyboardScancode(code: 0x0021)
        case 4:
            RDPKeyboardScancode(code: 0x0023)
        case 5:
            RDPKeyboardScancode(code: 0x0022)
        case 6:
            RDPKeyboardScancode(code: 0x002C)
        case 7:
            RDPKeyboardScancode(code: 0x002D)
        case 8:
            RDPKeyboardScancode(code: 0x002E)
        case 9:
            RDPKeyboardScancode(code: 0x002F)
        case 11:
            RDPKeyboardScancode(code: 0x0030)
        case 12:
            RDPKeyboardScancode(code: 0x0010)
        case 13:
            RDPKeyboardScancode(code: 0x0011)
        case 14:
            RDPKeyboardScancode(code: 0x0012)
        case 15:
            RDPKeyboardScancode(code: 0x0013)
        case 16:
            RDPKeyboardScancode(code: 0x0015)
        case 17:
            RDPKeyboardScancode(code: 0x0014)
        case 18:
            RDPKeyboardScancode(code: 0x0002)
        case 19:
            RDPKeyboardScancode(code: 0x0003)
        case 20:
            RDPKeyboardScancode(code: 0x0004)
        case 21:
            RDPKeyboardScancode(code: 0x0005)
        case 22:
            RDPKeyboardScancode(code: 0x0007)
        case 23:
            RDPKeyboardScancode(code: 0x0006)
        case 24:
            RDPKeyboardScancode(code: 0x000D)
        case 25:
            RDPKeyboardScancode(code: 0x000A)
        case 26:
            RDPKeyboardScancode(code: 0x0008)
        case 27:
            RDPKeyboardScancode(code: 0x000C)
        case 28:
            RDPKeyboardScancode(code: 0x0009)
        case 29:
            RDPKeyboardScancode(code: 0x000B)
        case 30:
            RDPKeyboardScancode(code: 0x001B)
        case 31:
            RDPKeyboardScancode(code: 0x0018)
        case 32:
            RDPKeyboardScancode(code: 0x0016)
        case 33:
            RDPKeyboardScancode(code: 0x001A)
        case 34:
            RDPKeyboardScancode(code: 0x0017)
        case 35:
            RDPKeyboardScancode(code: 0x0019)
        case 36:
            RDPKeyboardScancode(code: 0x001C)
        case 37:
            RDPKeyboardScancode(code: 0x0026)
        case 38:
            RDPKeyboardScancode(code: 0x0024)
        case 39:
            RDPKeyboardScancode(code: 0x0028)
        case 40:
            RDPKeyboardScancode(code: 0x0025)
        case 41:
            RDPKeyboardScancode(code: 0x0027)
        case 42:
            RDPKeyboardScancode(code: 0x002B)
        case 43:
            RDPKeyboardScancode(code: 0x0033)
        case 44:
            RDPKeyboardScancode(code: 0x0035)
        case 45:
            RDPKeyboardScancode(code: 0x0031)
        case 46:
            RDPKeyboardScancode(code: 0x0032)
        case 47:
            RDPKeyboardScancode(code: 0x0034)
        case 48:
            RDPKeyboardScancode(code: 0x000F)
        case 49:
            RDPKeyboardScancode(code: 0x0039)
        case 50:
            RDPKeyboardScancode(code: 0x0029)
        case 51:
            RDPKeyboardScancode(code: 0x000E)
        case 53:
            RDPKeyboardScancode(code: 0x0001)
        case 65:
            RDPKeyboardScancode(code: 0x0053)
        case 67:
            RDPKeyboardScancode(code: 0x0037)
        case 69:
            RDPKeyboardScancode(code: 0x004E)
        case 71:
            RDPKeyboardScancode(code: 0x0045)
        case 75:
            RDPKeyboardScancode(code: 0x0035, isExtended: true)
        case 76:
            RDPKeyboardScancode(code: 0x001C, isExtended: true)
        case 78:
            RDPKeyboardScancode(code: 0x004A)
        case 81:
            RDPKeyboardScancode(code: 0x000D)
        case 82:
            RDPKeyboardScancode(code: 0x0052)
        case 83:
            RDPKeyboardScancode(code: 0x004F)
        case 84:
            RDPKeyboardScancode(code: 0x0050)
        case 85:
            RDPKeyboardScancode(code: 0x0051)
        case 86:
            RDPKeyboardScancode(code: 0x004B)
        case 87:
            RDPKeyboardScancode(code: 0x004C)
        case 88:
            RDPKeyboardScancode(code: 0x004D)
        case 89:
            RDPKeyboardScancode(code: 0x0047)
        case 91:
            RDPKeyboardScancode(code: 0x0048)
        case 92:
            RDPKeyboardScancode(code: 0x0049)
        case 114:
            RDPKeyboardScancode(code: 0x0052, isExtended: true)
        case 115:
            RDPKeyboardScancode(code: 0x0047, isExtended: true)
        case 116:
            RDPKeyboardScancode(code: 0x0049, isExtended: true)
        case 117:
            RDPKeyboardScancode(code: 0x0053, isExtended: true)
        case 119:
            RDPKeyboardScancode(code: 0x004F, isExtended: true)
        case 121:
            RDPKeyboardScancode(code: 0x0051, isExtended: true)
        case 123:
            RDPKeyboardScancode(code: 0x004B, isExtended: true)
        case 124:
            RDPKeyboardScancode(code: 0x004D, isExtended: true)
        case 125:
            RDPKeyboardScancode(code: 0x0050, isExtended: true)
        case 126:
            RDPKeyboardScancode(code: 0x0048, isExtended: true)
        case 122:
            RDPKeyboardScancode(code: 0x003B)
        case 120:
            RDPKeyboardScancode(code: 0x003C)
        case 99:
            RDPKeyboardScancode(code: 0x003D)
        case 118:
            RDPKeyboardScancode(code: 0x003E)
        case 96:
            RDPKeyboardScancode(code: 0x003F)
        case 97:
            RDPKeyboardScancode(code: 0x0040)
        case 98:
            RDPKeyboardScancode(code: 0x0041)
        case 100:
            RDPKeyboardScancode(code: 0x0042)
        case 101:
            RDPKeyboardScancode(code: 0x0043)
        case 109:
            RDPKeyboardScancode(code: 0x0044)
        case 103:
            RDPKeyboardScancode(code: 0x0057)
        case 111:
            RDPKeyboardScancode(code: 0x0058)
        default:
            nil
        }
    }

    static func modifierScancode(forKeyCode keyCode: UInt16) -> RDPKeyboardScancode? {
        switch keyCode {
        case 54:
            RDPKeyboardScancode(code: 0x005C, isExtended: true)
        case 55:
            RDPKeyboardScancode(code: 0x005B, isExtended: true)
        case 56:
            RDPKeyboardScancode(code: 0x002A)
        case 58:
            RDPKeyboardScancode(code: 0x0038)
        case 59:
            RDPKeyboardScancode(code: 0x001D)
        case 60:
            RDPKeyboardScancode(code: 0x0036)
        case 61:
            RDPKeyboardScancode(code: 0x0038, isExtended: true)
        case 62:
            RDPKeyboardScancode(code: 0x001D, isExtended: true)
        default:
            nil
        }
    }

    private static func alwaysSendsScancode(forKeyCode keyCode: UInt16) -> Bool {
        switch keyCode {
        case 36, 48, 51, 53,
             65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92,
             96 ... 101, 103, 109, 111,
             114 ... 117, 119, 121 ... 126:
            true
        default:
            false
        }
    }
}
