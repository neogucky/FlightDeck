# FlightDeck

A flight companion that keeps your whole journey, incoming aircraft and flight history together. Native SwiftUI for iPhone, backed by a self-hosted Python account server.

[Overview](previews/overview.png) · [Three flights](previews/overview-three-flights.png) · [Longer trips](previews/overview-long-trip.png) · [Validation](VALIDATION.md)

[Schedule overview](previews/schedule-overview.png) · [Start page](previews/start.png) · [Add flight](previews/add-flight.png) · [Connected flights](previews/add-connected-flights.png) · [Account login](previews/account-login.png) · [API-key setup](previews/api-key-setup.png) · [Usage](previews/usage.png) · [Monthly history](previews/usage-history.png)

## Accounts and flight tracking

- Start on a dedicated connection page. Connect to your own server or one operated by someone you trust, then register or sign in with a username and password. Demo mode is an explicit secondary choice; saved sessions open your flights directly.
- Keep the session in the iPhone Keychain. Sessions last up to 90 days, with sign-out and sign-out-all-devices support.
- Follow the in-app guide to obtain and submit your own FlightAware AeroAPI key. It is verified before saving, encrypted on the server, never returned by the API, and not stored in the app.
- Every account has its own database: flights, incoming-aircraft snapshots, provider cache, spending ledger and request limits. An identical provider key cannot be attached to a different account, even after removal.
- Watch your account's current usage and up to 12 months of history in the **Usage** tab. It distinguishes provider-reported spend, local reservations and the intentionally conservative total. Limits are currently managed in server configuration; per-user limit controls are a later addition.
- Save individual flights or trips with up to eight connected legs, using only flight numbers and departure dates. `LX1055` and `LX 1055` resolve to the same canonical identifier; requests and saved flight labels use `LX1055`. Airports come from matching provider data. The overview displays flight numbers above route arrows for one to three flights; longer journeys use a compact summary.
- See published routes and planned times ahead of departure, then live flight status, aircraft details and a separate incoming-aircraft card per remaining leg as live data becomes available. Schedule-only data is labeled explicitly and never presented as confirmed on-time status.
- Live information refreshes when over 15 minutes old while the app is visible. Advance schedules and airport metadata are cached for 24 hours to conserve the budget. Pull-to-refresh can update a schedule sooner, subject to the 60-second safety cache, rate limits and spending gate.
- Keep manually entered flight history permanently. Provider details expire after 29 days. Device caches are partitioned by server and user and cleared on sign-out.
- Explore a separate local demo without making provider requests. Push notifications and background polling remain deferred.

See [security and account isolation](server/SECURITY.md) and [budget accounting](server/BUDGET.md) for the exact behavior and limits. Write-only API-key setup does not hide a key from the operator of a running server that must decrypt it for provider calls.

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

Nonempty legacy shared databases fail closed rather than being assigned to the first new user. Existing live data requires an explicit administrator migration preserving ownership and **the complete spending ledger**; do not reset billed usage by switching to a fresh database. See [migration and recovery notes](server/SECURITY.md).

## Run the app

1. Open `app/FlightDeck.xcodeproj` in Xcode and run on an iPhone simulator. The start page offers server connection and a secondary **Explore the demo** option.
2. For a physical phone, choose your authorized development team. The project does not provision a developer account or configure push.
3. On the start page, enter your HTTPS server URL and connect. From demo **Settings**, **Connect to a server** returns to this page.
4. Register a server account or sign in. New live accounts are then prompted to add an AeroAPI key, with links and instructions.
5. Add your flights and check **Usage** for that account's budget and history.

For a private CA/self-signed setup, the hostname-matching server certificate must be trusted on the iPhone. The app uses normal system TLS validation and never accepts arbitrary certificates. HTTP is supported only for localhost development. Development simulator builds need local signing for Keychain access; no paid Apple certificate is required for ad-hoc simulator signing.

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
- `GET /v1/usage`, `POST /v1/usage/refresh` — local current/history report, or refresh provider account metering first.
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

The fixture limits new registrations like the real server; restart it between repeated full test runs. Stop it when finished. Trip status aggregation can be checked separately:

```sh
swiftc app/FlightDeck/Models.swift app/FlightDeck/DemoData.swift \
  app/TripPresentationTests.swift -o /tmp/flightdeck-trip-tests
/tmp/flightdeck-trip-tests
```

## Later additions

User-configurable budget limits, email-based recovery and push delivery are not configured yet. A future scheduled worker and APNs delivery must use the authenticated owner's provider key and the same durable budget gate.
