#!/bin/bash
#
# Capture the App Store screenshots, in every language the listing has.
#
#   tools/screenshots.sh                        # both languages
#   tools/screenshots.sh --language fi          # just one
#   tools/screenshots.sh --device 'iPhone 16 Pro Max'
#
# Screenshots are a required part of an App Store listing and the one part that
# goes stale invisibly: nothing warns you that the pictures are of a version from
# four releases ago. So they are generated rather than taken by hand, from the
# same fixture every time, and re-running this is the whole cost of refreshing
# them.
#
# How it works: ChoresUITests/ScreenshotTests drives the app to five screens and
# attaches a PNG of each, XCTest puts them in a result bundle, and this pulls
# them out and gives them their names back. The app is launched with
# -screenshots-parent or -screenshots-kid, which seeds a family with a full week
# of chores and a history of ticking them off — see AppEnvironment.
#
# Output: build/screenshots/<App Store locale>/NN-name.png, which is exactly what
# tools/appstore.sh uploads.
#
# The size matters and is checked: the App Store's iPhone requirement is the 6.9"
# display, and 1320x2868 is what that means in pixels. A different simulator can
# be passed with --device, but if it is not a 6.9" phone the check will say so.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT='App/Chores.xcodeproj'
readonly SCHEME='Chores'
readonly TESTS='ChoresUITests/ScreenshotTests'
readonly OUT='build/screenshots'
readonly LOG='build/screenshots.log'

readonly DEFAULT_DEVICE='iPhone 17 Pro Max'
# Portrait, in pixels. Apple accepts either of these for the 6.9" slot.
readonly ACCEPTED_SIZES='1320x2868 1290x2796'

# Each entry is: <App Store locale> <AppleLanguages code> <AppleLocale>
readonly LANGUAGES=(
	'en-US en en_US'
	'fi fi fi_FI'
)

device="$DEFAULT_DEVICE"
only_language=''

while [ $# -gt 0 ]; do
	case "$1" in
		--device) device="${2:-}"; shift 2 ;;
		--language) only_language="${2:-}"; shift 2 ;;
		-h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

cd "$REPO_ROOT"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail 'this needs jq on PATH.'

# ---------------------------------------------------------------------------
# The simulator
#
# Resolved to a udid rather than passed to xcodebuild by name, because the status
# bar override below needs a specific device — and a screenshot with a real
# clock, a half-empty battery and one bar of signal in it looks like an accident.
# ---------------------------------------------------------------------------

step "Preparing the simulator ($device)"

udid="$(xcrun simctl list devices available -j |
	jq -r --arg name "$device" '[.devices[][] | select(.name == $name)][0].udid // empty')"

if [ -z "$udid" ]; then
	echo "No simulator named '$device' exists yet; creating one."
	device_type="$(xcrun simctl list devicetypes -j |
		jq -r --arg name "$device" '[.devicetypes[] | select(.name == $name)][0].identifier // empty')"
	[ -n "$device_type" ] ||
		fail "Xcode has no device type called '$device'. \`xcrun simctl list devicetypes\` lists them."

	runtime="$(xcrun simctl list runtimes -j |
		jq -r '[.runtimes[] | select(.platform == "iOS" and .isAvailable)] | last | .identifier // empty')"
	[ -n "$runtime" ] || fail 'no available iOS simulator runtime. Install one in Xcode → Settings → Components.'

	udid="$(xcrun simctl create "$device" "$device_type" "$runtime")"
fi

xcrun simctl boot "$udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$udid" -b >/dev/null

xcrun simctl status_bar "$udid" override \
	--time '9:41' \
	--batteryState charged --batteryLevel 100 \
	--cellularMode active --cellularBars 4 \
	--wifiMode active --wifiBars 3

echo "Simulator $udid is booted, with a fixed status bar."

mkdir -p build
: > "$LOG"

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

captured_locales=()

