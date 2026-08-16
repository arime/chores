# Parent Sign In with Apple — Design

**Date:** 2026-08-16
**Status:** Approved design, ready for implementation planning
**Supersedes:** the "Sign in with Apple" line in the v1 out-of-scope list of
`2026-08-10-household-chores-app-design.md`

## 1. Purpose

A parent's place in their family currently survives only as an anonymous Supabase session in
the device keychain. Lose the device, delete the app, or have the auth table rebuilt, and the
family is unreachable — there is no credential anywhere that can prove who they were. The
`LostSessionView` screen exists solely to apologise for this.

Parents will sign in with Apple. Their family then hangs off an Apple ID rather than off a
keychain entry, so a reinstall restores it with no code, no support, and no data loss.

Children are deliberately unchanged in how they *join*. They have no Apple ID to sign in with, the
claim-code mechanism already works, and a child device stays anonymous.

They are changing in one respect. Today a child cannot be removed from a family at all — there is
no delete, and no archive flag either, despite what the grants migration's comment claims. Adding
a parent's ability to delete their own profile would otherwise ship an odd asymmetry: parents can
leave, children are permanent. Since the `completed_by` work below is most of the groundwork, this
design closes both gaps at once. Deleting a child removes their completion history with them, by
intent.

## 2. Decisions

Recorded because each closes off an approach that would otherwise look reasonable later.

| Question | Decision |
|---|---|
| Migrate existing anonymous families? | **No.** Nothing has shipped; hosted data is disposable. Apple sign-in is the only way to be a parent. |
| How does a second parent join? | **Apple sign-in, then the existing claim code.** `claim_profile` already binds whatever `auth.uid()` is. |
| First screen | **Two doors.** "I'm a parent" resolves after sign-in; "I have a code" stays the child's door. |
| Escape hatch for a parent | **"Leave this family"** deletes their profile outright — no ghost seat; deletes the family if no other parent remains. |
| What happens to what they recorded? | **Kept.** `completions.completed_by` becomes nullable `on delete set null`, so a child's history survives a parent leaving. |
| When is an identity acquired? | **On demand.** No session at launch; each door acquires the identity it needs. |
| Account deletion | **Required.** App Review 5.1.1(v) applies once accounts exist. |
| Removing a child | **Hard delete, history included.** Chosen over an `is_archived` flag: archiving keeps rows a parent asked to be rid of and puts a filter in every profile query. |

### Identity on demand

`signInAnonymouslyIfNeeded()` currently runs unconditionally in `SessionViewModel.start()`,
before anyone has said who they are. That has to stop: it would leave an orphaned anonymous
`auth.users` row on every parent device, and it would make the database rule below a race
against whichever session happened to be current.

The two rejected alternatives, for the record: swapping an anonymous session for an Apple one
leaves that orphan behind; `linkIdentity` avoids the orphan but is only worth its cost when
anonymous families must be preserved, and on iOS it drags in a web redirect flow that the
native path avoids entirely.

## 3. Identity model

**A parent profile may only ever be bound to a non-anonymous auth user.** A child profile may
be bound to either, and in practice is always anonymous.

This is cheap to enforce because the schema is already closed. `profiles.auth_user_id` can only
be written in two places — `create_family()` and `claim_profile()`, both `SECURITY DEFINER` —
because the `profiles_insert` policy requires `auth_user_id is null` and the
`prevent_auth_user_id_change` trigger blocks every direct `UPDATE` outside its opt-in window.
Guarding those two functions guards the whole model.

Supabase puts an `is_anonymous` claim in every JWT (verified against the local stack: `true`
for an anonymous session, `false` for a password session), so the distinction is visible inside
Postgres.

## 4. Database changes

One migration.

```sql
create function public.is_anonymous_caller() returns boolean
  language sql stable
  as $$ select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) $$;
```

- **`create_family`** rejects an anonymous caller. A child device cannot bootstrap a family even
  if the UI is bypassed.
- **`claim_profile`** rejects an anonymous caller when the code's target profile has
  `role = 'parent'`. Child codes remain claimable anonymously.
