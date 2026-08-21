#!/bin/bash
#
# Push the App Store listing and submit it for review, without opening App Store
# Connect.
#
#   tools/appstore.sh --status              # what App Store Connect has now
#   tools/appstore.sh                       # push metadata and screenshots,
#                                           # attach the build, stop there
#   tools/appstore.sh --submit              # the same, then submit for review
#   tools/appstore.sh --metadata-only
#   tools/appstore.sh --screenshots-only
#   tools/appstore.sh --build 20260819.1411 # a specific build, not the newest
#   tools/appstore.sh --age-rating          # apply docs/appstore/age-rating.json
#
# The listing lives in docs/appstore/ — one directory per App Store locale, one
# file per field — and the screenshots in build/screenshots/, where
# tools/screenshots.sh puts them. Both are read, never written: this script's
# only direction is from the repository to Apple, so the reviewable copy of the
# listing is the one in git.
#
# Submitting is behind its own flag because it is the one step with a queue on
# the other side of it. Everything before it can be re-run freely.
#
# What it deliberately does NOT do:
#
#   - Set the app's name. That name was reserved by hand and is unique across the
#     store; a script overwriting it is a rename nobody asked for. It is
#     reported by --status instead.
#   - Answer the App Privacy questionnaire. Apple has no public API for it. It is
#     a one-time web task, and docs/RELEASING.md says exactly what to answer so
#     that it agrees with App/Chores/PrivacyInfo.xcprivacy.
#   - Upload a build. That is tools/testflight.sh; the same binary serves
#     TestFlight and the store.
#   - Answer the age rating questionnaire unless asked. --age-rating does it, and
#     it is a once-per-app job.
#   - Touch git.
#
# Authentication needs an App Store Connect API key with the App Manager or
# Admin role — there is no way to mint a token from the Apple ID in Xcode:
#
#   ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8
#   ASC_KEY_ID=XXXXXXXXXX
#   ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

set -euo pipefail

# So `wc -m` counts characters rather than bytes. Every App Store limit is in
# characters, and "Sängyn petaus" is not the length its bytes suggest.
export LC_CTYPE=UTF-8

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_FILE='App/Chores.xcodeproj/project.pbxproj'
readonly BUNDLE_ID='com.metsahalme.Chores'
readonly METADATA='docs/appstore'
readonly SHOTS='build/screenshots'

# App Store locales, which are also the directory names under docs/appstore/.
readonly LOCALES=('en-US' 'fi')

# Apple's limits, in characters. Exceeding one is a 400 with a field name in it;
# checking here says which file instead.
readonly LIMIT_SUBTITLE=30
readonly LIMIT_KEYWORDS=100
readonly LIMIT_PROMOTIONAL=170
readonly LIMIT_DESCRIPTION=4000
readonly LIMIT_WHATS_NEW=4000
readonly LIMIT_NOTES=4000

# Versions in these states accept metadata edits. Anything else is either with
# Apple or already on the store, and needs a new version number instead.
readonly EDITABLE_STATES='PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED INVALID_BINARY'

build_number=''
do_metadata=1
do_screenshots=1
do_build=1
do_submit=0
do_age_rating=0
status_only=0

while [ $# -gt 0 ]; do
	case "$1" in
		--status) status_only=1; shift ;;
		--submit) do_submit=1; shift ;;
		--metadata-only) do_screenshots=0; do_build=0; shift ;;
		--screenshots-only) do_metadata=0; do_build=0; shift ;;
		--age-rating) do_age_rating=1; do_metadata=0; do_screenshots=0; do_build=0; shift ;;
		--build) build_number="${2:-}"; shift 2 ;;
		-h|--help) sed -n '2,43p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

cd "$REPO_ROOT"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# shellcheck source=tools/asc-api.sh
. "$REPO_ROOT/tools/asc-api.sh"

command -v jq >/dev/null 2>&1 || fail 'this needs jq on PATH.'

# ---------------------------------------------------------------------------
# Reading the listing out of the repository
# ---------------------------------------------------------------------------

# Trailing newlines are stripped: every editor adds one, App Store Connect keeps
# it, and it counts against the limit.
field() {
	[ -f "$1" ] || fail "missing $1"
	printf '%s' "$(cat "$1")"
}

check_length() {
	local length
	length="$(field "$1" | wc -m | tr -d ' ')"
	[ "$length" -le "$2" ] ||
		fail "$1 is $length characters; the App Store allows $2."
}

