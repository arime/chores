# Releasing

## Database changes

Migrations live in `supabase/migrations/`. Apply them yourself:

    supabase link --project-ref <project-ref>
    supabase db push

Run `supabase test db` locally first — the pgTAP suite in `supabase/tests/` is the
regression gate for RLS, and an RLS bug fails silently.

## Environments

`Secrets.swift` holds both projects, and the build configuration decides which one the
app uses:

| Build | Backend |
|---|---|
| Debug — simulator, or a phone run from Xcode | Local |
| Debug with `-hosted` ticked in the scheme's Run arguments | Hosted |
| Release — archive, TestFlight, or ⌘R in Release | Hosted, always |

The discriminator is the configuration rather than the platform, because a phone
tethered to Xcode is still development. Release is the only configuration an archive
can be built from, so a distributed build has no code path to the local stack.

The local URL is the Mac's Bonjour name (`scutil --get LocalHostName` plus `.local`),
not `127.0.0.1`, so that a phone on the same Wi-Fi reaches the stack as well — loopback
would mean the phone itself. `NSAllowsLocalNetworking` in `App/Info.plist` is what
permits the cleartext connection; it covers `.local` and loopback only.

A phone using the local stack must be on the same Wi-Fi as the Mac. USB tethering
carries the debugger, not the network, so on cellular or a guest network you get the
"Can't reach the server" screen.

## Installing a Release build without TestFlight

Edit Scheme → Run → Build Configuration → Release, then ⌘R to the device. It installs
and keeps working with the cable gone, until the provisioning profile expires — twelve
months on a paid membership, seven days on a free personal team. Set the configuration
back to Debug afterwards: the scheme is shared, so it changes what everyone's ⌘R does.

## App builds

1. Confirm the `Hosted` values in `App/Chores/Secrets.swift`. It is gitignored; copy
   `App/Chores/Secrets.swift.example` if it is missing.
2. Run `swift test` from the repo root — all ChoresCore tests must pass.
3. Run the UI suite once:

       xcodebuild -project App/Chores.xcodeproj -scheme Chores \
         -destination 'platform=iOS Simulator,name=iPhone 17' test

4. Sign in with Apple has **no automated coverage**, and cannot have any — no test can mint an
   Apple identity token, and XCTest cannot drive Apple's system sheet. The whole UI suite runs
   against a stub provider, so the production button and the real sign-in path are exercised by
   nothing. Check them by hand on a real device before every TestFlight build:

   - Tap the Sign in with Apple button itself. It is a `SignInWithAppleButton` with hit-testing
     disabled and a transparent `Button` overlaid, so confirm it actually receives the tap.
   - Sign in and create a family.
   - Cancel Apple's sheet on a second attempt: it must return quietly, with no error message.
   - Force-quit and relaunch — the family must return with no code.
   - Delete the app, reinstall, sign in again — the family must return again. That is the whole
     point of the feature, and the only step that proves it.

5. Archive and upload:

       tools/testflight.sh

   Xcode → Any iOS Device → Product → Archive → Distribute → TestFlight still works
   and does the same thing. The script exists so that steps 2–4 remain the only part
   of a release needing a human, and so the upload can be handed to an agent.

## Sign in with Apple: what makes it work

**The entitlement is in the repository.** `App/Chores/Chores.entitlements` declares
`com.apple.developer.applesignin`, and both Chores build configurations point at it through
`CODE_SIGN_ENTITLEMENTS`, so a fresh clone already builds a binary that can sign someone in. Do not
add the capability again in Signing & Capabilities — Xcode would write a second entitlements file
beside the tracked one.

Recognise the failure it causes, because nothing in it names the cause. Without the entitlement,
`akd` refuses the request before any network call and logs
`AKAuthenticationError Code=-7026`; `AuthenticationServices` flattens that into
`ASAuthorizationError Code=1000`, and the app shows "Couldn't sign in". Nothing in the test suite
notices, because the suite never reaches it.

Two cheap checks, worth running whenever the signing configuration changes:

    grep -n CODE_SIGN_ENTITLEMENTS App/Chores.xcodeproj/project.pbxproj
    plutil -p App/Chores/Chores.entitlements