- **`leave_family()`** (new) deletes the caller's profile outright, so no ghost seat is left in
  People. If no other parent profile remains in the family, it deletes the family instead and
  lets the existing `on delete cascade` clear profiles, chores, schedule entries, completions and
  claim codes. Because it is `SECURITY DEFINER`, the deletion happens inside the RPC and the
  client still has no `DELETE` grant on `profiles` — the "never removed by a client" property in
  the grants migration holds.
- **`completions.completed_by`** becomes nullable and its foreign key becomes
  `on delete set null`:

  ```sql
  alter table public.completions alter column completed_by drop not null;
  alter table public.completions drop constraint completions_completed_by_fkey;
  alter table public.completions add constraint completions_completed_by_fkey
    foreign key (completed_by) references public.profiles(id) on delete set null;
  ```

  Without this, deleting a departing parent would cascade away every completion that parent had
  ticked off on a child's behalf — the feature added in `60ac940` and `1e5ce91` — silently
  erasing part of the children's history. Null now means "recorded by someone no longer in the
  family", which is the truth. The other three foreign keys into `profiles`
  (`claim_codes.profile_id`, `schedule_entries.profile_id`, `completions.profile_id`) keep
  cascading: for a departing parent they hold nothing worth saving, and for a departing *child*
  cascading is correct.
- **`delete_account()`** (new) performs `leave_family()`'s logic, then
  `delete from auth.users where id = auth.uid()`. `SECURITY DEFINER` owned by `postgres`, which
  holds the necessary privilege on the `auth` schema.
- **`delete_child(p_profile_id uuid)`** (new) deletes a child's profile. It requires
  `is_parent()`, requires the target to be in the caller's family, and refuses a target whose
  `role` is not `'child'` — removing another *parent* stays out of scope, so this cannot be the
  tool for it. The cascades do the rest, and every one of them is wanted here: the child's
  `schedule_entries`, their `claim_codes`, and their `completions` via `completions.profile_id`.

  A child can only ever be `completed_by` themselves — the `completions_insert` policy allows
  `is_parent() or profile_id = current_profile_id()` — so the new `set null` behaviour on
  `completed_by` never leaves a stray row behind when a child goes. It exists for departing
  parents only.

  Note for whoever reads `20260813120000_table_grants.sql` later: its comment says *"No DELETE: a
  profile is archived by the parent, never removed."* The absence of the grant is still correct —
  clients never delete profiles, the `SECURITY DEFINER` RPC does — but the stated reason is not,
  and archiving never existed. The new migration should say so rather than the applied one being
  edited.
**`app.allow_claim` keeps its name.** An earlier draft renamed it, because leaving was going to
unbind `auth_user_id` and the name would have covered two operations. Deleting the profile
instead means nothing ever unbinds: `claim_profile` remains the only writer of `auth_user_id`,
so the existing name stays exactly accurate and the trigger is untouched.

No RLS policy changes. `prevent_auth_user_id_change` and the three RLS helpers are otherwise
untouched.

## 5. The ChoresCore boundary

```swift
public enum DeviceIdentity: Equatable, Sendable {
    case none       // no session; show the two doors
    case anonymous  // a child device
    case signedIn   // a parent
}
```

`.signedIn` is derived from the JWT's `is_anonymous` claim, not from the provider — Apple is
currently the only way for a person to obtain such a session, but the rule and the name are about
durability of identity rather than about Apple. This is what lets the integration tests stand an
email user in for a parent without the type lying about what it holds.

```swift

// MARK: Session
func currentIdentity() async throws -> DeviceIdentity
func signInAnonymously() async throws                              // was signInAnonymouslyIfNeeded
func signInWithApple(idToken: String, nonce: String) async throws
func signOut() async throws
func leaveFamily() async throws
func deleteAccount() async throws

// MARK: People
func deleteChild(profileID: UUID) async throws
```

`currentProfile()`, `createFamily` and `claimProfile` are unchanged.

