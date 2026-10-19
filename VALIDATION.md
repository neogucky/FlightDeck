# Version 0.1 validation

Checked on 19 October 2026.

- **Python:** 16 tests passed. Covers concurrent spending reservations, account-wide high-water accounting, decimal rounding, restart persistence, month boundaries, expired prices, usage-report failures, timeouts without refunds, pagination blocking, caching, rate limits, authenticated API operations, connected-trip validation, local departure-date matching, provider retention and aircraft reassignment. Cached provider timestamps are preserved instead of making older data appear fresh.
- **Native build:** Xcode simulator build succeeded, with an iOS 17 deployment target and no third-party app packages.
- **Native UI:** Connected flights can be entered and opened; journal, aircraft details and Settings checks pass. A separate successful run terminates/reopens the app and verifies the added connected trip remains available.
- **Client/server integration:** The actual Swift API client and Codable models passed an HTTP smoke test against the Python demo server: authentication, adding linked legs, decoding flight details, refresh, usage display and deletion.
- **Visual review:** Native simulator overview and Settings inspected. Screenshots are in `previews/`.

No real FlightAware key was supplied. Live provider requests were exercised with deterministic HTTP mocks; no paid calls were made. The Windows service installer is prepared but has not been run on the user's Windows server. Physical-device signing, server HTTPS/certificate setup and push notifications have not been performed.

The test environment emits a dependency deprecation warning about Starlette's HTTPX-based TestClient; all assertions pass. This does not affect the production API client.
