# Setup and development

[← Back to FlightDeck](../README.md)

Commands use paths relative to the repository root unless a section says to run them from `server/`. For a product overview and screenshots, see the [README](../README.md).

## Run your server

Install Python 3.11 or newer, then from `server/`:

```sh
python -m venv .venv
# macOS / Linux:
source .venv/bin/activate
# Windows PowerShell instead:
# .\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.lock
python -m flightdeck configure
python -m flightdeck run
```

The configurator writes an ignored `.env`, prepares the account database, and generates `secrets/master.key`. It does not request a provider API key: each user supplies their own through the app after registering. Back up the master key separately and securely. Missing/wrong keys with existing encrypted credentials fail closed.

The default live server allows registration. Set `FLIGHTDECK_REGISTRATION_OPEN=false` to close registration while allowing existing users to sign in. Use separate account databases for demo and live server modes. Each account has the same configured safety ceiling, initially $4.50/month; `FLIGHTDECK_BUDGET_USD` can lower this ceiling, never raise it. Key replacement/removal never resets usage.

The server listens at `127.0.0.1:8787`. Point a dedicated HTTPS reverse-proxy hostname to it. Preserve the Authorization header and HTTP methods, avoid redirects, and never expose the checkout, `.env`, `data` or `secrets` as static files. The shipped runner uses one worker and disables access logging and forwarded-header trust.

### This media server: HTTPS under `/flights`

The deployment in `C:\Users\neogu\media` uses the existing Caddy reverse proxy
and public HTTPS relay. Enter `https://158.180.55.241:8080/flights` in the app.
The client must include the base-path support in `APIClient.swift` from this checkout.

The `flightdeck` Compose service builds `server/Dockerfile`, runs one unprivileged
worker in live mode and restarts automatically. Port 8787 is internal to Docker.
Caddy strips `/flights` before proxying API requests, preserving methods and
Authorization headers. `/flights` returns server discovery without a redirect;
`/flights/health` and `/flights/v1/server` provide health and protocol checks.

The named volume `media_flightdeck-data` stores the account database, user data
and `/data/secrets/master.key`. Preserve the volume across image rebuilds;
back up the complete data and master key securely. Never remove this volume
when updating. Registration is enabled; create your account in the app and add
your own AeroAPI key there. No provider key is needed to start the server.

From the media workspace, build and deploy only this service, then validate and
reload the existing Docker proxy:

```powershell
docker compose build flightdeck
docker compose up -d --no-deps flightdeck
docker exec media-reverse-proxy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec media-reverse-proxy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
```

### Windows service

From an administrator PowerShell in `server/`:

```powershell
.\scripts\install-windows.ps1
```

The installer prepares Python dependencies, prompts for configuration, protects data and encryption-key permissions, downloads a pinned/hash-verified WinSW release, and installs an automatically starting LocalService service. It leaves your reverse proxy, certificates and firewall configuration to you. It has not been exercised on the user's Windows server.

### Account recovery

A server administrator can reset a user's password and revoke all their sessions:

```powershell
python -m flightdeck reset-password --username alice
```

There is no email-based reset service in this version. Users authenticate to the server they chose, not to a global FlightDeck account.

### Upgrading the shared-token prototype

Version 0.2 replaces the shared connection token and global provider key. Back up the old `.env` and database. Configure a new account database; the configurator uses `data/live-accounts.sqlite3` rather than the prototype's shared file. The old token and global key are not accepted as user credentials. The app's old unscoped cache is not imported into another account.

Nonempty legacy shared databases fail closed rather than being assigned to the first new user. Existing live data requires an explicit administrator migration preserving ownership and **the complete spending ledger**; do not reset billed usage by switching to a fresh database. See [migration and recovery notes](../server/SECURITY.md).

## Run the app

1. Open `app/FlightDeck.xcodeproj` in Xcode and run on an iPhone simulator. The start page offers server connection and a secondary **Explore the demo** option.
2. For a physical phone, choose your authorized development team. The project does not provision a developer account or configure push.
3. On the start page, enter your HTTPS server URL and connect. From demo **Settings**, **Connect to a server** returns to this page.
4. Register a server account or sign in. New live accounts are then prompted to add an AeroAPI key, with links and instructions.
5. Add your flights and check **Usage** for that account's budget and history.

For a private CA/self-signed setup, the hostname-matching server certificate must be trusted on the iPhone. The app uses normal system TLS validation and never accepts arbitrary certificates. HTTP is supported only for localhost development. Development simulator builds need local signing for Keychain access; no paid Apple certificate is required for ad-hoc simulator signing.

### Servers behind a path prefix

Addresses such as `https://server.example.com:8080/flights` are supported, with or without the trailing slash. An address without a scheme defaults to HTTPS. Every API request preserves the port and path: discovery uses `/flights/v1/server`, login uses `/flights/v1/auth/login`, and subsequent account requests use the same prefix.