`Completion.completedBy` becomes `UUID?`, following the column — and *only* there. The write path
keeps `UUID`: `ChoresBackend.complete(...)`, `OutboxOperation.complete` and the insert payload all
run at a moment when the actor is known by definition. Null is a fact that can only arrive from
the database, so optionality belongs to the read model alone. Nothing in the app reads
`completedBy` back for display either, so there are no view changes.

**Apple stays out of `ChoresCore`.** `ASAuthorizationAppleIDProvider`, the nonce, and SwiftUI's
`SignInWithAppleButton` live in the app target; the core receives an already-obtained token and
passes it to `signInWithIdToken`. This preserves the property the protocol's own doc comment
claims — view models depend on this and never on Supabase or Apple types — and keeps every view
model testable in-process.

`SessionState` gains two cases and loses an assumption:

```swift
case signedOut            // new — no identity yet
case parentWithoutFamily  // new — Apple session, no profile
case unclaimed            // now specifically an anonymous device awaiting a code
```

`.parent`, `.child`, `.unreachable` and `.failed` are unchanged.

**The disowned-session recovery evolves.** `signInAnonymouslyIfNeeded` currently reacts to a
session the server disowns by silently minting a new anonymous one. That is wrong for a parent,
who cannot be silently re-authenticated against Apple. The detection moves into
`currentIdentity()` and the response becomes: clear the dead session, report `.none`. The child
lands on the code screen, the parent on the sign-in button, and a hidden write disappears.

## 6. App flow

| State | Screen |
|---|---|
| `.loading` | `ProgressView` |
| `.signedOut` | `OnboardingView` — two doors, unchanged |
| `.parentWithoutFamily` | new — "Start a family" / "I have a code" |
| `.unclaimed` | `ClaimCodeView` if never claimed, else `LostSessionView` |
| `.parent` / `.child` | as today |
| `.unreachable` / `.failed` | as today |

**Parent door:** "I'm a parent" pushes a screen carrying `SignInWithAppleButton`. On success the
app calls `signInWithApple` and refreshes. A returning parent lands straight in their family —
that is the entire reinstall story. A new one gets `.parentWithoutFamily`, which reuses the
existing `CreateFamilyView` and `ClaimCodeView`.

**Child door** keeps today's navigation. `ClaimCodeView` needs one targeted change: sign in
anonymously **only when `currentIdentity()` is `.none`**, since an already-signed-in second
parent now reaches the same screen.

**`LostSessionView` improves.** Its "Set up as a new family" button would now fail outright — the
database refuses anonymous callers — so it becomes "I'm a parent — sign in", leading to the same
Apple flow. A child can no longer start a family by accident, and a parent whose family really is
gone still has a way out.

**Manage** gains three actions, in ascending order of consequence: **Sign out** (clears the
session, keeps the profile — also the only way to hand a device to the other parent),
**Leave this family**, and **Delete account**. Each confirms; the last two warn differently when
the caller is the last parent.

**People** gains **Delete** on a child, with the bluntest confirmation in the app, because it is
the only irreversible action that destroys someone *else's* data. The wording must name what goes
rather than gesture at it — the child, their place in the schedule, and everything they have ever
ticked off — since "are you sure?" invites a reflex yes. No count is shown: `FamilySnapshot`
carries only the current week's completions, and fetching a lifetime total purely to populate a
warning is not worth a round trip. Parents get no Delete here; removing another parent stays out
of scope, and each parent leaves under their own account.

**Apple's name and email are deliberately ignored.** Apple returns them only on the first
authorization for a given Apple ID, ever — after a reinstall they come back nil, and apps that
persisted them from that single payload fail in ways that are miserable to debug.
`CreateFamilyView` already asks the parent for their name.

## 7. Testing

**pgTAP** is where enforcement is proven, since the rules live in the RPCs. The suite's helper
sets `request.jwt.claims` to `{sub, role}` only, so it needs
`tests.auth_as(p_uid uuid, p_anonymous boolean default false)` — the default keeps all fifteen
existing assertions passing untouched. New assertions: anonymous cannot `create_family`;
non-anonymous can; anonymous cannot claim a parent code but can claim a child code;
`leave_family` deletes the caller's profile; it deletes the family when no other parent remains
and preserves it when one does; **a completion the departing parent recorded on a child's behalf
survives with `completed_by` null** — the regression test for the cascade trap, and the one most
worth writing first; `delete_account` removes the `auth.users` row. The existing "auth_user_id
cannot be bound by a direct update" test must still pass — it is what proves the RPCs are the
only door.

