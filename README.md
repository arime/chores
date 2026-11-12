<p align="center">
  <img src="App/Chores/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="128" height="128" alt="Snappy Chores icon">
</p>

<h1 align="center">Snappy Chores</h1>

<p align="center">A chore chart for one household, on the phones you already have.</p>

A parent keeps the list: who is in the family, what the chores are, and which child does
which on which day. Each child sees only their own chores for today and ticks them off.

## Features

- A repeating weekly schedule, set up once
- A parent sees every child's day and the week at a glance
- A week wrap-up from Sunday evening: each child sees their own week, the parent the whole family's
- Children need no account: a parent adds them by first name and a short code
- An afternoon reminder for the child, and an evening one for the parent
- Works offline and catches up when the connection returns
- English and Finnish
- No ads, no analytics, no tracking, nothing to buy

## Support and privacy

- Help and contact: [arime.github.io/chores/support](https://arime.github.io/chores/support/)
- Privacy policy: [arime.github.io/chores/privacy](https://arime.github.io/chores/privacy/)
- Problems and ideas: email [metsari+chores@proton.me](mailto:metsari+chores@proton.me) or [open an issue](https://github.com/arime/chores/issues)

## For developers

SwiftUI for iPhone on iOS 17 or later, with a Supabase backend (Postgres, row-level
security). Copy `App/Chores/Secrets.swift.example` to `App/Chores/Secrets.swift` and fill
it in before building.

```sh
swift test             # unit tests
supabase test db       # pgTAP tests (needs Docker)
```

The UI tests run from Xcode's `Chores` scheme against an in-memory backend.
Building, releasing and database migrations are covered in
[docs/RELEASING.md](docs/RELEASING.md).

| Folder | Contents |
|---|---|
| `Sources/ChoresCore` | Models, scheduling, offline cache and outbox, view models |
| `App` | The Xcode project: SwiftUI screens and UI tests |
| `supabase` | Migrations, the evening reminder function and pgTAP tests |
| `docs/site` | The support and privacy pages, published to GitHub Pages |

## Contributing

Bug reports and ideas are welcome as [issues](https://github.com/arime/chores/issues).
Pull requests are accepted only from collaborators.

## License

Copyright © 2026 Ari Metsähalme. Licensed under the
[GNU Affero General Public License v3.0](LICENSE).

The name Snappy Chores and the app icon are not covered by the license.
