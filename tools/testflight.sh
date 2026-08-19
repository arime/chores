#!/bin/bash
#
# Archive Chores and upload it to TestFlight, without opening Xcode.
#
# This replaces Product → Archive → Distribute App → TestFlight. It does the same
# work through the same code paths: xcodebuild archives, then exportArchive
# re-signs the bundle with the Apple Distribution certificate and uploads it.
#
#   tools/testflight.sh                  # archive and upload
#   tools/testflight.sh --build 42       # use an explicit build number
#   tools/testflight.sh --archive-only   # stop before uploading
#   tools/testflight.sh --skip-db-check  # skip the hosted migration gate
#
# Internal testers get a build as soon as it finishes processing, and nothing
# below is needed for them. External testers — the ones who join by public link
# — need the build added to their group and put through Beta App Review:
#
#   tools/testflight.sh --external                    # upload, wait, then do both
#   tools/testflight.sh --external-only --build 42    # just those two, on an
#                                                     # already-uploaded build
#   tools/testflight.sh --external --whats-new 'Finnish translation'
#   tools/testflight.sh --external --external-group 'Public link'
#
# This does not shorten Beta App Review — it only removes the web interaction in
# front of it. The first build of a new MARKETING_VERSION is the slow one.
#
# What it deliberately does NOT do:
#
#   - Push migrations. A Release build always talks to hosted Supabase, so this
#     script *checks* that hosted is up to date and stops if it is not. Applying
#     them stays a deliberate act: `supabase db push`.
#   - Run the test suites. `swift test` and the UI suite are the gate described in
#     docs/RELEASING.md; run them before calling this.
#   - Verify Sign in with Apple. Nothing can — see docs/RELEASING.md. The device
#     checks listed there are the only coverage that path has.
#   - Create the external group, or fill in Test Information. Both are one-time
#     web tasks, and external distribution is impossible until they are done.
#   - Touch git. Nothing is committed, tagged, or pushed.
#
# Authentication: the Apple ID signed into Xcode is used by default. For a CI or
# headless run — or for anything with --external, which cannot use the Xcode
# Apple ID at all — export all three of these to use an App Store Connect API
# key instead:
#
#   ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8
#   ASC_KEY_ID=XXXXXXXXXX
#   ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT="App/Chores.xcodeproj"
readonly SCHEME="Chores"
readonly BUNDLE_ID="com.metsahalme.Chores"
readonly EXPORT_OPTIONS="App/ExportOptions.plist"
readonly ARCHIVE="build/Chores.xcarchive"
readonly LOG="build/testflight.log"

readonly DEFAULT_EXTERNAL_GROUP='External Testers'
# Processing usually takes a few minutes. Twenty is generous enough that hitting
# it means something is wrong rather than slow.
readonly PROCESSING_TIMEOUT=1200

build_number=""
skip_db_check=0
archive_only=0
external=0
external_only=0
external_group="${ASC_EXTERNAL_GROUP:-$DEFAULT_EXTERNAL_GROUP}"
whats_new=""

while [ $# -gt 0 ]; do
	case "$1" in
		--build) build_number="${2:-}"; shift 2 ;;
		--skip-db-check) skip_db_check=1; shift ;;
		--archive-only) archive_only=1; shift ;;
		--external) external=1; shift ;;
		--external-only) external=1; external_only=1; shift ;;
		--external-group) external_group="${2:-}"; shift 2 ;;
		--whats-new) whats_new="${2:-}"; shift 2 ;;
		-h|--help) sed -n '2,47p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

cd "$REPO_ROOT"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# External distribution
#
# Only reached with --external or --external-only. Everything it needs lives in
# tools/asc-api.sh; this is just the order the four calls go in.
# ---------------------------------------------------------------------------

