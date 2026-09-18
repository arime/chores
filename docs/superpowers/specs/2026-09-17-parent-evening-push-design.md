# Parent Evening Push — Design

**Date:** 2026-09-17
**Status:** Designed, not implemented.

## 1. Purpose

A parent wants to know, in the evening, whether any child still has a chore for today
that nobody has ticked off. Today the app tells them nothing unless they open it.

The obvious implementation — a local notification — cannot do this. A local notification
is scheduled ahead and fires blind; nothing runs on the device at 21:00 to ask whether
the chores are done. And the parent's phone would not know anyway: `FamilyStore` is
pull-only (`start()`, `refresh()`, pull-to-refresh), so a chore a child ticked at 20:30
reaches the parent's device only when the parent next opens the app. A locally scheduled
"still undone" reminder would be wrong on most evenings where the children finished after
the parent last looked.

The server knows. It holds the template, the completions and the family's timezone. This
design has it send a push, at the time each parent chooses, only when the family's day is
genuinely unfinished.

## 2. Decisions

| Question | Decision |
|---|---|
| Push, local, or background refresh? | **Push.** The condition depends on other devices' ticks, and only the server sees all of them. Background refresh (`BGAppRefreshTask`) was considered and rejected: its start time is a floor, not a schedule, and a force-quit app never runs it. |
| Direct APNs or a relay (FCM)? | **Direct APNs from an Edge Function.** The Apple account exists already; a relay adds a vendor and a second privacy story for nothing. |
| Where does the logic live? | **SQL.** Which parents are due, what counts as undone, and what prevents a double-send are all `security definer` functions, tested with pgTAP like the RLS already is. The Edge Function is transport. |
| Who is reminded? | **Each parent, at their own time.** `profiles.evening_reminder_at`, default 21:00, `null` = off. Not per family: one parent switching it off must not silence the other. |
| What does it say? | **A count, no names.** "3 chores are still unticked." Nothing identifying transits Apple or lands on a lock screen. |
| Which children count? | **Only `role = 'child'` entries.** A parent who put themselves on the schedule is not in their own reminder. |
| When is a parent due? | **The hour after their configured time**, in the family's timezone, clipped at midnight. The job runs every five minutes, so in practice within five minutes of the time. |
| Retry after a failed send? | **No.** Claim before send; a failure is recorded and visible, never retried that evening. One visible failure beats two arrivals. |
| Localization | **On the device.** The payload carries `loc-key`s and a number; `Localizable.xcstrings` renders Finnish or English. The server chooses between a singular and a plural key because `loc-args` are strings. |
| Do children register a token? | **No.** Children's devices register nothing; the privacy story stays "children have no accounts and no identifiers". |
| Log retention | **None in v1.** One row per parent per evening. |

## 3. Shared foundation

These pieces are needed by this design and by the child reminders design
(`2026-09-17-child-reminders-design.md`). They are specified here and built first.

### 3.1 Columns on `profiles`

```sql
alter table public.profiles
  add column afternoon_reminder_at time,
  add column evening_reminder_at   time;
```

Both nullable; `null` means off. Meaning depends on role:

| Role | `afternoon_reminder_at` | `evening_reminder_at` |
|---|---|---|
| child | local heads-up (child spec) | local nag (child spec) |
| parent | ignored | the push in this design |

A `before insert` trigger fills role-based defaults when a column is `null` at insert:
parents get evening 21:00 and afternoon `null`; children get 15:00 and 20:00. The same
migration backfills existing rows by role. Consequence, accepted: a profile is created
with reminders on and switched off afterwards — there is no way to create one with them
off, which removes the ambiguity between "not provided" and "off".

No RLS change: `profiles_update` already lets a parent update any profile in the family,
including their own. `security definer` functions bypass RLS anyway.

### 3.2 `TimeOfDay` in `ChoresCore`

```swift
public struct TimeOfDay: Codable, Hashable, Sendable {
    public var hour: Int      // 0...23
    public var minute: Int    // 0...59
}
```

