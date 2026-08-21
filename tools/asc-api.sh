#!/bin/bash
#
# App Store Connect API helpers, sourced by tools/testflight.sh.
#
# Split out rather than inlined because the upload script is a readable
# sequence of xcodebuild invocations and this is HTTP plumbing; mixing them
# would obscure both. Nothing here runs on its own — source it, then call
# asc_require_credentials before anything else.
#
# Every request goes through asc_request, which treats any non-2xx as fatal and
# prints Apple's own error detail. That matters more here than usual: these
# endpoints are the least-exercised part of the release path, and a silently
# ignored failure would look exactly like a build that testers never receive.

readonly ASC_API='https://api.appstoreconnect.apple.com/v1'

asc_token_cache=''

# ---------------------------------------------------------------------------
# Credentials and auth
# ---------------------------------------------------------------------------

asc_require_credentials() {
	[ -n "${ASC_KEY_PATH:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] || {
		cat >&2 <<-'EOF'
		error: this needs an App Store Connect API key.

		The Apple ID signed into Xcode is enough to upload a build, but not to
		call the API — there is no way to mint a token from it. Create a key at
		Users and Access → Integrations → App Store Connect API, then export:

		  ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8
		  ASC_KEY_ID=XXXXXXXXXX
		  ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

		The key needs the App Manager or Admin role. A Developer-role key can
		upload a build but cannot manage beta groups or the App Store listing.
		EOF
		exit 1
	}
	[ -f "$ASC_KEY_PATH" ] || fail "no App Store Connect API key at $ASC_KEY_PATH"
}

# Minted once per run. Apple caps a token at 20 minutes and the whole external
# sequence is comfortably shorter than that, even including the processing wait.
asc_token() {
	if [ -z "$asc_token_cache" ]; then
		asc_token_cache="$(python3 "$REPO_ROOT/tools/asc-jwt.py" \
			--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer-id "$ASC_ISSUER_ID")" ||
			fail 'could not mint an App Store Connect token'
	fi
	printf '%s' "$asc_token_cache"
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

# asc_request METHOD PATH [JSON_BODY] -> response body on stdout
#
# The status code is appended to the body by curl and split off here, so that a
# failure can print what Apple actually said. Their errors carry a `detail`
# field that usually names the problem exactly; discarding it in favour of
# "request failed" is how these integrations become undebuggable.
asc_request() {
	local method="$1" path="$2" body="${3:-}"
	local args=(-sS -X "$method" -w $'\n%{http_code}'
		-H "Authorization: Bearer $(asc_token)")

	if [ -n "$body" ]; then
		args+=(-H 'Content-Type: application/json' -d "$body")
	fi

	local response status payload
	response="$(curl "${args[@]}" "$ASC_API$path")" ||
		fail "could not reach the App Store Connect API ($method $path)"

	status="${response##*$'\n'}"
	payload="${response%$'\n'*}"

	case "$status" in
		2*) printf '%s' "$payload" ;;
		401)
			fail 'App Store Connect rejected the token (401). Check ASC_KEY_ID and ASC_ISSUER_ID match the key file, and that the key has not been revoked.' ;;
		403)
			fail "App Store Connect refused the request (403). The API key most likely lacks the App Manager or Admin role. Apple said: $(asc_detail "$payload")" ;;
		*)
			fail "$method $path failed with HTTP $status. Apple said: $(asc_detail "$payload")" ;;
	esac
}

# Pulls the human-readable part out of an error document, falling back to the
# raw payload when it is not shaped the way we expect.
asc_detail() {
	printf '%s' "$1" | jq -r '(.errors // [] | map(.detail // .title) | join("; ")) // empty' 2>/dev/null ||
		printf '%s' "$1"
}

# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------

asc_app_id() {
	local bundle_id="$1" id
	id="$(asc_request GET "/apps?filter%5BbundleId%5D=$bundle_id&limit=1" |
		jq -r '.data[0].id // empty')"
	[ -n "$id" ] || fail "no app with bundle id $bundle_id is visible to this API key"
	printf '%s' "$id"
}

# `version` on a build is CFBundleVersion — the build number, not the marketing
# version. Uploads are numbered from the clock, so this is unique per upload.
asc_build_id() {
	local app_id="$1" build_number="$2" id
	id="$(asc_request GET "/builds?filter%5Bapp%5D=$app_id&filter%5Bversion%5D=$build_number&limit=1" |
		jq -r '.data[0].id // empty')"
	printf '%s' "$id"
}