distribute_externally() {
	local app_id build_id group_id

	step "Distributing build $build_number to '$external_group'"

	app_id="$(asc_app_id "$BUNDLE_ID")"
	# Resolved before the wait, so a mistyped group name fails now rather than
	# after twenty minutes of polling.
	group_id="$(asc_group_id "$app_id" "$external_group")"

	echo 'Waiting for App Store Connect to finish processing the build...'
	build_id="$(asc_wait_for_processing "$app_id" "$build_number" "$PROCESSING_TIMEOUT")"
	echo "Build $build_number is processed."

	asc_set_whats_new "$build_id" "$whats_new"
	asc_add_to_group "$build_id" "$group_id"
	echo "Added to '$external_group'."

	asc_submit_review "$build_id"
	echo 'Submitted for Beta App Review.'

	printf '\n\033[1m==> Build %s is with Beta App Review\033[0m\n' "$build_number"
	cat <<-EOF
	Testers on the public link get it once Apple approves, which is a queue: a
	day or so for the first build of a new version, usually quick after that.
	Watch TestFlight → iOS Builds, or the email.
	EOF
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

step 'Pre-flight'

# Flag combinations that cannot mean anything, caught before any work.
if [ "$external" -eq 1 ] && [ "$archive_only" -eq 1 ]; then
	fail '--archive-only stops before uploading, so there is nothing for --external to distribute.'
fi

if [ "$external" -eq 1 ]; then
	# Argument coherence before credentials: a missing --build is the more
	# likely mistake and the more actionable message, and checking the key
	# first would report a key problem to someone whose key is fine.
	if [ "$external_only" -eq 1 ] && [ -z "$build_number" ]; then
		fail '--external-only needs --build <number>, naming a build already uploaded. See build/uploads.log for what has been sent.'
	fi

	# shellcheck source=tools/asc-api.sh
	. "$REPO_ROOT/tools/asc-api.sh"
	asc_require_credentials
	command -v jq >/dev/null 2>&1 || fail 'external distribution needs jq on PATH.'
fi

# --external-only touches nothing local: no archive, no Secrets, no migration
# gate. The build it acts on was uploaded by an earlier run and its contents are
# already fixed.
if [ "$external_only" -eq 1 ]; then
	echo "Acting on build $build_number, already uploaded."
	distribute_externally
	exit 0
fi

[ -f App/Chores/Secrets.swift ] ||
	fail 'App/Chores/Secrets.swift is missing. Copy App/Chores/Secrets.swift.example and fill in the Hosted values.'

[ -f "$EXPORT_OPTIONS" ] || fail "$EXPORT_OPTIONS is missing."

# Resolved here rather than at upload time, so a mistake costs nothing instead of
# surfacing after a two-minute archive.
auth_args=()
auth_description='Authenticating as the Apple ID signed into Xcode.'
if [ -n "${ASC_KEY_PATH:-}" ] || [ -n "${ASC_KEY_ID:-}" ] || [ -n "${ASC_ISSUER_ID:-}" ]; then
	[ -n "${ASC_KEY_PATH:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] ||
		fail 'set all three of ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID, or none of them.'
	[ -f "$ASC_KEY_PATH" ] || fail "no App Store Connect API key at $ASC_KEY_PATH"
	auth_description='Authenticating with an App Store Connect API key.'
	auth_args=(
		-authenticationKeyPath "$ASC_KEY_PATH"
		-authenticationKeyID "$ASC_KEY_ID"
		-authenticationKeyIssuerID "$ASC_ISSUER_ID"
	)
fi

# A Release build reads the Hosted values, so an unpushed migration is a build
# that fails on a tester's first launch rather than on ours. Missing table grants
# are the version of this that looks like an outage.
if [ "$skip_db_check" -eq 0 ]; then
	if ! command -v supabase >/dev/null 2>&1; then
		fail 'the supabase CLI is not on PATH. Install it, or pass --skip-db-check.'
	fi
	echo 'Checking hosted migrations (dry run — nothing is applied)...'
	if ! supabase db push --dry-run --output-format json 2>/dev/null | grep -q '"upToDate":true'; then
		fail 'hosted Supabase has pending migrations. Run `supabase db push` first, then re-run this.'
	fi
	echo 'Hosted database is up to date.'
fi

# Recorded in the log so a build in TestFlight can be traced back to a commit.
commit="$(git rev-parse --short HEAD)"
if [ -n "$(git status --porcelain)" ]; then
	commit="$commit-dirty"
	echo "Working tree is dirty; this build is not reproducible from $commit."
fi

# A UTC timestamp is monotonic across daylight-saving changes, and needs no
# commit to the project file. App Store Connect rejects a build number it has
# already seen, and it is per-upload, not per-release.
[ -n "$build_number" ] || build_number="$(date -u '+%Y%m%d.%H%M')"

# Testers see this as What to Test. The commit subject is what actually changed,
# and the build number is what they can quote back when reporting something.
[ -n "$whats_new" ] || whats_new="$(git log -1 --pretty=%s) (build $build_number)"

echo "Scheme:       $SCHEME (Release)"
echo "Build number: $build_number"
echo "Commit:       $commit"
if [ "$external" -eq 1 ]; then
	echo "External:     '$external_group', then Beta App Review"
fi

mkdir -p build
rm -rf "$ARCHIVE"

# ---------------------------------------------------------------------------
# Archive
# ---------------------------------------------------------------------------

step "Archiving $BUNDLE_ID $build_number"

# CURRENT_PROJECT_VERSION is overridden rather than edited into the project file.
# GENERATE_INFOPLIST_FILE is YES and App/Info.plist declares no CFBundleVersion,
# so the override flows straight into the bundle and the repository stays clean.
xcodebuild \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration Release \
	-destination 'generic/platform=iOS' \
	-archivePath "$ARCHIVE" \
	-allowProvisioningUpdates \
	CURRENT_PROJECT_VERSION="$build_number" \
	archive 2>&1 | tee "$LOG"

# ---------------------------------------------------------------------------
# Verify the archive
#
# These are the checks a glance at Xcode's Organizer cannot make. The entitlement
# one matters most: without it Sign in with Apple fails at runtime with an error
# that names nothing, and no test in the suite reaches that path.
# ---------------------------------------------------------------------------

step 'Verifying the archive'

readonly APP="$ARCHIVE/Products/Applications/Chores.app"
[ -d "$APP" ] || fail "no app bundle at $APP"

archived_version="$(plutil -extract ApplicationProperties.CFBundleVersion raw -o - "$ARCHIVE/Info.plist")"
[ "$archived_version" = "$build_number" ] ||
	fail "archive is build $archived_version, expected $build_number"

archived_id="$(plutil -extract ApplicationProperties.CFBundleIdentifier raw -o - "$ARCHIVE/Info.plist")"
[ "$archived_id" = "$BUNDLE_ID" ] ||
	fail "archive is $archived_id, expected $BUNDLE_ID"

# A simulator build would carry no signature and an empty entitlements blob, and
# would be rejected on upload. LSRequiresIPhoneOS proves this is a device build.
plutil -extract LSRequiresIPhoneOS raw -o - "$APP/Info.plist" >/dev/null 2>&1 ||
	fail 'archive is not a device build'

if ! codesign -d --entitlements - --xml "$APP" 2>/dev/null |
	plutil -p - | grep -q 'com.apple.developer.applesignin'; then
	fail 'com.apple.developer.applesignin is missing from the signed entitlements. Check CODE_SIGN_ENTITLEMENTS and that the App ID has Sign in with Apple enabled.'
fi

[ -d "$ARCHIVE/dSYMs/Chores.app.dSYM" ] ||
	fail 'no dSYM in the archive; crash reports from testers would not symbolicate'

[ -f "$APP/PrivacyInfo.xcprivacy" ] ||
	fail 'PrivacyInfo.xcprivacy is not in the bundle'

echo 'Build number, bundle id, device build, Sign in with Apple entitlement, dSYM, privacy manifest: all present.'

if [ "$archive_only" -eq 1 ]; then
	step 'Done (--archive-only)'
	echo "Archive: $ARCHIVE"
	exit 0
fi

# ---------------------------------------------------------------------------
# Export and upload
# ---------------------------------------------------------------------------

step 'Exporting and uploading to App Store Connect'

echo "$auth_description"

# The archive is signed with a development identity, because that is what the
# Release configuration specifies. exportArchive re-signs with Apple Distribution
# and strips get-task-allow, which is the signature that reaches testers.
# -allowProvisioningUpdates lets it fetch the App Store provisioning profile.
#
# ExportOptions.plist sets destination=upload, so nothing is written to
# -exportPath on success and there is no .ipa to inspect afterwards. The upload
# is recorded in the archive's own Info.plist under Distributions.
xcodebuild -exportArchive \
	-archivePath "$ARCHIVE" \
	-exportOptionsPlist "$EXPORT_OPTIONS" \
	-exportPath build/export \
	-allowProvisioningUpdates \
	"${auth_args[@]+"${auth_args[@]}"}" 2>&1 | tee -a "$LOG"

printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$build_number" "$commit" >> build/uploads.log

step "Uploaded build $build_number"
cat <<EOF
Processing in App Store Connect takes a few minutes. The internal test group has
"Automatically distribute builds" enabled, so testers get it without any further
step; watch for the email, or check TestFlight → iOS Builds.

Build log:     $LOG
Upload record: build/uploads.log
EOF

if [ "$external" -eq 1 ]; then
	distribute_externally
fi
