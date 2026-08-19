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
		error: external distribution needs an App Store Connect API key.

		The Apple ID signed into Xcode is enough to upload a build, but not to
		call the API — there is no way to mint a token from it. Create a key at
		Users and Access → Integrations → App Store Connect API, then export:

		  ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8
		  ASC_KEY_ID=XXXXXXXXXX
		  ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

		The key needs the App Manager or Admin role. A Developer-role key can
		upload but cannot manage beta groups.
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
