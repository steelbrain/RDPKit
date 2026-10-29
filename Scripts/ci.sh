#!/bin/sh
# The checks .github/workflows/ci.yml runs; each CI step calls this script.
#
#   Scripts/ci.sh                    every check, in CI's order
#   Scripts/ci.sh lint | test | example-tests | example-builds
#   Scripts/ci.sh platform <name>    build RDPKit for iOS, tvOS, Mac Catalyst or visionOS
#
# Every check uses the Xcode CI uses, the macos-26 runner's default: a newer
# Swift accepts code that it rejects, such as a Data.withUnsafeBytes closure
# whose parameter type is left to inference.
set -eu

xcode_version=26.6

cd "$(dirname "$0")/.."

# The runner image names it Xcode_26.6.app, the xcodes tool Xcode-26.6.app.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    for app in "/Applications/Xcode_$xcode_version.app" "/Applications/Xcode-$xcode_version.app"; do
        if [ -d "$app" ]; then
            export DEVELOPER_DIR="$app/Contents/Developer"
            break
        fi
    done
fi
selected_version=$(xcodebuild -version | sed -n 's/^Xcode //p')
if [ "$selected_version" != "$xcode_version" ]; then
    echo "error: CI uses Xcode $xcode_version, but the selected Xcode is $selected_version." >&2
    echo "Install Xcode $xcode_version in /Applications or point DEVELOPER_DIR at it." >&2
    exit 1
fi

# Build folders of their own keep the default Xcode's .build from being rebuilt.
scratch=".build/xcode-$xcode_version"
examples_scratch="Examples/.build/xcode-$xcode_version"

usage() {
    echo "usage: $0 [lint | test | example-tests | example-builds | platform <name>]" >&2
    exit 64
}

platform() {
    case "$1" in
        iOS) destination='generic/platform=iOS' ;;
        tvOS) destination='generic/platform=tvOS' ;;
        'Mac Catalyst') destination='generic/platform=macOS,variant=Mac Catalyst' ;;
        visionOS) destination='generic/platform=visionOS' ;;
        *) usage ;;
    esac
    xcodebuild -quiet -scheme RDPKit -destination "$destination" CODE_SIGNING_ALLOWED=NO build
}

check() {
    case "$1" in
        lint)
            swiftlint lint --strict
            ;;
        test)
            swift test --no-parallel --scratch-path "$scratch"
            ;;
        example-tests)
            swift test --package-path Examples --scratch-path "$examples_scratch"
            ;;
        example-builds)
            for product in RDPClient RDPFirstFrameCapture RDPPreflight RDPFrameBenchmark; do
                swift build --package-path Examples --scratch-path "$examples_scratch" --product "$product"
            done
            ;;
        platform)
            [ $# -eq 2 ] || usage
            platform "$2"
            ;;
        *)
            usage
            ;;
    esac
}

if [ $# -eq 0 ]; then
    for name in lint test example-tests example-builds; do
        check "$name"
    done
    for name in iOS tvOS 'Mac Catalyst' visionOS; do
        platform "$name"
    done
else
    check "$@"
fi