asc_group_id() {
	local app_id="$1" name="$2" group
	group="$(asc_request GET "/apps/$app_id/betaGroups?limit=200" |
		jq -r --arg name "$name" '.data[] | select(.attributes.name == $name) | "\(.id)\t\(.attributes.isInternalGroup)"')"

	[ -n "$group" ] || {
		local available
		available="$(asc_request GET "/apps/$app_id/betaGroups?limit=200" |
			jq -r '.data[] | "  \(.attributes.name)  (\(if .attributes.isInternalGroup then "internal" else "external" end))"')"
		fail "no beta group named '$name'. Groups on this app:
$available

Create an external group in App Store Connect first — it needs Test Information
(beta description, feedback email, contact details, privacy policy URL) filled
in before external distribution is possible at all."
	}

	[ "$(printf '%s' "$group" | cut -f2)" = 'false' ] ||
		fail "'$name' is an internal group. Internal builds are distributed automatically and need none of this; pass the name of an external group."

	printf '%s' "$(printf '%s' "$group" | cut -f1)"
}

asc_app_name() {
	asc_request GET "/apps/$1" | jq -r '.data.attributes.name // empty'
}

# "Does your app contain, show, or access third-party content?" — an app-level
# declaration, required before a first submission and easy to forget because
# nothing asks for it until the submission is refused.
asc_set_content_rights() {
	asc_request PATCH "/apps/$1" "$(jq -nc --arg id "$1" --arg declaration "$2" \
		'{data: {type: "apps", id: $id, attributes: {contentRightsDeclaration: $declaration}}}')" >/dev/null
}

# id and build number of the most recently uploaded build, tab separated. Used
# when no --build is given: the last thing uploaded is nearly always the thing
# meant.
asc_latest_build() {
	asc_request GET "/builds?filter%5Bapp%5D=$1&sort=-uploadedDate&limit=1" |
		jq -r '.data[0] | select(.) | [.id, .attributes.version] | @tsv'
}

# ---------------------------------------------------------------------------
# The App Store version, and everything hanging off it
#
# The shape, because it is not obvious and the names are nearly the same:
#
#   app
#    ├── appInfo                       one per app, not per version
#    │    ├── appInfoLocalizations     name, subtitle, privacy policy URL
#    │    └── primary/secondaryCategory
#    └── appStoreVersion               one per version number
#         ├── appStoreVersionLocalizations   description, keywords, URLs,
#         │    └── appScreenshotSets          what's new, promotional text
#         │         └── appScreenshots
#         ├── appStoreReviewDetail      contact details and notes for review
#         └── build                     the binary this version ships
#
# So the subtitle and the description live in different places, on different
# sides of the version boundary — which is why editing one leaves the other
# alone, and why a new version inherits the subtitle but not the description.
# ---------------------------------------------------------------------------

# Each of the four lookups below has a find_ form that reports what is there and
# a plain form that creates what is missing. Reading the state of a listing must
# not bring half of it into existence — `--status` uses the find_ forms
# throughout, and a status command with side effects would be its own bug.

# Prints "<id>\t<state>", or nothing if this version does not exist yet.
asc_find_version() {
	asc_request GET "/apps/$1/appStoreVersions?filter%5Bplatform%5D=IOS&limit=50" |
		jq -r --arg version "$2" '
			.data[]
			| select(.attributes.versionString == $version)
			| [.id, (.attributes.appVersionState // .attributes.appStoreState // "UNKNOWN")]
			| @tsv'
}

# The version resource for `version_string`, creating it if App Store Connect
# has never heard of it. Prints "<id>\t<state>".
asc_version() {
	local app_id="$1" version_string="$2" found id
	found="$(asc_find_version "$app_id" "$version_string")"

	if [ -n "$found" ]; then
		printf '%s' "$found"
		return 0
	fi

	id="$(asc_request POST '/appStoreVersions' "$(jq -nc \
		--arg app "$app_id" --arg version "$version_string" \
		'{data: {type: "appStoreVersions",
		         attributes: {platform: "IOS", versionString: $version},
		         relationships: {app: {data: {type: "apps", id: $app}}}}}')" |
		jq -r '.data.id')"
	printf '%s\tPREPARE_FOR_SUBMISSION' "$id"
}