marketing_version() {
	local version
	version="$(grep -m1 'MARKETING_VERSION' "$PROJECT_FILE" | sed 's/.*= *//; s/;.*//')"
	[ -n "$version" ] || fail "could not read MARKETING_VERSION from $PROJECT_FILE"
	printf '%s' "$version"
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

step 'Pre-flight'

[ -f "$METADATA/listing.json" ] || fail "missing $METADATA/listing.json"
jq empty "$METADATA/listing.json" 2>/dev/null || fail "$METADATA/listing.json is not valid JSON"

# Everything from here to the credentials check is about what would be *sent*, so
# --status skips it: reading the state back has to work while the listing is
# still being written, and that is exactly when it is most wanted.
if [ "$status_only" -eq 1 ]; then
	echo 'Reporting only; the listing itself is not checked.'
fi

# The two placeholders that are deliberately unfilled in the repository. Sending
# either to Apple would put "SUPPORT_EMAIL_TODO" on the store.
if [ "$status_only" -eq 0 ] && grep -rl '_TODO' "$METADATA" >/dev/null 2>&1; then
	printf '\033[31merror:\033[0m the listing still has placeholders in it:\n' >&2
	grep -rn '_TODO' "$METADATA" >&2
	cat >&2 <<-'EOF'

	Fill them in first. The same placeholder is in docs/site/, and the Pages
	workflow refuses to publish while it is there.
	EOF
	exit 1
fi

if [ "$status_only" -eq 0 ]; then
	for locale in "${LOCALES[@]}"; do
		[ -d "$METADATA/$locale" ] || fail "missing $METADATA/$locale"
		check_length "$METADATA/$locale/subtitle.txt" "$LIMIT_SUBTITLE"
		check_length "$METADATA/$locale/keywords.txt" "$LIMIT_KEYWORDS"
		check_length "$METADATA/$locale/promotional-text.txt" "$LIMIT_PROMOTIONAL"
		check_length "$METADATA/$locale/description.txt" "$LIMIT_DESCRIPTION"
		check_length "$METADATA/$locale/whats-new.txt" "$LIMIT_WHATS_NEW"
	done
	check_length "$METADATA/review-notes.txt" "$LIMIT_NOTES"
	echo "Listing files are present and within Apple's length limits."
fi

# App Review opens the privacy policy and support URLs, and an unreachable one
# is a rejection that says nothing about GitHub Pages. Checked here because the
# usual cause is Pages never having been switched on.
if [ "$status_only" -eq 0 ] && [ "$do_metadata" -eq 1 ]; then
	for locale in "${LOCALES[@]}"; do
		for page in privacy support; do
			url="$(field "$METADATA/$locale/$page-url.txt")"
			curl -sfI --max-time 20 "$url" >/dev/null ||
				fail "$url is not reachable. App Review opens it. If the site has never been published, enable GitHub Pages (Settings → Pages → Source: GitHub Actions) and let .github/workflows/pages.yml run."
		done
	done
	echo 'Privacy policy and support pages are reachable.'
fi

# Credentials last of the pre-flight checks: a mistake in the listing is far
# more likely than a mistake in the key, and it costs nothing to report without
# one.
asc_require_credentials

version_string="$(marketing_version)"
app_id="$(asc_app_id "$BUNDLE_ID")"
app_name="$(asc_app_name "$app_id")"

# --status reports; it does not create the version it is reporting on.
if [ "$status_only" -eq 1 ]; then
	version_row="$(asc_find_version "$app_id" "$version_string")"
else
	version_row="$(asc_version "$app_id" "$version_string")"
fi
version_id="$(printf '%s' "$version_row" | cut -f1)"
version_state="$(printf '%s' "$version_row" | cut -f2)"

echo "App:      $app_name ($BUNDLE_ID)"
echo "Version:  $version_string — ${version_state:-not created in App Store Connect yet}"

# ---------------------------------------------------------------------------
# --status
# ---------------------------------------------------------------------------

if [ "$status_only" -eq 1 ]; then
	step 'What App Store Connect has'

	latest="$(asc_latest_build "$app_id" || true)"
	if [ -n "$latest" ]; then
		echo "Newest build uploaded: $(printf '%s' "$latest" | cut -f2)"
	else
		echo 'Newest build uploaded: none'
	fi

	if [ -z "$version_id" ]; then
		echo "Nothing else to report: version $version_string does not exist yet."
		echo 'Running tools/appstore.sh with no flags creates it.'
		exit 0
	fi

	echo "Build attached:        $(asc_attached_build "$version_id" || true)"

	display_type="$(jq -r '.screenshotDisplayType' "$METADATA/listing.json")"
	for locale in "${LOCALES[@]}"; do
		localization_id="$(asc_find_version_localization "$version_id" "$locale")"
		if [ -z "$localization_id" ]; then
			printf '%-6s  not created yet\n' "$locale"
			continue
		fi

		set_id="$(asc_find_screenshot_set "$localization_id" "$display_type")"
		shots=0
		if [ -n "$set_id" ]; then
			shots="$(asc_request GET "/appScreenshotSets/$set_id/appScreenshots?limit=200" |
				jq -r '.data | length')"
		fi
		described="$(asc_request GET "/appStoreVersionLocalizations/$localization_id" |
			jq -r 'if (.data.attributes.description // "") == "" then "no" else "yes" end')"
		printf '%-6s  description: %-3s  screenshots: %s\n' "$locale" "$described" "$shots"
	done

	submission="$(asc_find_review_submission "$app_id" || true)"
	if [ -n "$submission" ]; then
		echo "Review submission: $(printf '%s' "$submission" | cut -f2)"
	else
		echo 'Review submission: none open'
	fi
	exit 0