Neither proves the entitlement survives into a build, and **only a device build can**. Xcode writes
an empty entitlements blob for simulator destinations, so a simulator binary shows nothing here and
that absence means nothing:

    xcodebuild -project App/Chores.xcodeproj -scheme Chores \
      -destination 'generic/platform=iOS' -configuration Debug build
    codesign -d --entitlements - --xml \
      ~/Library/Developer/Xcode/DerivedData/Chores-*/Build/Products/Debug-iphoneos/Chores.app \
      | plutil -p -

`com.apple.developer.applesignin` must appear alongside `application-identifier`.

Two things stay outside the repository.

**The App ID.** `com.metsahalme.Chores` needs Sign in with Apple enabled on the developer portal, or
the profile cannot carry the entitlement and signing fails. Automatic signing enables it and
regenerates the profile on the next device build. To see what the current profile permits:

    security cms -D -i ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision \
      | plutil -extract Entitlements xml1 -o - - | plutil -p -

**Hosted Supabase.** Authentication → Providers → **Apple** → enable, and put
`com.metsahalme.Chores` in Client IDs. Leave the Secret Key fields empty: they serve the OAuth web
flow, while native `signInWithIdToken` needs only the client ID so the server can check the token's
`aud` claim. Leave anonymous sign-ins enabled — children still depend on them.

**Local** is already configured: `[auth.external.apple]` in `supabase/config.toml` is enabled with
the same client ID.

## TestFlight

### What it needs that a development build does not

A **paid Apple Developer Program membership**. A free personal team cannot reach
TestFlight at all — it signs, but it cannot distribute. The tell is the provisioning
profile: seven days on a personal team, twelve months on a paid one.

    security cms -D -i ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision \
      | plutil -extract ExpirationDate raw -

Enrolment is not instant — identity verification takes a day or two, longer for an
organisation account — so start it before anything else here matters.

Then, once per app:

- Set `DEVELOPMENT_TEAM` to the paid team.
- Register `com.metsahalme.Chores` and create the app record in App Store Connect.
  The display name there is separate from the bundle ID and has to be unique across
  the store, so plain "Chores" may already be taken.

### Before every upload

- **Push the migrations to hosted first.** Release builds always use Hosted, so a
  migration that has not been pushed is a build that fails on a tester's first launch
  rather than on yours. Missing table grants are the version of this that looks like
  an outage: the app can reach the server perfectly well and is refused by it.
  `tools/testflight.sh` refuses to build until `supabase db push --dry-run` reports the
  hosted database up to date; it never pushes for you.
- The build number must be one App Store Connect has not seen. It is per-upload, not
  per-release — a rejected upload burns one. `MARKETING_VERSION` only changes when the
  version users see changes.

### Uploading from the command line

`tools/testflight.sh` is the whole of step 5. It archives, verifies the archive, then
exports and uploads. `--help` lists its options; the useful ones are `--archive-only`,
which stops before uploading, and `--build`, which overrides the build number.

**Build numbers come from the clock, not the project file.** The script passes
`CURRENT_PROJECT_VERSION=$(date -u '+%Y%m%d.%H%M')` to `xcodebuild` as a build-setting
override. `GENERATE_INFOPLIST_FILE` is `YES` and `App/Info.plist` declares no
`CFBundleVersion`, so the override reaches the bundle and nothing in the repository
changes — no build-number commits, and no way to upload a number twice. UTC keeps it
monotonic across daylight-saving changes. The value committed in `project.pbxproj`
therefore only affects builds made through Xcode.

**Signing happens twice, and only the second one ships.** The Release configuration
sets `CODE_SIGN_IDENTITY = "Apple Development"`, so the archive is signed with a
development identity. `xcodebuild -exportArchive` then re-signs the bundle with
`Apple Distribution` and strips `get-task-allow`, which is the signature testers
receive. This is the same thing Xcode's Distribute button does, so the development
identity on the archive is expected and not worth changing. `-allowProvisioningUpdates`
is what lets the export fetch the App Store provisioning profile.

