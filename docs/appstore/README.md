# The App Store listing

Everything App Store Connect shows on the product page, kept here so that it is
reviewable, diffable, and pushed by `tools/appstore.sh` rather than typed into a
web form twice — once per language.

    tools/appstore.sh --status      # what App Store Connect has now
    tools/appstore.sh               # push all of this, attach the newest build
    tools/appstore.sh --submit      # the same, then submit for review

One directory per App Store locale. Adding a language to the listing is adding a
directory and its files, and adding the locale to `LOCALES` in
`tools/appstore.sh`.

## Per-locale files

| File | Where it lands | Limit |
|---|---|---|
| `subtitle.txt` | under the app's name on the product page | 30 characters |
| `description.txt` | the product page body | 4000 |
| `keywords.txt` | search terms, comma separated, never shown | 100 |
| `promotional-text.txt` | above the description; editable without a new version | 170 |
| `whats-new.txt` | the release notes for this version | 4000 |
| `support-url.txt` | the Support link on the product page | — |
| `marketing-url.txt` | the developer's own page for the app | — |
| `privacy-url.txt` | the Privacy Policy link | — |

The limits are checked before anything is sent. Apple counts characters, not
bytes, and a trailing newline counts — the script strips one, so these files can
end the way every other text file does.

The three URLs point at `docs/site/`, which `.github/workflows/pages.yml`
publishes to GitHub Pages. They are localized: Finnish readers get the Finnish
page. `tools/appstore.sh` fetches each one before pushing metadata, because an
unreachable privacy policy is a rejection whose message mentions neither Pages
nor this file.

## Shared files

- **`listing.json`** — copyright, the two categories, release type, the
  third-party content declaration, and the contact details App Review uses if
  they need to ask something. `releaseType: MANUAL` means an approved version
  waits to be released by hand; `AFTER_APPROVAL` puts it on the store the moment
  it passes.
- **`review-notes.txt`** — what App Review needs to know that the app cannot tell
  them. Mostly: any Apple ID works, no demo account exists, and how to reach the
  child's side of the app on a single device, which otherwise takes two.
- **`age-rating.json`** — the questionnaire, all of it declaring nothing, which
  rates the app 4+. Applied only by `tools/appstore.sh --age-rating`, and only
  needed once per app. It is separate because Apple has revised the
  questionnaire more than once: if a field name has changed, the error names it
  and nothing else is affected.

## What is not here

**The app's name.** It was reserved by hand, it has to be unique across the
store, and a script overwriting it is a rename nobody asked for.
`tools/appstore.sh --status` prints what App Store Connect has.

**The screenshots.** They are generated — `tools/screenshots.sh` — and land in
`build/screenshots/<locale>/`, which is not in git. Pictures of a fixture are
reproducible from the fixture; a PNG in a repository is a thing nobody can
diff and nobody dares regenerate.

**The App Privacy answers.** Apple has no public API for the data-collection
questionnaire, so it stays a web task. `docs/RELEASING.md` lists exactly what to
answer, and why each answer has to agree with `App/Chores/PrivacyInfo.xcprivacy`.

**The price.** Free, set once in Pricing and Availability. A submission with no
price schedule is refused, and the API for one is price points and territories —
too much plumbing for a decision that will never change.