# How many iOS versions the app has ever had. One means this is the first
# release, which is the only case where What's New must not be sent — there is
# nothing for it to be new since, and App Store Connect rejects it.
asc_version_count() {
	asc_request GET "/apps/$1/appStoreVersions?filter%5Bplatform%5D=IOS&limit=200" |
		jq -r '.data | length'
}

asc_patch_version() {
	asc_request PATCH "/appStoreVersions/$1" "$(jq -nc --arg id "$1" --argjson attrs "$2" \
		'{data: {type: "appStoreVersions", id: $id, attributes: $attrs}}')" >/dev/null
}

asc_app_info_id() {
	# An app has one appInfo per state; the editable one is whichever is not
	# already on the store.
	asc_request GET "/apps/$1/appInfos?limit=10" |
		jq -r '[.data[] | select((.attributes.appStoreState // .attributes.state // "") != "READY_FOR_SALE")][0].id
			// .data[0].id // empty'
}

asc_set_categories() {
	local app_info_id="$1" primary="$2" secondary="$3" relationships
	relationships="$(jq -nc --arg primary "$primary" --arg secondary "$secondary" '
		{primaryCategory: {data: (if $primary == "" then null else {type: "appCategories", id: $primary} end)},
		 secondaryCategory: {data: (if $secondary == "" then null else {type: "appCategories", id: $secondary} end)}}')"
	asc_request PATCH "/appInfos/$app_info_id" "$(jq -nc \
		--arg id "$app_info_id" --argjson rel "$relationships" \
		'{data: {type: "appInfos", id: $id, relationships: $rel}}')" >/dev/null
}

# The localization for `locale`, created if absent. The set of locales an app
# has is not fixed by anything in this repository — adding a language to the
# listing is adding a directory under docs/appstore/ and running this.
asc_find_app_info_localization() {
	asc_request GET "/appInfos/$1/appInfoLocalizations?limit=200" |
		jq -r --arg locale "$2" '.data[] | select(.attributes.locale == $locale) | .id'
}

# `name` is required to *create* a localization — a listing in a new language has
# to be called something — but is never sent when patching an existing one. The
# two are different acts: naming a listing that has no name yet is not renaming
# one that does. The caller passes the app's current name, so a new language
# inherits it; give that language a name of its own in App Store Connect
# afterwards if it wants one.
asc_app_info_localization() {
	local app_info_id="$1" locale="$2" name="$3" id
	id="$(asc_find_app_info_localization "$app_info_id" "$locale")"
	[ -z "$id" ] || { printf '%s' "$id"; return 0; }

	asc_request POST '/appInfoLocalizations' "$(jq -nc \
		--arg info "$app_info_id" --arg locale "$locale" --arg name "$name" \
		'{data: {type: "appInfoLocalizations", attributes: {locale: $locale, name: $name},
		         relationships: {appInfo: {data: {type: "appInfos", id: $info}}}}}')" |
		jq -r '.data.id'
}

# Deliberately never sends `name`: the store name was reserved by hand and a
# script overwriting it is a rename nobody asked for. Everything else in this
# resource is fair game.
asc_patch_app_info_localization() {
	asc_request PATCH "/appInfoLocalizations/$1" "$(jq -nc --arg id "$1" --argjson attrs "$2" \
		'{data: {type: "appInfoLocalizations", id: $id, attributes: $attrs}}')" >/dev/null
}

asc_find_version_localization() {
	asc_request GET "/appStoreVersions/$1/appStoreVersionLocalizations?limit=200" |
		jq -r --arg locale "$2" '.data[] | select(.attributes.locale == $locale) | .id'
}

asc_version_localization() {
	local version_id="$1" locale="$2" id
	id="$(asc_find_version_localization "$version_id" "$locale")"
	[ -z "$id" ] || { printf '%s' "$id"; return 0; }

	asc_request POST '/appStoreVersionLocalizations' "$(jq -nc \
		--arg version "$version_id" --arg locale "$locale" \
		'{data: {type: "appStoreVersionLocalizations", attributes: {locale: $locale},
		         relationships: {appStoreVersion: {data: {type: "appStoreVersions", id: $version}}}}}')" |
		jq -r '.data.id'
}