for entry in "${LANGUAGES[@]}"; do
	read -r asc_locale language locale <<< "$entry"

	if [ -n "$only_language" ] &&
		[ "$only_language" != "$language" ] && [ "$only_language" != "$asc_locale" ]; then
		continue
	fi

	step "Capturing $asc_locale"

	result="$OUT/$asc_locale.xcresult"
	destination="$OUT/$asc_locale"
	rm -rf "$result" "$destination"
	mkdir -p "$destination"

	# xcodebuild forwards any TEST_RUNNER_-prefixed variable to the test runner
	# process with the prefix stripped. That is the only channel into a test
	# process that runs on a different machine than the one invoking it, as far
	# as xcodebuild is concerned.
	TEST_RUNNER_SCREENSHOTS=1 \
	TEST_RUNNER_SCREENSHOT_LANGUAGE="$language" \
	TEST_RUNNER_SCREENSHOT_LOCALE="$locale" \
	xcodebuild test \
		-project "$PROJECT" \
		-scheme "$SCHEME" \
		-destination "id=$udid" \
		-only-testing:"$TESTS" \
		-resultBundlePath "$result" 2>&1 | tee -a "$LOG" | grep -E '^(Test Suite|Test Case|\*\*)' || true

	# The result bundle names attachments after their payload hash; the name the
	# test gave each one survives in the manifest, and is what the App Store
	# ordering depends on.
	raw="$result-attachments"
	rm -rf "$raw"
	xcrun xcresulttool export attachments --path "$result" --output-path "$raw" >/dev/null

	[ -f "$raw/manifest.json" ] || fail "no attachments were exported from $result"

	count=0
	while IFS=$'\t' read -r exported name; do
		[ -n "$exported" ] || continue
		# XCTest makes each attachment name unique in the bundle by appending a
		# repetition index and a UUID. Neither belongs in a filename anyone has
		# to look at, and the prefix that decides the App Store ordering is in
		# front of it either way.
		name="$(printf '%s' "$name" | sed -E 's/_[0-9]+_[0-9A-Fa-f-]{36}\.png$/.png/')"
		mv "$raw/$exported" "$destination/$name"
		count=$((count + 1))
	done < <(jq -r '
		.[].attachments
		| (if type == "array" then .[] else . end)
		| select((.suggestedHumanReadableName // "") | endswith(".png"))
		| [.exportedFileName, .suggestedHumanReadableName]
		| @tsv' "$raw/manifest.json" | sort -t$'\t' -k2)

	rm -rf "$raw"
	[ "$count" -gt 0 ] || fail "the capture run produced no PNGs. See $LOG."

	echo "$count screenshots in $destination"
	captured_locales+=("$asc_locale")
done

[ ${#captured_locales[@]} -gt 0 ] ||
	fail "no language matched --language '$only_language'. Known: en-US, fi."

# ---------------------------------------------------------------------------
# Verify
#
# A wrong-sized screenshot is rejected on upload, several minutes later, with a
# message about a display type rather than about the simulator that produced it.
# ---------------------------------------------------------------------------

step 'Verifying'

for asc_locale in "${captured_locales[@]}"; do
	for shot in "$OUT/$asc_locale"/*.png; do
		size="$(sips -g pixelWidth -g pixelHeight "$shot" |
			awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}')"
		case " $ACCEPTED_SIZES " in
			*" $size "*) ;;
			*) fail "$(basename "$shot") is ${size}, which the App Store's 6.9\" iPhone slot will not take (it wants one of: $ACCEPTED_SIZES). '$device' is the wrong simulator for this." ;;
		esac
	done
	echo "$asc_locale: $(find "$OUT/$asc_locale" -name '*.png' | wc -l | tr -d ' ') screenshots, all sized correctly"
done

step 'Done'
cat <<EOF
Screenshots: $OUT/
Log:         $LOG

Look at them before uploading — this checks that they are the right size and
that the app got to the right screen, not that they are any good. Then:

    tools/appstore.sh --screenshots
EOF