fi

case " $EDITABLE_STATES " in
	*" $version_state "*) ;;
	*) fail "version $version_string is $version_state, which does not take edits. Bump MARKETING_VERSION in the project for a new version, or wait for this one to come back from review." ;;
esac

# ---------------------------------------------------------------------------
# Age rating
#
# Once per app, and separate from everything else because Apple's questionnaire
# has been revised more than once: if a field name has changed, the error names
# it and only this flag is affected.
# ---------------------------------------------------------------------------

if [ "$do_age_rating" -eq 1 ]; then
	step 'Age rating'
	asc_set_age_rating "$(asc_app_info_id "$app_id")" "$(jq -c . "$METADATA/age-rating.json")"
	echo 'Applied docs/appstore/age-rating.json. Nothing in it declares any mature content, so this app rates 4+.'
	exit 0
fi

# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------

if [ "$do_metadata" -eq 1 ]; then
	step "Pushing metadata for $version_string"

	asc_patch_version "$version_id" "$(jq -c '{copyright, releaseType}' "$METADATA/listing.json")"
	echo 'Copyright and release type set.'

	asc_set_content_rights "$app_id" "$(jq -r '.contentRights' "$METADATA/listing.json")"
	echo 'Content rights declared.'

	app_info_id="$(asc_app_info_id "$app_id")"
	asc_set_categories "$app_info_id" \
		"$(jq -r '.primaryCategory // ""' "$METADATA/listing.json")" \
		"$(jq -r '.secondaryCategory // ""' "$METADATA/listing.json")"
	echo 'Categories set.'

	# What's New has nothing to be new since on a first release, and App Store
	# Connect refuses it there.
	send_whats_new=1
	if [ "$(asc_version_count "$app_id")" -le 1 ]; then
		send_whats_new=0
		echo "This is the app's first version, so What's New is not sent."
	fi

	for locale in "${LOCALES[@]}"; do
		info_localization_id="$(asc_app_info_localization "$app_info_id" "$locale" "$app_name")"
		asc_patch_app_info_localization "$info_localization_id" "$(jq -nc \
			--arg subtitle "$(field "$METADATA/$locale/subtitle.txt")" \
			--arg privacy "$(field "$METADATA/$locale/privacy-url.txt")" \
			'{subtitle: $subtitle, privacyPolicyUrl: $privacy}')"

		localization_id="$(asc_version_localization "$version_id" "$locale")"
		attributes="$(jq -nc \
			--arg description "$(field "$METADATA/$locale/description.txt")" \
			--arg keywords "$(field "$METADATA/$locale/keywords.txt")" \
			--arg promotional "$(field "$METADATA/$locale/promotional-text.txt")" \
			--arg support "$(field "$METADATA/$locale/support-url.txt")" \
			--arg marketing "$(field "$METADATA/$locale/marketing-url.txt")" \
			'{description: $description, keywords: $keywords,
			  promotionalText: $promotional, supportUrl: $support,
			  marketingUrl: $marketing}')"
		if [ "$send_whats_new" -eq 1 ]; then
			attributes="$(printf '%s' "$attributes" | jq -c \
				--arg whatsNew "$(field "$METADATA/$locale/whats-new.txt")" \
				'. + {whatsNew: $whatsNew}')"
		fi
		asc_patch_version_localization "$localization_id" "$attributes"

		echo "$locale: subtitle, description, keywords, promotional text and URLs set."
	done

	asc_set_review_detail "$version_id" "$(jq -c \
		--arg notes "$(field "$METADATA/review-notes.txt")" \
		'{contactFirstName: .review.firstName, contactLastName: .review.lastName,
		  contactPhone: .review.phone, contactEmail: .review.email,
		  demoAccountRequired: .review.demoAccountRequired, notes: $notes}' \
		"$METADATA/listing.json")"
	echo 'App Review contact details and notes set.'
