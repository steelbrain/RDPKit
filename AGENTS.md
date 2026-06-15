# Agent Instructions

These conventions are mandatory for this repository.

## Project Context

RDPKit is a Pure Swift RDP library for Apple platforms. The reusable package
lives at the repository root, and example shells live under `Examples/`.

Use this boundary when making changes:

- Code needed by macOS, iOS, tvOS, Mac Catalyst, visionOS, and third-party
  clients belongs in `Sources/RDPKit`.
- macOS-only UI, Keychain wiring, AppKit windowing, and app preferences belong in
  `Examples/RDPClient`.
- Command-line probes and demos belong in `Examples/RDPPreflight` or
  `Examples/RDPFirstFrameCapture`.

The library should prefer Apple primitives and Apple-maintained Swift packages:
VideoToolbox, CoreMedia, CoreVideo, AVFoundation, Security, SwiftNIO, and
SwiftNIO SSL. Do not add FreeRDP or another native RDP stack as a dependency.

Windows RDP and KDE KRdp compatibility remain primary validation targets. Treat
RDPGFX, AVC420/H.264, AVC444/H.264, HEVC/H.265, frame acknowledgements, display
resize, keyboard, pointer, clipboard, and audio as first-class library concerns.

## Cursor Behavior

- Do not hide the host macOS cursor when it enters the remote control or viewer
  area.
- If remote cursor support is needed, render or synchronize the remote cursor
  without suppressing the host cursor unless the user explicitly requests cursor
  hiding.

## Validation

- Gather context before implementing: read relevant code, callers, tests, and
  examples before editing.
- Confirm public API names and signatures from current source before documenting
  them.
- Use existing patterns before introducing new abstractions.
- Keep changes small enough to review in isolation.
- Review your own diff before committing.
- Do not use subagents unless the user explicitly asks for them.

Suggested checks:

- Library behavior: `swift test`
- Swift style gate: `swiftlint lint --strict`
- Example app and tool builds:
  `swift build --package-path Examples --product RDPClient`
  `swift build --package-path Examples --product RDPPreflight`
  `swift build --package-path Examples --product RDPFirstFrameCapture`

For documentation-only changes, a full build is optional, but check links,
commands, and references to removed files.

## Documentation

- Keep `README.md` package-focused. It should explain what RDPKit is, how to
  install it, how to use it, what codecs/features are supported, and how to run
  the examples.
- Keep claims precise. RDPKit is Pure Swift and has no FreeRDP/native RDP stack,
  but it intentionally depends on Apple-maintained SwiftNIO and SwiftNIO SSL for
  networking and TLS.
- Do not reintroduce planning docs or wishlist files unless the user asks for
  them.

## Git Conventions

### Branch Naming

- All new branches MUST be prefixed with `steelbrain/`.
- Format: `steelbrain/<descriptive-kebab-case-name>`.
- Examples: `steelbrain/fix-login-redirect`, `steelbrain/add-campaign-filters`.

### Commit Messages

- MUST use present tense, imperative mood.
- First line MUST be 72 characters or fewer.
- Reference issues or PRs after the first line when useful.
- Documentation-only changes MUST include `[ci skip]` in the title.
- NEVER write vague messages like "Fix bug", "Update code", or "Minor changes."
- When opening a pull request, omit the emoji prefix from the PR title.

### Emoji Prefixes

Use these exact text prefixes when applicable:

| Prefix | When to use |
| --- | --- |
| `:new:` | Adding new functionality |
| `:bug:` | Fixing a bug |
| `:art:` | Improving format or structure |
| `:racehorse:` | Improving performance |
| `:fire:` | Removing code or files |
| `:memo:` | Writing docs |
| `:white_check_mark:` | Adding tests |
| `:arrow_up:` | Upgrading dependencies |
| `:arrow_down:` | Downgrading dependencies |
| `:lock:` | Security |
| `:green_heart:` | Fixing CI |
| `:shirt:` | Removing linter warnings |
| `:non-potable_water:` | Plugging memory leaks |

If none of these fit, omit the prefix. NEVER force-fit one.

Examples:

```text
:bug: Fix login redirect losing query params
:arrow_up: Upgrade lodash to 4.18.1
:new: Add campaign scheduling API
:memo: Document campaign scheduling API [ci skip]
```