Configure the reverse proxy to strip the external `/flights` prefix before forwarding to the backend: `/flights/v1/server` must reach `/v1/server` on `127.0.0.1:8787`. Preserve query strings, Authorization headers, request bodies and HTTP methods, and forward directly without redirects. The Python server's own routes remain rooted at `/v1/`. When connecting by IP over HTTPS, the certificate must cover that IP address and be trusted on the phone.

## iOS calendar import

Open **Settings → Calendar import**, allow calendar access, and select calendars. Google calendars must be synced with iOS Calendar; installing only the Google Calendar app does not expose its calendars through EventKit. iOS 17 requires full calendar access to read events. FlightDeck never writes, edits or deletes calendar events.

- **Automatically suggest flights** is off by default. When enabled, the app scans at launch/foreground and while active, including after calendar-change notifications. Suggestions appear as a review banner on Trips. It does not run a server calendar connection, background scheduler or push notification service.
- **Search calendars now** performs a manual search regardless of the automatic setting. Both paths examine the next 180 days, including flights already in progress, and exclude cancelled/all-day events, completed flights, already tracked flights, and dismissed suggestions.
- Titles such as `Flight to Frankfurt (LH 1189)` are recognized case-insensitively. Flight numbers are normalized; departure dates use the event timezone, falling back to the phone timezone for events without one. The review shows calendar times and the timezone used.
- New flights form a connected trip if the next departure is at or after the previous arrival and strictly less than 12 hours later. Overlapping flights and a gap of exactly 12 hours remain separate. Groups are limited to eight legs, matching the server limit. This uses calendar timing as a heuristic, without confirming airport continuity.
- Review and add a connected trip, a single flight, or all suggested journeys. **Dismiss** remembers the normalized flight numbers and departure dates in that suggestion. Both automatic and manual searches respect dismissals across app restarts. **Later** keeps suggestions for review. **Reset dismissed suggestions** makes them eligible again. Import buttons immediately change to an animated plane and **Adding…** label; other import/dismiss actions remain disabled until the request finishes.
- Calendar selection, automatic-scan preference and hashed dismissal identities stay on the device and are partitioned by server/account; demo preferences are separate. Source event titles, calendar names, descriptions and source event identifiers are not sent to the server. Accepting a suggestion sends only the flight numbers, departure dates, offset-aware calendar flight times, timezone identifier and an opaque import identity.
- Importing does not rearrange existing trips or automatically edit/delete already tracked flights after a calendar change. Imported calendar times are user-provided itinerary data. AeroAPI still supplies flight status, routes and aircraft data under the existing budget gate.

The server atomically deduplicates imports per authenticated account by import identity and flight number/date. Retrying an accepted import does not create another trip or purchase more provider calls. Calendar scanning itself makes no AeroAPI calls; accepting new flights invokes normal budgeted enrichment.

Calendar detection, refusal persistence, connection grouping, manual search and import/restart behavior are tested with synthetic calendar events on a separate simulator. Real Google-to-iOS sync, event timezones and permission behavior remain to be exercised on the physical phone after deployment.

## Flight data and history

The connector uses `/schedules/{date_start}/{date_end}` for published schedules ahead of the live window, `/airports/{id}` for verified airport timezones/names, and `/flights/{ident}` for live status within approximately 48 hours of departure. Schedule queries require both an airline and a flight-number filter and never paginate. It does not buy historical endpoints. The app asks for a flight number and departure date, and derives the route from one matching occurrence. Ambiguous results stay unresolved instead of guessing. Dates are departure-airport local dates; times are displayed in each airport's timezone. Optional airport filters remain supported by the API for older clients.

Schedule lookups use the same per-account spending gate: a schedule reserves $0.04 and each uncached airport metadata lookup reserves $0.03, twice their reviewed published prices. A cold schedule with two airports reserves $0.10; repeated automatic polling uses cached data. As departure enters the live window, live lookup takes precedence even if the schedule cache is still fresh. A missing live occurrence can fall back to a published schedule, which supplies no confirmed aircraft registration, incoming-flight assignment, or live on-time status. Lookup failures persist on the saved flight and remain visible across state reads, throttled refreshes, and server/app restarts.

Incoming links use FlightAware's `inbound_fa_flight_id` and are re-evaluated when aircraft assignments change. The app does not yet predict missed connections. A provider that has not identified an incoming aircraft cannot supply that link.

User-entered flight numbers and dates remain permanently. Raw provider data and normalized live details, including derived airports, expire after 29 days; the new flight form does not ask users to enter routes manually. Legacy user-entered airport codes remain in existing itineraries. Completed flights are not continually refreshed. This journal contains flights users add; it does not import an airline account's complete history.

## API

Public endpoints:

- `GET /health` — minimal health/version.
- `GET /v1/server` — protocol, mode and registration availability.
- `POST /v1/auth/register`, `POST /v1/auth/login` — credentials to a new opaque session.

