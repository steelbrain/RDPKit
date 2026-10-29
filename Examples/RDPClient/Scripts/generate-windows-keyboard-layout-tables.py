#!/usr/bin/env python3
"""Regenerates Sources/WindowsKeyboardLayoutTables.swift from a capture made on Windows.

RDPClient sends a character key as its scancode only when the Windows layout it announced
types the same character, so it needs to know what each layout types. Windows answers that
itself, for every layout MacRDPKeyboardLayout can announce:

1. python3 generate-windows-keyboard-layout-tables.py request > capture-request.json
   lists those layouts (read from Sources/KeyboardLayouts.swift) and the scancodes.
2. On Windows 10 1607 or later, with capture-windows-keyboard-layouts.ps1 beside it:
   powershell -NoProfile -ExecutionPolicy Bypass -File capture-windows-keyboard-layouts.ps1 -RequestFile capture-request.json
   writes layouts.json next to the request.
3. python3 generate-windows-keyboard-layout-tables.py tables layouts.json
   rewrites Sources/WindowsKeyboardLayoutTables.swift.

Windows' Japanese layout is the exception. What it types follows the keyboard type and
subtype, which a capture takes from the capturing PC, while RDPClient announces a Japanese
keyboard; so its tables are written out below (JAPANESE), one per keyboard subtype.
"""

import json
import re
import sys
import unicodedata
from pathlib import Path

SOURCES = Path(__file__).resolve().parent.parent / "Sources"
MAPPING_SOURCE = SOURCES / "KeyboardLayouts.swift"
TABLES_SOURCE = SOURCES / "WindowsKeyboardLayoutTables.swift"

# The character keys MacRDPKeyboardMapping can send: the number, letter and punctuation rows,
# the ISO key (0x56) and the JIS keys (0x73, 0x7D). Space is the same on every layout.
SCANCODES = (
    list(range(0x02, 0x0E))
    + list(range(0x10, 0x1C))
    + list(range(0x1E, 0x2A))
    + list(range(0x2B, 0x36))
    + [0x56, 0x73, 0x7D]
)

JAPANESE_KLID = 0x0000_0411

# Windows' Japanese layout per keyboard subtype, which RDPClient announces with keyboard type 7:
# what each key in SCANCODES types without and with Shift ("\0" for nothing); Caps Lock shifts
# the letters only.
JAPANESE = {
    # A 101-key keyboard (kbd101.dll): every key types what US English types, the ISO key (0x56)
    # included, and the JIS keys type nothing. A capture in a Windows 11 session announced so
    # matched this key for key, Caps Lock too (live, 2026-10-29).
    0: (
        "101-key keyboard (kbd101.dll)",
        "1234567890-=qwertyuiop[]asdfghjkl;'`\\zxcvbnm,./\\\0\0",
        "!@#$%^&*()_+QWERTYUIOP{}ASDFGHJKL:\"~|ZXCVBNM<>?|\0\0",
    ),
    # A 106/109-key keyboard (kbd106.dll): every key types its JIS legend; Ro (0x73) and Yen
    # (0x7D) both type "\" (U+005C), which Japanese fonts draw as a yen sign. Shift-0 and
    # Hankaku/Zenkaku (0x29) type nothing, and 0x56, which these keyboards lack, is left as
    # typing nothing, so a Mac key sent as 0x56 goes as Unicode.
    2: (
        "106/109-key keyboard (kbd106.dll)",
        "1234567890-^qwertyuiop@[asdfghjkl;:\0]zxcvbnm,./\0\\\\",
        "!\"#$%&'()\0=~QWERTYUIOP`{ASDFGHJKL+*\0}ZXCVBNM<>?\0_|",
    ),
}


def input_sources_by_layout():
    """The Mac input sources that announce each KLID, from MacRDPKeyboardLayout.windowsLayouts."""
    text = MAPPING_SOURCE.read_text(encoding="utf-8")
    body = text[text.index("static let windowsLayouts") :]
    body = body[: body.index("\n    ]")]
    entries = re.findall(r'"([^"]+)": 0x([0-9A-F]{4})_([0-9A-F]{4}),', body)
    if not entries:
        raise SystemExit("no layouts found in %s" % MAPPING_SOURCE)
    names = {}
    for name, high, low in entries:
        names.setdefault(int(high + low, 16), []).append(name)
    # Written out, never captured.
    names.pop(JAPANESE_KLID, None)
    return names


def request():
    klids = sorted(input_sources_by_layout())
    json.dump({"klids": ["%08X" % klid for klid in klids], "scancodes": SCANCODES}, sys.stdout, indent=1)
    sys.stdout.write("\n")