**What the script checks before uploading.** These are the checks the Organizer cannot
make by eye, and each one has a failure it is there to catch:

| Check | What it catches |
|---|---|
| Hosted migrations up to date | a Release build whose first launch fails for a tester |
| `com.apple.developer.applesignin` in the *signed* entitlements | Sign in with Apple failing at runtime with `ASAuthorizationError Code=1000` and nothing naming the cause |
| `LSRequiresIPhoneOS` present | a simulator build, which carries no usable signature |
| Build number and bundle id match what was asked for | an override that silently did not apply |
| `Chores.app.dSYM` present | tester crash reports arriving unsymbolicated |
| `PrivacyInfo.xcprivacy` in the bundle | the manifest being dropped from the bundle |

**Authentication** uses the Apple ID signed into Xcode. For a headless or CI run,
export `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID` for an App Store Connect API
key instead (Users and Access → Integrations → App Store Connect API); the script
validates all three up front and passes them to `-exportArchive`.

**There is no `.ipa` afterwards.** `App/ExportOptions.plist` sets `destination` to
`upload`, so the build goes straight to App Store Connect and nothing is written to
the export path. The upload is recorded in the archive's own `Info.plist` under
`Distributions`, and `build/uploads.log` gets a line with the build number and the
commit it came from. To read the record back:

    plutil -p build/Chores.xcarchive/Info.plist

`uploadEvent` → `state` is `success` on an upload that landed, and `uploadedBuildNumber`
is what App Store Connect received — it equals the archived build number because
`manageAppVersionAndBuildNumber` is `false` in the export options. Left at its default
of `true`, Xcode would renumber the build during upload.

### Internal or external

**Internal** testing covers up to 100 people holding a role on the App Store Connect
team, and skips Beta App Review entirely — builds land minutes after processing. This
is what a family app wants.

Adding people to the team costs nothing beyond the membership, but each internal tester
needs **their own Apple ID** and has to accept an invitation. Apple's minimum age for an
Apple ID the person controls is 13 in most of Europe, and a child account managed through
Family Sharing cannot become an App Store Connect user — Family Sharing does not share
TestFlight builds either. For a child below that age the options are a device signed into
a parent's Apple ID, or the Release build described under "Installing a Release build
without TestFlight" above, which lasts twelve months on a paid membership.

The other cost is access: the roles that can receive builds can also edit app metadata or
touch certificates. Give the least-privileged role that still works.

**External** testing reaches up to 10,000 testers by public link, and needs Beta App
Review plus test notes and a contact address. Review is lighter than the App Store's
but is still a queue.

Two things have to exist before any external build can go anywhere, and both are one-time
web tasks that no CLI replaces:

- **Test Information** (TestFlight → Test Information): beta description, feedback email,
  contact details, privacy policy URL. Until it is complete, external distribution is
  impossible — and it fails quietly, while internal testing keeps working, which is what
  makes it confusing.
- **An external group**, with its public link enabled.

After that, the per-build steps are scripted:

    tools/testflight.sh --external                  # upload, wait for processing,
                                                    # add to the group, submit for review
    tools/testflight.sh --external-only --build 42  # the same two steps against a build
                                                    # that was uploaded earlier

`--external-group` names a group other than the default `External Testers`, or set
`ASC_EXTERNAL_GROUP`. `--whats-new` sets the What to Test note; it defaults to the commit
subject and the build number.

This removes the web interaction, not the wait. Beta App Review still queues — a day or so
for the first build of a new `MARKETING_VERSION`, usually quick for later ones.

**`--external` requires an App Store Connect API key**, unlike a plain upload: there is no
way to mint an API token from the Apple ID signed into Xcode. The key needs the **App
Manager or Admin** role, because a Developer-role key can upload a build but cannot manage
beta groups. Token minting lives in `tools/asc-jwt.py` — ES256 signing is openssl's job,
and that script only converts the signature from DER to the raw form JOSE wants.
`python3 tools/asc-jwt.py --selftest` checks that conversion offline, which is worth
running if the API starts returning 401 for no apparent reason.

### Privacy and export answers

Both are declared in the repository, so App Store Connect should stop asking:

- `App/Chores/PrivacyInfo.xcprivacy` — the manifest. It ships inside the bundle, which
  is why it lives in the synchronized folder rather than beside `App/Info.plist`.
- `ITSAppUsesNonExemptEncryption` in `App/Info.plist` — false, because the only
  encryption is the system's own HTTPS.

The privacy answers given in App Store Connect must agree with the manifest. It declares
names and user content — display names, chore names, the schedule and completion history
— as collected, linked to the user, for app functionality, and no tracking. If what the
app stores ever changes, both sides change together. "The App Privacy answers" under
[The App Store](#the-app-privacy-answers) below has them as a table, to be answered
against.

## The App Store

### What a public release needs that TestFlight does not

TestFlight distributes a binary. The App Store sells a *listing*, and most of what
follows is about the listing rather than the app. Three things are new, and one is
smaller than it looks:

- **A privacy policy URL and a support URL that resolve.** Both are required
  fields, and App Review opens them. They live in `docs/site/` and are published
  to GitHub Pages by `.github/workflows/pages.yml`. The app links to the same two
  pages from Manage, through `App/Chores/AppLinks.swift`.
- **Screenshots**, at the exact pixel size Apple asks for. Generated:
  `tools/screenshots.sh`.
- **The listing text**, in both languages. In `docs/appstore/`, pushed by
  `tools/appstore.sh`.
- **The App Privacy answers and the age rating.** Two questionnaires, each
  answered once, neither per-release.

The app itself needed one change: **iPhone only**. `TARGETED_DEVICE_FAMILY` is
`1`, not `1,2`. Declaring iPad support means a mandatory iPad screenshot set and
a reviewer opening every screen on a 13-inch canvas — a class of rejection the app
gains nothing by risking. It still runs on an iPad, in iPhone compatibility mode.

### Publishing the site, once

Settings → Pages → Build and deployment → Source: **GitHub Actions**. Then any
push touching `docs/site/` publishes it, and the workflow prints the URL.

The contact address on the pages is `arime-chores@proton.me`, and the workflow
refuses to publish if a `SUPPORT_EMAIL_TODO` placeholder ever comes back — a
support page whose only address is a placeholder is worse than no page, and App
Review reads these.

One placeholder is still outstanding: `REVIEW_PHONE_TODO` in
`docs/appstore/listing.json`. App Review requires a phone number for the contact,
and `tools/appstore.sh` refuses to send anything while any `_TODO` is left in
`docs/appstore/`. To see what is left:

    grep -rn '_TODO' docs/appstore docs/site

### The screenshots

    tools/screenshots.sh                 # both languages
    tools/screenshots.sh --language fi   # one

It boots a 6.9" simulator, pins the status bar to 9:41 with a full battery, runs
`ChoresUITests/ScreenshotTests` once per listing language, and pulls the PNGs out
of the result bundle into `build/screenshots/<locale>/`. Then it checks their
size, because a wrong-sized screenshot is rejected minutes later by a message
that names a display type rather than a simulator.

The app is launched with `-screenshots-parent` or `-screenshots-kid`, which seed
the lived-in family in `InMemoryChoresBackend.seedDemoFamily` — three children, a
full week of chores, earlier days already done, today deliberately half done.
Nothing about it touches Supabase.

`ScreenshotTests` **skips unless `SCREENSHOTS=1` is in the test runner's
environment**, which the script sets via `TEST_RUNNER_SCREENSHOTS=1`. So the
ordinary `xcodebuild test` run reports them as skipped, and stays a test run.

They are not in git. `docs/appstore/README.md` says why.

### The listing

    tools/appstore.sh --status      # what App Store Connect has now
    tools/appstore.sh               # push metadata and screenshots, attach a build
    tools/appstore.sh --submit      # the same, then submit for review

The listing is `docs/appstore/`: one directory per locale, one file per field,
with the field limits enforced before anything is sent. That file's own README
covers what each one is.

This needs an **App Store Connect API key** — the same one `--external` needs,
with the App Manager or Admin role. The Apple ID in Xcode cannot mint a token.

Two things it will not do, deliberately. It never writes the app's **name**: that
was reserved by hand and is unique across the store, so a script overwriting it
is a rename nobody asked for. And it does not **submit** unless asked, because
that is the one step with a queue behind it.

`releaseType` in `listing.json` is `MANUAL`, so an approved version waits for you
to release it. Change it to `AFTER_APPROVAL` for a version that should go live the
moment it passes.

### A price, once

App Store Connect → Pricing and Availability → **Free**. A submission with no
price schedule is refused, and the message is about pricing rather than about
this being a thing nobody set. The API can do it, through price points and a
base territory, but it is one decision that will never change and not worth the
plumbing.

Availability defaults to every territory, which is what a free family app wants.

### The App Privacy answers

App Store Connect → App Privacy. Apple has no public API for this one, so it is a
web task — and the answers must match `App/Chores/PrivacyInfo.xcprivacy` exactly,
because the two are read side by side and a mismatch is a rejection that names
neither file.

What the manifest declares, and therefore what to answer:

| Data | Collected | Linked to the user | Tracking | Purpose |
|---|---|---|---|---|
| Contact Info → Name | yes | yes | no | App Functionality |
| User Content → Other User Content | yes | yes | no | App Functionality |

Nothing else. No identifiers, no usage data, no diagnostics: there is no
analytics or crash-reporting SDK in the project, and the reminder is a local
notification with no push token. "Do you or your third-party partners use data
for tracking?" is **no**.

The names are the display names of parents and children. The other user content
is the chore names, the weekly schedule and the completion history. If what the
app stores ever changes, the manifest, these answers and
`docs/site/privacy/` all change together.

### The age rating

    tools/appstore.sh --age-rating

Applies `docs/appstore/age-rating.json`, which declares nothing at all. Apple
computes the rating from it and returned **4+**, with Brazil self-rated L. Once
per app, not per version: the declaration hangs off `appInfo` rather than
`appStoreVersion`, and asking a version for it 404s with "the relationship
`ageRatingDeclaration` does not exist" — which names the relationship but not the
resource that actually has one.

The file has to answer *every* question in the questionnaire. A PATCH carrying
one attribute comes back 409 listing all the others, so there is no partial
update. When Apple next revises the questionnaire, the same 409 is how you will
find out, and the fields it names are the fields to add.

Two answers in it are judgement calls rather than facts:

- `userGeneratedContent` is **false**. A parent types names and chores that their
  own children see, which is user-entered content but not user-generated content
  in the sense the question is asking about — there are no strangers, no feed and
  nothing to discover. Answering true would pull in Guideline 1.2's moderation,
  reporting and blocking requirements and raise the age band.
- `parentalControls` is **false**. A parent does control what a child's device
  shows, but there is no PIN or gate of the kind the question means.

`kidsAgeBand` is deliberately null: that field is what puts an app in the **Kids
Category**, which brings its own rules — no third-party analytics or advertising,
a parental gate in front of every link out, and a stricter review. The app would
pass most of them, but the category is a marketing choice rather than a
consequence of having children use the app, and v1 does not make it.

### The order of it all, for a first release

1. Fill in `REVIEW_PHONE_TODO`, and enable GitHub Pages.
2. `tools/testflight.sh` — the same binary serves TestFlight and the store, and
   uploading it first means the build is processed by the time the listing is
   ready.
3. `tools/screenshots.sh`, then look at what it produced.
4. `tools/appstore.sh` — creates the version, declares content rights, pushes the
   listing, uploads the screenshots, attaches the build.
5. Set the price to Free, answer App Privacy, and run
   `tools/appstore.sh --age-rating`.
6. `tools/appstore.sh --status`, and read it.
7. `tools/appstore.sh --submit`.

Steps 2 to 6 are safe to repeat. Only the last one queues anything.

## First-time setup of the hosted project

Enable **Authentication → Sign In / Providers → Anonymous sign-ins**. Without it every
device fails at first launch with "Can't reach the server".

## If the app says "Can't reach the server"

Free Supabase projects pause after roughly 7 days with no API activity. Open the
dashboard and resume the project; no data is lost. This is expected after a holiday.