fi

# ---------------------------------------------------------------------------
# Screenshots
# ---------------------------------------------------------------------------

if [ "$do_screenshots" -eq 1 ]; then
	step 'Uploading screenshots'

	display_type="$(jq -r '.screenshotDisplayType' "$METADATA/listing.json")"

	for locale in "${LOCALES[@]}"; do
		directory="$SHOTS/$locale"
		[ -d "$directory" ] ||
			fail "no screenshots in $directory. Run tools/screenshots.sh first."

		shots=()
		while IFS= read -r shot; do
			shots+=("$shot")
		done < <(find "$directory" -name '*.png' | sort)

		[ ${#shots[@]} -gt 0 ] ||
			fail "no PNGs in $directory. Run tools/screenshots.sh first."

		localization_id="$(asc_version_localization "$version_id" "$locale")"
		set_id="$(asc_screenshot_set "$localization_id" "$display_type")"

		# Replaced rather than added to, so the store shows what is in build/ and
		# in that order.
		asc_clear_screenshot_set "$set_id"
		for shot in "${shots[@]}"; do
			asc_upload_screenshot "$set_id" "$shot"
			printf '  %s\n' "$(basename "$shot")"
		done
		echo "$locale: ${#shots[@]} screenshots uploaded to $display_type."
	done
fi

# ---------------------------------------------------------------------------
# The build
# ---------------------------------------------------------------------------

if [ "$do_build" -eq 1 ]; then
	step 'Attaching the build'

	if [ -n "$build_number" ]; then
		build_id="$(asc_build_id "$app_id" "$build_number")"
		[ -n "$build_id" ] ||
			fail "App Store Connect has no build $build_number for $BUNDLE_ID. See build/uploads.log for what has been sent, and remember processing takes a few minutes."
	else
		latest="$(asc_latest_build "$app_id")"
		[ -n "$latest" ] ||
			fail "this app has no builds. Upload one with tools/testflight.sh first."
		build_id="$(printf '%s' "$latest" | cut -f1)"
		build_number="$(printf '%s' "$latest" | cut -f2)"
		echo "No --build given, so using the newest: $build_number"
	fi

	asc_attach_build "$version_id" "$build_id"
	echo "Build $build_number is attached to $version_string."
fi

# ---------------------------------------------------------------------------
# Submit
# ---------------------------------------------------------------------------

if [ "$do_submit" -eq 1 ]; then
	step 'Submitting for review'

	submission_row="$(asc_review_submission "$app_id")"
	submission_id="$(printf '%s' "$submission_row" | cut -f1)"
	submission_state="$(printf '%s' "$submission_row" | cut -f2)"

	if [ "$submission_state" != 'READY_FOR_REVIEW' ]; then
		fail "there is already a submission for this app in state $submission_state. Wait for it, or cancel it in App Store Connect."
	fi

	asc_add_submission_item "$submission_id" "$version_id"
	asc_submit_review_submission "$submission_id"

	step "$version_string is with App Review"
	cat <<-EOF
	Review takes a day or two for a first submission. Watch the email, or run
	tools/appstore.sh --status.

	releaseType is $(jq -r '.releaseType' "$METADATA/listing.json") in $METADATA/listing.json — with MANUAL, an
	approved version waits for you to release it in App Store Connect.
	EOF
	exit 0
fi

step 'Done'

# Says what this run did rather than what a full run would have done: with
# --metadata-only or --screenshots-only, claiming a build was attached is a lie
# about the state of the version being submitted.
if [ "$do_metadata" -eq 1 ]; then echo 'Metadata pushed.'; fi
if [ "$do_screenshots" -eq 1 ]; then echo 'Screenshots uploaded.'; fi
if [ "$do_build" -eq 1 ]; then echo "Build $build_number attached."; fi

cat <<EOF
Nothing is with Apple yet.

Still needed before a first submission, once each:

  - A price. App Store Connect → Pricing and Availability → Free. Submitting
    without one is refused, and the API for price schedules is not worth the
    plumbing for a single decision that will never change.
  - App Privacy answers (App Store Connect → App Privacy). No public API.
    docs/RELEASING.md lists what to answer so it agrees with
    PrivacyInfo.xcprivacy.
  - The age rating questionnaire: tools/appstore.sh --age-rating

Then:

    tools/appstore.sh --status        # read it back
    tools/appstore.sh --submit        # send it to App Review
EOF