asc_patch_version_localization() {
	asc_request PATCH "/appStoreVersionLocalizations/$1" "$(jq -nc --arg id "$1" --argjson attrs "$2" \
		'{data: {type: "appStoreVersionLocalizations", id: $id, attributes: $attrs}}')" >/dev/null
}

asc_set_review_detail() {
	local version_id="$1" attrs="$2" id
	id="$(asc_request GET "/appStoreVersions/$version_id/appStoreReviewDetail" |
		jq -r '.data.id // empty')"

	if [ -n "$id" ]; then
		asc_request PATCH "/appStoreReviewDetails/$id" "$(jq -nc --arg id "$id" --argjson attrs "$attrs" \
			'{data: {type: "appStoreReviewDetails", id: $id, attributes: $attrs}}')" >/dev/null
	else
		asc_request POST '/appStoreReviewDetails' "$(jq -nc \
			--arg version "$version_id" --argjson attrs "$attrs" \
			'{data: {type: "appStoreReviewDetails", attributes: $attrs,
			         relationships: {appStoreVersion: {data: {type: "appStoreVersions", id: $version}}}}}')" >/dev/null
	fi
}

# The declaration hangs off appInfo, not appStoreVersion: a rating describes the
# app, not one release of it. It used to be the other way round, and asking a
# version for its ageRatingDeclaration now 404s with "the relationship does not
# exist" — which names the relationship but not the resource that has it.
#
# Apple wants the *entire* questionnaire in one request. Sending a single
# attribute comes back 409 listing every other one it wants, so there is no
# partial update and no point attempting one.
asc_set_age_rating() {
	local app_info_id="$1" attrs="$2" id
	id="$(asc_request GET "/appInfos/$app_info_id/ageRatingDeclaration" |
		jq -r '.data.id // empty')"
	[ -n "$id" ] || fail 'this app has no age rating declaration to patch.'
	asc_request PATCH "/ageRatingDeclarations/$id" "$(jq -nc --arg id "$id" --argjson attrs "$attrs" \
		'{data: {type: "ageRatingDeclarations", id: $id, attributes: $attrs}}')" >/dev/null
}

asc_attach_build() {
	asc_request PATCH "/appStoreVersions/$1/relationships/build" "$(jq -nc --arg build "$2" \
		'{data: {type: "builds", id: $build}}')" >/dev/null
}

asc_attached_build() {
	asc_request GET "/appStoreVersions/$1/build" | jq -r '.data.attributes.version // empty'
}

# ---------------------------------------------------------------------------
# Screenshots
#
# Three steps per image, none of which can be skipped: reserve a slot and get
# back one or more pre-signed PUTs, send the bytes, then say it is done and
# prove it with a checksum. Apple verifies the checksum, so a truncated upload
# fails here rather than showing up as a corrupt screenshot on the store.
# ---------------------------------------------------------------------------

asc_find_screenshot_set() {
	asc_request GET "/appStoreVersionLocalizations/$1/appScreenshotSets?limit=50" |
		jq -r --arg type "$2" '.data[] | select(.attributes.screenshotDisplayType == $type) | .id'
}

asc_screenshot_set() {
	local localization_id="$1" display_type="$2" id
	id="$(asc_find_screenshot_set "$localization_id" "$display_type")"
	[ -z "$id" ] || { printf '%s' "$id"; return 0; }

	asc_request POST '/appScreenshotSets' "$(jq -nc \
		--arg localization "$localization_id" --arg type "$display_type" \
		'{data: {type: "appScreenshotSets", attributes: {screenshotDisplayType: $type},
		         relationships: {appStoreVersionLocalization:
		           {data: {type: "appStoreVersionLocalizations", id: $localization}}}}}')" |
		jq -r '.data.id'
}

# Emptied before uploading, so what is on the store is what is in build/, in the
# order the filenames give. Appending instead would silently double the set on
# the second run.
asc_clear_screenshot_set() {
	local set_id="$1" id
	while IFS= read -r id; do
		[ -n "$id" ] || continue
		asc_request DELETE "/appScreenshots/$id" >/dev/null
	done < <(asc_request GET "/appScreenshotSets/$set_id/appScreenshots?limit=200" |
		jq -r '.data[].id')
}