For `delete_child`: a parent can delete a child in their own family, and the child's completions,
schedule entries and claim codes go with them; a parent cannot delete a child in another family;
a parent cannot use it to delete a parent; a child cannot use it at all. Assert too that deleting
a child leaves *other* children's completions untouched — the cascade is scoped by
`completions.profile_id`, and a mistake there would be silent.

**Unit tests** cover the new `SessionState` mapping against `InMemoryChoresBackend`, which gains
identity modelling and fakes for the new calls: `.signedOut` with no identity,
`.parentWithoutFamily` with an Apple identity and no profile, `.unclaimed` with an anonymous one,
and a disowned session reporting `.signedOut`.

**Integration tests** cannot mint an Apple identity token. But the database rule is about
`is_anonymous`, not about Apple, so an email user is a faithful stand-in at exactly the level the
rule operates. The suite already holds the service-role key and already reads and writes
`EphemeralStorage` directly, so it can create a confirmed email user, obtain a session over HTTP,
and pre-seed storage with it — the backend then behaves as a signed-in parent against the real
server with no test-only method added to the production protocol. Covers `createFamily`, the
parent claim code, `leave_family` and `delete_account`. Plus the cheap one: an anonymous session
calling `createFamily` must now fail.

**UI tests** are where this bites hardest. Every parent test currently walks through onboarding
into `CreateFamilyView`, and that path now starts at a system Apple sheet that XCTest cannot
drive. The sign-in screen therefore takes its token source as a dependency — the real Apple
button in production, a stub the fake backend satisfies under `-ui-testing`. Injection rather
than an `if isUITesting` inside the view, so both the two-door screen and the parent flow stay
covered instead of being skipped.

**Known gap:** Apple's actual token exchange gets no automated coverage at any layer. It needs a
manual pass on a real device — first sign-in, force-quit and relaunch, then delete and reinstall
to confirm the family returns. This belongs in `RELEASING.md` as a pre-TestFlight check.

## 8. Configuration

Manual setup, none of it in code:

1. **Xcode** — add the Sign In with Apple capability to the Chores target. This creates the
   project's first `.entitlements` file, sets `CODE_SIGN_ENTITLEMENTS`, and regenerates the
   provisioning profile with the capability attached.
2. **Supabase hosted** — Authentication → Providers → Apple → enable, Client IDs
   `com.metsahalme.Chores`. The Secret Key fields serve the OAuth *web* flow and are not needed:
   native `signInWithIdToken` requires only the client ID, so the server can validate the token's
   `aud` claim. Anonymous sign-ins stay enabled; children depend on them.
3. **Local** — `[auth.external.apple]` in `supabase/config.toml`: `enabled = true`,
   `client_id = "com.metsahalme.Chores"`. Its `secret = "env(SUPABASE_AUTH_EXTERNAL_APPLE_SECRET)"`
   line points at a variable that will never be set and may need emptying for the stack to start.

## 9. Out of scope

- Any other sign-in provider. Apple is the only one, so Apple's equivalence requirement for
  third-party sign-in does not arise.
- Children signing in at all.
- One Apple ID belonging to more than one family. `profiles.auth_user_id` is `unique`, and
  "Leave this family" is the supported way to move.
- Transferring family ownership, or a parent removing another parent. `delete_child` refuses a
  parent target specifically so it cannot become that tool by accident.
- Recovering a child's device without a code.
- Undo for a deleted child. The deletion is immediate and total; the confirmation dialog is the
  only safeguard, which is why its wording is part of this design rather than left to the
  implementation.
- Archiving anything. Considered for both departing parents and removed children, and rejected
  both times: it retains rows someone asked to be rid of and adds a filter to every profile query
  that will eventually be forgotten in one place.