All other endpoints require `Authorization: Bearer <session-token>` and select the authenticated account automatically:

- `POST /v1/auth/logout`, `POST /v1/auth/logout-all` — revoke sessions.
- `GET /v1/account` — public account metadata, never secrets.
- `PUT /v1/account/api-key`, `DELETE /v1/account/api-key` — configure/remove a provider key. **No read-back endpoint.**
- `GET /v1/state` — account metadata, trips, current usage and refresh issues.
- `GET /v1/usage`, `POST /v1/usage/refresh` — local current/history report, or refresh provider account metering first. The app uses pull-to-refresh for this action. `account_checked_at` is the last successful provider check; `reported_through` is the exact requested reporting cutoff. `pending_estimated_usd` estimates costs for unreconciled requests; `reserved_usd` remains a compatibility alias. See [the budget guide](../server/BUDGET.md) for the ten-minute reporting cadence and additional five-minute buffer.
- `POST /v1/trips`, `DELETE /v1/trips/{id}` — save/remove the user's itinerary.
- `POST /v1/refresh?force=false&trip_id=<optional>` — refresh relevant flights within cache/rate/budget rules.

Interactive API documentation is disabled. Request-validation errors never echo submitted passwords or keys. Sensitive responses are not cacheable.

## Checks

From `server/`:

```sh
python -m pytest -q
```

The tests use provider mocks and fake credentials. To run the native account UI and client integration checks, start the local fixture in another terminal; it accepts only test keys and cannot contact FlightAware:

```sh
cd server
python tests/serve_fixture.py
```

Then from the repository root, with an installed iPhone simulator:

```sh
xcodebuild -project app/FlightDeck.xcodeproj -scheme FlightDeck \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/FlightDeckDerived \
  -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

A temporary DerivedData folder avoids file-provider metadata that can interfere with local code signing. After adding app source files, regenerate the deterministic Xcode project with `python app/generate_project.py`; it does not preserve manual project-file changes.

The Swift integration executable uses the actual native API client and Codable models against that fixture:

```sh
swiftc -parse-as-library app/FlightDeck/Models.swift app/FlightDeck/APIClient.swift \
  app/IntegrationSmoke.swift -o /tmp/flightdeck-smoke
/tmp/flightdeck-smoke
```

The fixture and smoke check exercise both root hosting and `/flights` hosting. URL construction and path-isolation checks also run without a server:

```sh
swiftc -parse-as-library app/FlightDeck/Models.swift app/FlightDeck/APIClient.swift \
  app/APIClientTests.swift -o /tmp/flightdeck-api-url-tests
/tmp/flightdeck-api-url-tests
```

The fixture limits new registrations like the real server; restart it between repeated full test runs. Stop it when finished. Trip status aggregation can be checked separately:

```sh
swiftc app/FlightDeck/Models.swift app/FlightDeck/DemoData.swift \
  app/TripPresentationTests.swift -o /tmp/flightdeck-trip-tests
/tmp/flightdeck-trip-tests
```


Calendar title parsing, date/timezone handling and connection boundaries can be checked without a calendar account:

```sh
swiftc app/FlightDeck/Models.swift app/FlightDeck/CalendarFlightDetection.swift \
  app/CalendarDetectionTests.swift -o /tmp/flightdeck-calendar-tests
/tmp/flightdeck-calendar-tests
```

The native calendar UI test uses `--uitesting-calendar` on a separate test simulator; it never reads real calendar events. The initial `--uitesting-calendar-reset` flag resets only fixture preferences. The test verifies automatic discovery, a two-leg connection, remembered rejection after restart, deduplicated imports, manual rescan and explicit reset of dismissals.

## Launch animation and artwork

The native launch scene runs once per cold app launch. It never delays flight refreshes or calendar scanning, and returning from the background does not replay it. iOS **Reduce Motion** uses a brief logo fade. Backgrounding during launch dismisses the animation. The navy sheet resolves to the measured upcoming-trip or empty-state card; the initial server connection screen uses a fade instead.

The empty Trips screen offers **Add a flight** and **Search calendar**. The latter opens calendar setup until permission and a calendar selection are available, then searches and presents suggestions. History remains in its own tab.

To regenerate the app icon and Departure wordmark on macOS, run `swift app/make_icon.swift` from the repository root. Source artwork and the font license live in `app/FlightDeck/Brand/`. Launch UI tests use only synthetic trips in the test simulator. `--uitesting-launch` enables the animation during tests, `--uitesting-empty` supplies an empty trip list, and the debug-only `--uitesting-launch-frame=<seconds>` freezes a frame for visual inspection. Normal UI tests skip the animation.

## Later additions

User-configurable budget limits, email-based recovery and push delivery are not configured yet. A future scheduled worker and APNs delivery must use the authenticated owner's provider key and the same durable budget gate.