def escape(scalar):
    """A Swift string literal for one character; NUL marks a key that does not type one."""
    if scalar is None:
        return "\\0"
    if scalar in "\\\"":
        return "\\" + scalar
    code = ord(scalar)
    # Controls, combining marks, invisible characters and right-to-left letters are escaped,
    # so the source reads left to right and every character is visible.
    if (
        code < 0x20
        or 0x7F <= code < 0xA0
        or unicodedata.category(scalar)[0] in "MCZ"
        or unicodedata.bidirectional(scalar)
        in ("R", "AL", "AN", "NSM", "RLE", "RLO", "LRE", "LRO", "PDF", "RLI", "LRI", "FSI", "PDI")
    ):
        return "\\u{%X}" % code
    return scalar


def cell(key, mode):
    """What the key types in one shift state, or None for a dead key, or a key that types
    nothing or more than one character: those go as Unicode."""
    kind, text = key["cells"][mode]
    if kind != "text" or len(text) != 1:
        return None
    return text


def caps_lock_flag(key):
    plain, shifted, caps, caps_shifted = (tuple(cell) for cell in key["cells"])
    if caps == plain and caps_shifted == shifted:
        return "-"
    if caps == shifted and caps_shifted == plain:
        return "S"
    return "?"


def tables(capture_path):
    captured = json.loads(Path(capture_path).read_text(encoding="utf-8-sig"))
    names = input_sources_by_layout()
    missing = [klid for klid in names if not isinstance(captured.get("%08X" % klid), dict)]
    if missing:
        raise SystemExit(
            "no capture for %s; Windows has no such layout, so map those input sources to another"
            % ", ".join("%08X (%s)" % (klid, ", ".join(names[klid])) for klid in sorted(missing))
        )

    entries = []
    for klid, sources in names.items():
        keys = captured["%08X" % klid]["keys"]
        ordered = [keys[str(sc)] for sc in SCANCODES]
        entries.append((
            klid,
            ", ".join(sorted(sources)),
            [cell(key, 0) for key in ordered],
            [cell(key, 1) for key in ordered],
            "".join(caps_lock_flag(key) for key in ordered),
        ))
    japanese = []
    for sub_type, (comment, unshifted, shifted) in JAPANESE.items():
        japanese.append((
            sub_type,
            comment + ": written out, not captured",
            [None if c == "\0" else c for c in unshifted],
            [None if c == "\0" else c for c in shifted],
            "".join("S" if c.isalpha() else "-" for c in unshifted),
        ))

    lines = [
        "// Generated by Scripts/generate-windows-keyboard-layout-tables.py from what",
        "// Scripts/capture-windows-keyboard-layouts.ps1 read on Windows 11: for every layout",
        "// MacRDPKeyboardLayout announces, each scancode below mapped with MapVirtualKeyEx and",
        "// typed with ToUnicodeEx (keyboard state left unchanged), without and with Shift and",
        "// Caps Lock. Japanese, announced with a Japanese keyboard, is written out in the",
        "// generator instead.",
        "",
        "extension MacRDPWindowsKeyboardLayout {",
        "    /// The character keys, in the order of each layout's strings.",
        "    static let scancodes: [UInt16] = [",
    ]
    for start in range(0, len(SCANCODES), 12):
        lines.append("        " + ", ".join("0x%02X" % sc for sc in SCANCODES[start : start + 12]) + ",")
    lines += [
        "    ]",
        "",
        "    /// Per layout: what each key types without Shift and with it (NUL for a dead key, or a",
        "    /// key that types nothing or more than one character), and what Caps Lock does to it:",
        '    /// "S" acts as Shift, "-" nothing, "?" something else.',
        "    static let layouts: [UInt32: (unshifted: String, shifted: String, capsLock: String)] = [",
    ]
    def table(key, comment, unshifted, shifted, caps_lock):
        return [
            "        // " + comment,
            "        %s: (" % key,
            '            "%s",' % "".join(escape(scalar) for scalar in unshifted),
            '            "%s",' % "".join(escape(scalar) for scalar in shifted),
            '            "%s"' % caps_lock,
            "        ),",
        ]

    for klid, *strings in sorted(entries, key=lambda entry: entry[0]):
        lines += table("0x%04X_%04X" % (klid >> 16, klid & 0xFFFF), *strings)
    lines += [
        "    ]",
        "",
        "    /// Windows' Japanese layout (0x%04X_%04X) per keyboard subtype, announced with keyboard"
        % (JAPANESE_KLID >> 16, JAPANESE_KLID & 0xFFFF),
        "    /// type 7 (see MacRDPWindowsKeyboard), in the same form.",
        "    static let japaneseLayouts: [UInt32: (unshifted: String, shifted: String, capsLock: String)] = [",
    ]
    for sub_type, *strings in sorted(japanese, key=lambda entry: entry[0]):
        lines += table(str(sub_type), *strings)
    lines += ["    ]", "}"]
    TABLES_SOURCE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("wrote %d layouts to %s" % (len(entries) + len(japanese), TABLES_SOURCE), file=sys.stderr)


def main():
    if sys.argv[1:] == ["request"]:
        request()
    elif len(sys.argv) == 3 and sys.argv[1] == "tables":
        tables(sys.argv[2])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