Encodes to `"HH:MM:SS"`, which is what Postgres `time` returns and accepts; decodes
`"HH:MM"` too. `Profile` gains `afternoonReminderAt: TimeOfDay?` and
`eveningReminderAt: TimeOfDay?`, keyed `afternoon_reminder_at` / `evening_reminder_at`.

`SupabaseChoresBackend.updateProfile` extends its `ProfileUpdate` payload with both
fields. **`nil` must be encoded as an explicit JSON `null`**, not omitted — omitting it
would make "turn off" a no-op. `InMemoryChoresBackend` stores the fields.

### 3.3 A reusable time control

One SwiftUI component: an on/off toggle and, when on, an hour-and-minute picker bound to
a `TimeOfDay?`. This design uses it once (§7.4); the child design uses it twice.

## 4. Data

### 4.1 `device_tokens`

```sql
create table public.device_tokens (
  token       text primary key,
  family_id   uuid not null references public.families(id) on delete cascade,
  profile_id  uuid not null references public.profiles(id) on delete cascade,
  environment text not null check (environment in ('development', 'production')),
  updated_at  timestamptz not null default now()
);
create index device_tokens_profile_idx on public.device_tokens(profile_id);
```

`token` is the APNs device token, hex. It is the primary key on purpose: a token
identifies a device+app, so when a device changes hands the upsert moves the row instead
of leaving a stale one pointing at the previous parent. `environment` records whether the
build that registered was a debug build (Apple's sandbox gateway) or a TestFlight/App
Store build (production); a token is valid on exactly one.

Clients never write this table directly. A token proves possession of a phone, and the
row has to follow the phone: if parent A signed out uncleanly and parent B signs in on
the same device, B's registration must take the row over, which a per-row RLS policy
would refuse. So writes go through two `security definer` RPCs for `authenticated`
callers, each guarded by `is_parent()` (raising `P0005` like the other parent-only
guards):

- `device_token_register(p_token text, p_environment text)` — upserts the row for the
  caller's own profile and family, overwriting whoever held the token before.
- `device_token_forget(p_token text)` — deletes the row **only if it is the caller's**,
  so a late forget from the previous holder cannot remove the new holder's registration.

RLS: `select` only, `profile_id = public.current_profile_id()` — a parent sees their own
rows, a child none, nobody sees anyone else's. Grant `select` to `authenticated`, nothing
more; the rest is the RPCs.

### 4.2 `evening_reminder_sends`

```sql
create table public.evening_reminder_sends (
  profile_id   uuid not null references public.profiles(id) on delete cascade,
  local_date   date not null,
  claimed_at   timestamptz not null default now(),
  sent_at      timestamptz,
  undone_count int  not null,
  device_count int  not null,
  failure      text,
  primary key (profile_id, local_date)
);
```

The double-send guard and the only log this feature has. RLS enabled, **no policies** —
clients never read or write it; the two `security definer` RPCs below do. A row with
`sent_at null` and `failure null` is a send still in flight or a function that never
called back; a row with `device_count = 0` is a parent who was due but had no registered
device — the answer to "why didn't I get it".

## 5. The SQL

### 5.1 `evening_reminder_work()`

`security definer`, `set search_path = public`. Execute revoked from `public`, `anon`
and `authenticated`; granted to `service_role`. It runs in one transaction and does two
things.

**Claim.** For every parent profile `p` in family `f` such that

- `p.evening_reminder_at is not null`
- with `local_now = now() at time zone f.timezone` and `local_date = local_now::date`,
  `local_now >= local_date + p.evening_reminder_at` and
  `local_now < local_date + p.evening_reminder_at + interval '1 hour'` — the hour after
  the configured time, computed on timestamps so a 23:30 setting gets a window clipped at
  midnight rather than one that wraps
- no row exists in `evening_reminder_sends` for `(p.id, local_date)`
- `undone(f, local_date) > 0`

insert `(p.id, local_date, undone_count, device_count)` with `sent_at null`.

**Return.** One row per `device_tokens` row belonging to a profile claimed in this call:
`profile_id, local_date, undone_count, token, environment`. A claimed parent with no
devices contributes nothing to the result and keeps their `device_count = 0` row.

`undone(f, d)` is its own function, `family_undone_count(p_family_id uuid, p_date date)`,
same privileges as the rest, so pgTAP can test the rule directly and the child design can
reuse it if it ever moves to push. It counts `schedule_entries` rows in family `f` for
`extract(isodow from d)` whose chore is not archived, whose profile has `role = 'child'`,
and with no `completions` row for `(profile_id, chore_id, due_on = d)`. A left anti-join
on the existing `(profile_id, chore_id, due_on)` uniqueness and the `(family_id, due_on)`
index; no new columns.

Claiming before sending is the deliberate trade. A second job tick arriving while Apple is
slow sees the claims and returns nothing, so a double-send is impossible. The cost is that
a send which fails after the claim is not retried that evening; it sits in the table with
`failure` set.

### 5.2 `evening_reminder_record(p_profile_id uuid, p_local_date date, p_sent_at timestamptz, p_failure text)`

Updates the claim row. Same privileges as 5.1.

### 5.3 `device_tokens_forget(p_tokens text[])`

Deletes those rows. Same privileges. Called for tokens Apple reports dead; without it, dead
tokens accumulate forever and every evening pays for them.

### 5.4 The job

`create extension if not exists pg_cron;` and `pg_net` in the migration. Then:

```sql
select cron.schedule('evening-reminder', '*/5 * * * *', $$
  with work as materialized (select * from public.evening_reminder_work())
  select net.http_post(
    url     := (select decrypted_secret from vault.decrypted_secrets
                where name = 'evening_reminder_url'),
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || (select decrypted_secret
                    from vault.decrypted_secrets where name = 'evening_reminder_secret')),
    body    := jsonb_build_object('work', (select jsonb_agg(to_jsonb(w)) from work w)))
  where exists (select 1 from work);
$$);
```

`materialized` because `work()` has side effects and is referenced twice; it must run
once. Most ticks find no work and stop at the query — the function is invoked only when
there is something to send. The URL and bearer secret come from Supabase Vault at run
time, so the migration holds nothing sensitive and works locally and hosted alike. Seeding
the two Vault entries is a once-per-project step (§8).

## 6. The Edge Function

`supabase/functions/evening-reminder/index.ts`, Deno. `verify_jwt = false`: the caller is
`pg_net`, authenticated by our own bearer secret, not a Supabase user.

**Authentication.** Constant-time compare of the bearer against `EVENING_REMINDER_SECRET`.
Anything else is `401` and nothing happens.

**Input.** `{ work: [{ profile_id, local_date, undone_count, token, environment }] }`.

**APNs token.** An ES256 JWT (`iss` = `APNS_TEAM_ID`, `kid` = `APNS_KEY_ID`, `iat`)
signed with Web Crypto from the `.p8` PEM in `APNS_PRIVATE_KEY`. Cached in module scope
and rebuilt after 50 minutes: Apple honours one for an hour and rate-limits generation.

**Send.** Per row, HTTP/2 `POST https://api.push.apple.com/3/device/{token}` — or
`api.sandbox.push.apple.com` when `environment = 'development'` — with headers
`authorization: bearer …`, `apns-topic: com.metsahalme.Chores`, `apns-push-type: alert`,
`apns-priority: 10`, `apns-expiration: now + 3 h`. The expiry stops a phone that was off
overnight from getting yesterday's reminder at breakfast.

Payload:

```json
{ "aps": { "alert": { "title-loc-key": "EVENING_PUSH_TITLE",
                       "loc-key": "EVENING_PUSH_BODY_MANY",
                       "loc-args": ["3"] },
           "sound": "default" } }
```

`loc-key` is `EVENING_PUSH_BODY_ONE` when `undone_count = 1`, else `_MANY`. The device
resolves the keys from `Localizable.xcstrings` in its own language. Apple sees a token,
three keys and a number.

**Outcomes.** `200` delivered. `400` with reason `BadDeviceToken` and `410` (`Unregistered`)
mean the token is dead. Everything else — `403` (our JWT), `429`, `5xx`, network — is a
failure for that device.

**Callbacks**, with `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` (provided to every
function): `device_tokens_forget(dead tokens)` once, then per `(profile_id, local_date)`
`evening_reminder_record(…, sent_at = now() if any device delivered else null,
failure = null or a one-line summary of statuses)`.

**Secrets**, set with `supabase secrets set`: `EVENING_REMINDER_SECRET`, `APNS_KEY_ID`,
`APNS_TEAM_ID`, `APNS_PRIVATE_KEY`. The `.p8` is an APNs auth key from the Developer
portal (Certificates, Identifiers & Profiles → Keys) — a different key from the App Store
Connect API key in `~/.appstoreconnect/`.

## 7. The app

### 7.1 Registration

- `App/Chores/Chores.entitlements` gains `aps-environment` — Xcode's Push Notifications
  capability writes `development`; the archive export rewrites it to `production`.
- `ChoresApp` gets `@UIApplicationDelegateAdaptor(AppDelegate.self)`. The delegate has one
  job: receive the device token in `didRegisterForRemoteNotificationsWithDeviceToken`,
  hex-encode it, and hand it to `PushRegistration`. `didFailToRegister…` is logged and
  otherwise ignored — a device without push simply gets no reminder.
- `PushRegistration` (`@MainActor`, app target, decision logic in `ChoresCore` as
  `PushRegistrationState` so it is unit-testable) holds the latest token and the current
  parent profile, which arrive in either order. When it has both, it calls
  `backend.registerDeviceToken(_:environment:)`. It re-registers on every parent launch;
  tokens can change and the upsert is cheap. Environment is `development` under
  `#if DEBUG`, else `production`.
- `ParentRootView`'s `.task` requests notification authorization — the kid's
  `ReminderScheduler.requestAuthorization()` moves to a shared `Notifications` enum — then
  calls `UIApplication.shared.registerForRemoteNotifications()`. Both skipped when
  `AppEnvironment.isUITesting`, as the kid side already does.
- `KidRootView` never registers.

### 7.2 Teardown

`ManageView.perform` calls `backend.forgetDeviceToken(token)` **before** the action it
wraps. Order matters: after `signOut()` the RLS identity is gone and the delete would be
refused. Leave-family and delete-account cascade through the FK regardless; sign-out is
the case that needs the explicit delete, or the device keeps receiving a family it no
longer shows.

### 7.3 `ChoresBackend`

Two methods: `registerDeviceToken(_ token: String, environment: PushEnvironment)` and
`forgetDeviceToken(_ token: String)`. The server derives the profile and family from the
caller, so neither is a parameter. Supabase implementation calls the two RPCs in §4.1;
in-memory implementation keeps a token → (profile, family, environment) map keyed by
the session's profile, and cascades it when a profile is deleted.

### 7.4 Settings

A fourth Manage hub row using the existing `HubRow(systemImage:label:meta:)`:
`bell` / "Evening reminder" / `21:00` or "Off". `ManageDestination` gains `.reminder`; the
destination is a small screen with the §3.3 control bound to the parent's own
`eveningReminderAt`, saved through `updateProfile`, with a footnote: *Sent to this phone
at this time when a child still has chores unticked. Off means never.*

### 7.5 Strings

In `Localizable.xcstrings`, English source with Finnish:

| Key | en | fi (proposed) |
|---|---|---|
| `EVENING_PUSH_TITLE` | Chores tonight | Illan tehtävät |
| `EVENING_PUSH_BODY_ONE` | 1 chore is still unticked. | 1 tehtävä on vielä kuittaamatta. |
| `EVENING_PUSH_BODY_MANY` | %@ chores are still unticked. | %@ tehtävää on vielä kuittaamatta. |

plus the settings screen's labels and footnote. The Finnish is a proposal for review.

## 8. Privacy and documents

All in the same version, in this order.

1. `App/Chores/PrivacyInfo.xcprivacy`: add
   `NSPrivacyCollectedDataTypeDeviceID`, linked `true`, tracking `false`, purpose
   `AppFunctionality`, with a comment saying it is the APNs token of a parent's device.
2. `docs/site/privacy/` (en and fi): a paragraph on the push token — what it is, that only
   parents' devices hold one, that it is deleted on sign-out, leaving and account
   deletion, and that the reminder carries a count and no names.
3. App Store Connect → App Privacy: Identifiers → Device ID, collected, linked, not
   tracking, App Functionality. Then **Publish** — `docs/RELEASING.md` already documents
   why the button is the step that bites.
4. `docs/RELEASING.md`: the App Privacy table gains the row and the "no identifiers …
   local notification with no push token" paragraph is rewritten. A new once-per-project
   section: creating the APNs key, `supabase secrets set` for the four secrets, the two
   Vault entries (`evening_reminder_url`, `evening_reminder_secret`), and
   `supabase functions deploy evening-reminder`. `pg_cron` and `pg_net` need no web step;
   the migration enables them.
5. `App/Chores/Kid/ReminderScheduler.swift:5` — "no APNs, no certificates, no push
   tokens" — becomes a statement about the child's side and says so.

## 9. Testing

**pgTAP**, `supabase/tests/02_evening_reminder.sql`:

- due inside the hour after the configured time, in the family's timezone; not due
  before; not due after; `null` never due; a 23:30 setting is due at 23:45 and the window
  ends at midnight
- `family_undone_count` excludes archived chores, excludes `role = 'parent'` entries,
  excludes completed rows, is zero on a weekday with no entries, and counts a chore
  assigned to two children twice
- a second `work()` call in the same window returns nothing and the claim row exists with
  `sent_at null`
- a due parent with no `device_tokens` is claimed with `device_count = 0` and returns no
  rows
- `record()` sets `sent_at` / `failure`; `forget()` deletes exactly the given tokens
- `device_token_register` writes the caller's own row, takes over a token another
  parent held, and refuses a child with `P0005`; `device_token_forget` removes only
  the caller's own row; a parent selects only their own rows and a child none
- the trigger fills `21:00` / `null` for a parent and `15:00` / `20:00` for a child; a
  provided value is kept
- `anon` and `authenticated` cannot execute the three RPCs

**XCTest**, `ChoresCoreTests`: `TimeOfDay` round-trips `"20:00:00"` and accepts `"20:00"`;
`Profile` decodes both new columns and `null`; `PushRegistrationState` registers only when
token and parent profile are both present, in either order, and forgets on teardown —
against `InMemoryChoresBackend`.

**Deno**, `supabase/functions/evening-reminder/index_test.ts`: `_ONE` vs `_MANY` key
selection; which statuses classify a token as dead; JWT claim shape and `kid` header. Run
with one `deno test` command from that directory.

**Manual end to end**, written into RELEASING.md: a debug build on a device registers a
`development` token; `supabase functions serve`; one `curl` with a hand-written work row;
the notification arrives.

## 10. Rollout

1. Migration — run by hand, as all migrations in this project are.
2. Secrets, Vault entries, `functions deploy`. Safe before the app ships: with the trigger
   default every parent is due nightly whenever the day is unfinished, so
   `evening_reminder_sends` gains `device_count = 0` rows each evening — harmless, and
   proof the job runs before a single token exists.
3. App changes into 1.1; TestFlight on a real device exercises the production gateway.
4. Privacy manifest is in the build; App Privacy answers published; site deployed; listing
   texts already committed. `tools/appstore.sh --submit`.

## 11. Out of scope

- Any push to children's devices. See the child reminders design for why local is right
  there.
- Retrying a failed send within the evening.
- Alerting on failures. The table is the log; a later cron query or dashboard can read it.
- Per-device settings. A parent with two phones gets the same reminder on both.

## 12. Risks

- **A second Apple key to protect.** The APNs `.p8` lives in Supabase secrets. If it leaks,
  revoke it in the Developer portal and set a new one; nothing in the database changes.
- **Silent failure remains possible** in one place: if `pg_cron` itself stops, no rows
  appear and nothing says so. Mitigation: the nightly `device_count = 0` rows during
  rollout establish what "working" looks like; their absence is the signal.
- **Debug vs production mismatch.** A Release build run from Xcode with a development
  profile would register a `production` token against the sandbox gateway. Rare, and the
  `400 BadDeviceToken` it produces deletes the token rather than accumulating.
