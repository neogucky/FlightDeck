# FlightDeck

A personal flight companion: your upcoming flight, the incoming aircraft and every connection in one place. Native SwiftUI for iPhone, backed by a small Python service.

[Native overview preview](previews/overview.png) · [Three flights](previews/overview-three-flights.png) · [Longer trips](previews/overview-long-trip.png) · [Validation notes](VALIDATION.md)

## First version

- A saved flight journal, including manually entered past flights.
- Single flights and trips with up to eight connected legs; each leg has its own departure date.
- A whole-trip overview with first departure, final arrival and a combined status. For one to three flights, each flight number sits above its arrow between airports; longer trips show endpoints and a connection count. A separate incoming-aircraft card tracks each remaining leg. Trips are identified automatically, with no name to enter.
- Upcoming trips sorted by date, with flight status, gates, local times, aircraft registration/type and the incoming flight when identified by FlightAware.
- Automatic refresh on opening/foregrounding and while the app is visible when data is over 15 minutes old. Pull-to-refresh requests an immediate update, subject to a 60-second safety cache and spending limits.
- Offline device cache, separate demo and server data, connection-token storage in Keychain.
- A dedicated AeroAPI connector with a durable SQLite spending gate.
- No push entitlement, APNs credentials, background polling, or Apple-account changes in this version.

The app initially opens a clearly labelled local demo. Demo records are illustrative and make no network requests. Connecting a server loads its separate itinerary; demo trips are not copied into your real journal.

## Repository

- `app/FlightDeck.xcodeproj` — ready-to-open Xcode project, iOS 17+.
- `app/FlightDeck/` — SwiftUI app, network client, persistence and design components.
- `app/FlightDeckUITests/` — native interaction tests.
- `server/flightdeck/` — FastAPI service, SQLite persistence and AeroAPI connector.
- `server/tests/` — billing/concurrency, API and itinerary tests; no paid API calls.
- `server/scripts/install-windows.ps1` — repeatable Windows-service setup/update.
- `server/BUDGET.md` — spending model, assumptions and recovery rules.

## Run the server

Python 3.11 or newer is required. From `server/`:

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

Choose demo or live in the configurator. Live mode requires your own FlightAware AeroAPI Personal key. Configuration is stored in ignored `.env`; never commit it. Use a dedicated AeroAPI account for this app. A connection token is generated for the iOS client, separate from the provider API key.

The server listens at `127.0.0.1:8787` by default. `/health` is public and contains no private information. All `/v1/` endpoints require `Authorization: Bearer <connection-token>`. Interactive API documentation is disabled. No provider key is sent to the app.

On Windows, run the following in an administrator PowerShell from `server/` after installing Python:

```powershell
.\scripts\install-windows.ps1
```

The installer creates the environment, installs pinned dependencies, prompts for initial configuration, downloads a pinned/hash-verified WinSW release, installs/updates an automatically starting LocalService service, sets file permissions, and checks its health. It does not change your reverse proxy, certificates or firewall. Installation/update is scripted but still requires verification on your Windows machine. The Python backend is tested locally on macOS.

Point your reverse proxy’s chosen HTTPS hostname to `http://127.0.0.1:8787`. Proxy HTTP methods and the Authorization header without redirects. Do not serve the project directory as static files. If the proxy is on another machine, bind to a suitable private interface using `--host` and restrict access to that proxy.

## Run the app

1. Open `app/FlightDeck.xcodeproj` in Xcode.
2. Choose an iPhone simulator and Run to explore the demo.
3. For a physical iPhone, select your authorized development team in Signing & Capabilities. The bundle ID is `com.flightdeck.personal`; change it if needed. This repository does not modify or create developer-account resources automatically.
4. In Settings, enter the HTTPS server address and connection token from `.env`, then connect.

For a self-signed setup, install/trust your private CA on the iPhone and use a valid hostname-matching server certificate. The app uses standard system TLS validation and does not accept arbitrary certificates. For simulator development only, `http://localhost:8787` is supported. Production addresses must use HTTPS.

## Flight data and history

The Personal-tier `/flights/{ident}` endpoint returns recent/near-future occurrences. This version deliberately does not purchase schedule or historical endpoints. You can save trips well ahead of departure or long ago; live details will be unavailable outside the supported recent-flight window. The connector does not buy more pages if a result is missing. Specify airports when needed to disambiguate a flight number/date; no arbitrary occurrence is selected.

Dates are departure-airport local dates. Flight timestamps are stored with offsets and displayed in the corresponding airport timezone. Each linked leg is independent, so overnight connections can have different dates. Incoming links come from FlightAware’s `inbound_fa_flight_id`; they are re-evaluated when aircraft assignments change. Unknown information is displayed as unknown. The app does not yet predict missed connections.

Your **user-entered itinerary** (flight number, date, route and trip name) is retained permanently. Provider payloads and cached live details expire after 29 days on both server and app, conservatively within the published Personal licence’s 30-day raw-data limit. Enter airport codes to keep route history after live details expire. Completed flights are not continually refreshed in the background. This is a flight journal for flights you add; it cannot import an entire historical airline account.

## API contract

- `GET /v1/state` — journal, current snapshots, budget and refresh issues.
- `POST /v1/trips` — create a trip (`title`, `legs`), then attempt eligible live lookups. Saving succeeds even if status lookup is unavailable.
- `DELETE /v1/trips/{id}` — remove the trip and its snapshots.
- `POST /v1/refresh?force=false&trip_id=<optional>` — refresh stale relevant flights; `force=true` bypasses the 15-minute cache but never the 60-second safety cache or budget gate.

## Checks

```sh
cd server
python -m pytest -q
```

From the repository root, using an installed iOS simulator:

```sh
xcodebuild -project app/FlightDeck.xcodeproj -scheme FlightDeck \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

The checked-in project has no third-party iOS dependencies. After adding Swift files, regenerate the deterministic project with `python app/generate_project.py` (preserves no manual project-file edits).

Check trip status aggregation on macOS (including a delayed/cancelled second leg and missing status):

```sh
swiftc app/FlightDeck/Models.swift app/FlightDeck/DemoData.swift \
  app/TripPresentationTests.swift -o /tmp/flightdeck-trip-tests
/tmp/flightdeck-trip-tests
```

The native API smoke test uses the actual app network client and Codable models against a disposable local demo server. Start `python tests/serve_fixture.py` from `server/`, then from the repository root compile and run:

```sh
swiftc -parse-as-library app/FlightDeck/Models.swift app/FlightDeck/APIClient.swift \
  app/IntegrationSmoke.swift -o /tmp/flightdeck-smoke
/tmp/flightdeck-smoke
```

This check runs on macOS, uses a deliberately non-secret local fixture token, and never calls FlightAware.

## Next step after version one

Once push permissions are resolved, add a scheduled worker, change detection and APNs delivery behind the existing backend API. The same budget gate must cover every scheduled call. Native push is not configured yet.