asc_upload_screenshot() {
	local set_id="$1" path="$2"
	local name size reservation screenshot_id count index operation
	local method url offset length checksum state

	name="$(basename "$path")"
	size="$(wc -c < "$path" | tr -d ' ')"

	reservation="$(asc_request POST '/appScreenshots' "$(jq -nc \
		--arg set "$set_id" --arg name "$name" --argjson size "$size" \
		'{data: {type: "appScreenshots", attributes: {fileName: $name, fileSize: $size},
		         relationships: {appScreenshotSet: {data: {type: "appScreenshotSets", id: $set}}}}}')")"

	screenshot_id="$(printf '%s' "$reservation" | jq -r '.data.id')"
	count="$(printf '%s' "$reservation" | jq -r '.data.attributes.uploadOperations | length')"
	[ "$count" -gt 0 ] || fail "App Store Connect reserved $name but offered nowhere to upload it to"

	for ((index = 0; index < count; index++)); do
		operation="$(printf '%s' "$reservation" | jq -c ".data.attributes.uploadOperations[$index]")"
		method="$(printf '%s' "$operation" | jq -r '.method')"
		url="$(printf '%s' "$operation" | jq -r '.url')"
		offset="$(printf '%s' "$operation" | jq -r '.offset')"
		length="$(printf '%s' "$operation" | jq -r '.length')"

		# The pre-signed URL carries its own authorization; the API bearer token
		# must not be sent with it.
		local headers=()
		local header value
		while IFS=$'\t' read -r header value; do
			[ -n "$header" ] || continue
			headers+=(-H "$header: $value")
		done < <(printf '%s' "$operation" | jq -r '.requestHeaders[]? | [.name, .value] | @tsv')

		tail -c "+$((offset + 1))" "$path" | head -c "$length" |
			curl -sS -f -X "$method" "${headers[@]+"${headers[@]}"}" --data-binary @- "$url" ||
			fail "uploading $name failed on part $((index + 1)) of $count"
	done

	checksum="$(md5 -q "$path")"
	asc_request PATCH "/appScreenshots/$screenshot_id" "$(jq -nc \
		--arg id "$screenshot_id" --arg sum "$checksum" \
		'{data: {type: "appScreenshots", id: $id,
		         attributes: {uploaded: true, sourceFileChecksum: $sum}}}')" >/dev/null

	# Apple validates size and format asynchronously. Reading the state back is
	# the difference between "uploaded" and "accepted", and a rejected image is
	# otherwise only visible in the web interface.
	state="$(asc_request GET "/appScreenshots/$screenshot_id" |
		jq -r '.data.attributes.assetDeliveryState.state // "UNKNOWN"')"
	case "$state" in
		FAILED|INVALID)
			fail "App Store Connect rejected $name: $(asc_request GET "/appScreenshots/$screenshot_id" |
				jq -r '[.data.attributes.assetDeliveryState.errors[]?.description] | join("; ")')" ;;
	esac
}

# ---------------------------------------------------------------------------
# The external sequence
# ---------------------------------------------------------------------------

# A build cannot join a group until App Store Connect has finished processing
# it, which takes minutes and has no callback. PROCESSING is the normal state on
# arrival; INVALID and FAILED are terminal and worth stopping on rather than
# waiting out the full timeout.
asc_wait_for_processing() {
	local app_id="$1" build_number="$2" timeout="$3"
	local waited=0 interval=30 build_id state

	while [ "$waited" -lt "$timeout" ]; do
		build_id="$(asc_build_id "$app_id" "$build_number")"

		if [ -n "$build_id" ]; then
			state="$(asc_request GET "/builds/$build_id" |
				jq -r '.data.attributes.processingState // empty')"
			case "$state" in
				VALID)
					printf '%s' "$build_id"
					return 0 ;;
				INVALID|FAILED)
					fail "App Store Connect reports build $build_number as $state. Check the email it sent for the reason." ;;
			esac
		fi

		# Reported on stderr so stdout stays the build id and nothing else.
		printf '  still %s after %ds...\n' "${state:-awaiting the build record}" "$waited" >&2
		sleep "$interval"
		waited=$((waited + interval))
	done

	fail "build $build_number was still not ready after ${timeout}s. It may simply be slow — re-run with --external-only --build $build_number once it appears."
}

