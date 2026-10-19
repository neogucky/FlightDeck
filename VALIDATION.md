# Version 0.1 validation

Checked on 19 October 2026.

- **Python:** 16 tests passed. Covers concurrent spending reservations, account-wide high-water accounting, decimal rounding, restart persistence, month boundaries, expired prices, usage-report failures, timeouts without refunds, pagination blocking, caching, rate limits, authenticated API operations, connected-trip validation, local departure-date matching, provider retention and aircraft reassignment. Cached provider timestamps are preserved instead of making older data appear fresh.
- **Native build:** Xcode simulator build succeeded, with an iOS 17 deployment target and no third-party app packages.
- **Native UI:** Three tests passed. The overview shows the whole route, both flight numbers and two separate incoming-aircraft cards. Connected flights can be entered without a trip name, saved and reopened after terminating the app; journal, aircraft details and Settings checks pass.
- **Trip status:** Native Swift checks passed for delayed, cancelled and diverted connections, arrival delays, missing data, connecting/in-progress/completed trips, direct flights and empty trips. One on-time leg cannot imply every leg is on time.
- **Client/server integration:** The actual Swift API client and Codable models passed an HTTP smoke test against the Python demo server: authentication, adding linked legs, decoding flight details, refresh, usage display and deletion.
- **Visual review:** Updated simulator overview and connected-flight form inspected, including the navy add button, trip-wide departure/final arrival, both incoming-aircraft cards and removal of the trip-name field. Screenshots are in `previews/`.

No real FlightAware key was supplied. Live provider requests were exercised with deterministic HTTP mocks; no paid calls were made. The Windows service installer is prepared but has not been run on the user's Windows server. Physical-device signing, server HTTPS/certificate setup and push notifications have not been performed.

The test environment emits a dependency deprecation warning about Starlette's HTTPX-based TestClient; all assertions pass. This does not affect the production API client.