# Every locale gets the same text. The alternative is guessing which locale the
# testers read, and the note is about what changed in the build rather than
# anything user-facing.
asc_set_whats_new() {
	local build_id="$1" text="$2" localizations count
	localizations="$(asc_request GET "/builds/$build_id/betaBuildLocalizations?limit=200" |
		jq -r '.data[].id')"

	[ -n "$localizations" ] || {
		printf '  no beta build localizations exist yet; skipping the What to Test note\n' >&2
		return 0
	}

	count=0
	local id body
	while IFS= read -r id; do
		body="$(jq -nc --arg id "$id" --arg text "$text" \
			'{data: {type: "betaBuildLocalizations", id: $id, attributes: {whatsNew: $text}}}')"
		asc_request PATCH "/betaBuildLocalizations/$id" "$body" >/dev/null
		count=$((count + 1))
	done <<< "$localizations"

	printf '  What to Test set on %d localization(s)\n' "$count" >&2
}

asc_add_to_group() {
	local build_id="$1" group_id="$2" body
	body="$(jq -nc --arg id "$group_id" \
		'{data: [{type: "betaGroups", id: $id}]}')"
	asc_request POST "/builds/$build_id/relationships/betaGroups" "$body" >/dev/null
}

# Idempotency is Apple's here: submitting a build that is already in review
# comes back as a 409, which asc_request surfaces with their wording rather than
# retrying into a duplicate.
asc_submit_review() {
	local build_id="$1" body
	body="$(jq -nc --arg id "$build_id" \
		'{data: {type: "betaAppReviewSubmissions", relationships: {build: {data: {type: "builds", id: $id}}}}}')"
	asc_request POST '/betaAppReviewSubmissions' "$body" >/dev/null
}

# ---------------------------------------------------------------------------
# App Review submission
#
# Not the same thing as Beta App Review above, and not the same API either. A
# submission is a container: it is created empty, one item per thing being
# reviewed is added to it, and then the whole container is submitted. The older
# appStoreVersionSubmissions endpoint submitted a version directly and no longer
# covers everything a submission can contain.
# ---------------------------------------------------------------------------

# Prints "<id>\t<state>" for a submission that is neither finished nor being
# cancelled, or nothing if there is none.
asc_find_review_submission() {
	asc_request GET "/reviewSubmissions?filter%5Bapp%5D=$1&filter%5Bplatform%5D=IOS&limit=50" |
		jq -r '[.data[] | select(.attributes.state != "COMPLETE" and .attributes.state != "CANCELING")][0]
			| select(.) | [.id, .attributes.state] | @tsv'
}

# An open submission that has not been sent yet, created if there is none.
# Prints "<id>\t<state>". A submission already in review is returned as it is —
# what to do about that is the caller's decision, not this function's.
asc_review_submission() {
	local app_id="$1" found id
	found="$(asc_find_review_submission "$app_id")"

	if [ -n "$found" ]; then
		printf '%s' "$found"
		return 0
	fi

	id="$(asc_request POST '/reviewSubmissions' "$(jq -nc --arg app "$app_id" \
		'{data: {type: "reviewSubmissions", attributes: {platform: "IOS"},
		         relationships: {app: {data: {type: "apps", id: $app}}}}}')" |
		jq -r '.data.id')"
	printf '%s\tREADY_FOR_REVIEW' "$id"
}

# Idempotent by inspection rather than by Apple: adding the same version twice
# is an error, and the second run of a script that failed on the step after this
# one is exactly when that would happen.
asc_add_submission_item() {
	local submission_id="$1" version_id="$2" existing
	existing="$(asc_request GET "/reviewSubmissions/$submission_id/items?limit=50" |
		jq -r --arg version "$version_id" \
			'.data[] | select(.relationships.appStoreVersion.data.id == $version) | .id')"
	[ -z "$existing" ] || return 0

	asc_request POST '/reviewSubmissionItems' "$(jq -nc \
		--arg submission "$submission_id" --arg version "$version_id" \
		'{data: {type: "reviewSubmissionItems",
		         relationships: {reviewSubmission: {data: {type: "reviewSubmissions", id: $submission}},
		                         appStoreVersion: {data: {type: "appStoreVersions", id: $version}}}}}')" >/dev/null
}

asc_submit_review_submission() {
	asc_request PATCH "/reviewSubmissions/$1" "$(jq -nc --arg id "$1" \
		'{data: {type: "reviewSubmissions", id: $id, attributes: {submitted: true}}}')" >/dev/null
}
