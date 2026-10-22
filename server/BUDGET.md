# AeroAPI spending gate

The sole provider integration is `flightdeck/connector.py`. Its paid operations are allowlisted: `GET /flights/{ident}`, filtered `GET /schedules/{date_start}/{date_end}`, and `GET /airports/{id}`. It cannot call arbitrary endpoints and does not follow pagination links or redirects.

## Account scope

Each authenticated FlightDeck user has a separate SQLite database containing their reservations, provider-account high-water marks, API cache and request throttles. Every provider request uses that user's encrypted credential. Caches are not shared between users, even for identical flight queries. The initial $4.50 ceiling applies per user; the app's Usage tab shows that account's current totals and up to 12 months of history. Budget controls in the app are deferred.

API-key setup verifies access using the usage endpoint before storing the key. One exact key is permanently associated with one user on an installation. Replacement/removal preserves all reservations and high-water accounting, including across months; it never grants a fresh budget. Keys from one FlightAware account still share its provider bill, so use one FlightDeck user per provider account. This does not control external usage or other installations.

## Conservative accounting

Prices reviewed on **20 October 2026**:

- Flight-information lookup: published **$0.005 per result set**, capped with `max_pages=1`.
- Published schedule lookup: **$0.020 per result set**, capped with `max_pages=1` and filtered by airline and numeric flight number.
- Airport metadata lookup: **$0.015** per result set; this endpoint returns one airport object rather than a paged collection.
- Account-wide usage lookup: published **$0**.
- This installation reserves **$0.01 per flight-information call**, **$0.04 per schedule call**, and **$0.03 per airport metadata call**, twice each published price. A cold schedule plus two airport lookups reserves $0.10. Every endpoint checks that its complete reservation fits before sending the paid request.
- Operational ceiling: **$4.50/month**. The configured budget may be lower, never higher. An additional $0.50 remains below the requested $5 limit.

Before each paid request, the connector queries `/account/usage?all_keys=true` and records undiscounted account cost. An unavailable, malformed, stale or non-finite usage report prevents paid requests. The provider documents account metering as updating every ten minutes; its response has no per-request billing receipt or reporting watermark.

The gate compares **reported usage for an older period plus predicted pending costs for newer requests** with the $4.50 ceiling. The usage request explicitly sets `start` to the UTC month's beginning and `end` to 15 minutes before that request starts: the documented ten-minute cadence plus five minutes of processing headroom. Only after that report succeeds are completed local requests older than its `end` marked reconciled. Their audit records remain in the database, but their estimates no longer contribute to pending costs. Time passing alone never releases an estimate. Integer microdollars and upward rounding are used throughout; floating-point comparisons do not authorize spending.

Fifteen minutes is a conservative operational assumption, not a provider guarantee: FlightAware documents a refresh cadence rather than an exact ingestion deadline. The Usage page exposes both when a report was retrieved and where its requested period ends. Newer calls are estimated at twice the reviewed price until a later report covers them. A previously observed provider-cost high-water mark remains a floor so key replacement, reporting regressions or upgrades cannot erase already confirmed spend. During the first 15 minutes of a new month, a current report is still required and recent requests remain pending. Historical periods with pending entries are reconciled separately, one per usage check.

Reservations are committed with SQLite `BEGIN IMMEDIATE` **before** the HTTP request. Concurrent processes share that ledger. A failed local rate check, pool wait, DNS/TLS connection or connection timeout is recorded as not sent and contributes no pending cost. A read/write timeout, interrupted response, HTTP error, cancellation or unknown outcome may have reached the provider: its estimate remains until covered by a usage report. An unfinished in-flight record is never released by reconciliation. There are no automatic HTTP retries. A durable limit of four paid requests per rolling minute allows headroom for free usage checks within the Personal tier's ten result sets/minute, without assuming free requests are exempt. Forced refresh still shares a 60-second cache.

An additional durable gate counts every provider HTTP attempt against ten per rolling minute for the user, including free usage refreshes and key verification. The Usage tab has one manual refresh gesture: pull down. That operation refreshes provider usage without calling a paid flight endpoint. Its total is reported spend plus predicted pending costs, not a billing invoice. Request counts describe requests sent, including responses that may ultimately have no charge; connection failures before send are excluded.

Existing ledgers are upgraded in place, preserving their original amounts and outcomes. Since the old ledger did not record completion times, its requests receive a one-minute completion buffer after their stored start. A subsequent successful usage report must cover that buffered time before the estimate is retired. Back up the databases before upgrading; never reset them to get a lower total.

Each leg is resolved once when added. Subsequent automatic paid updates pause until 48 hours before its verified scheduled departure (falling back to an offset-aware calendar departure). From 48 to six hours before departure, the interval is two hours; within six hours and while in progress, it is 15 minutes. Completed flights are skipped. The iOS app requests automatic updates only while active; the server runs no polling timer. When no departure time could be verified, an initial attempt is allowed, then further updates require manual refresh until a time is available. Failed automatic attempts use the same cadence, including rate limits and temporary provider errors.

Pull-to-refresh can bypass that timing after the existing 60-second safety gate. Due schedule updates also bypass the daily schedule cache, while static airport metadata retains its 24-hour cache. Schedule freshness uses the schedule's own retrieval time, not the age of cached airport names/timezones. Live lookup becomes available within approximately 47 hours of scheduled departure; schedules cover earlier times and missing live occurrences. Responses include each leg's current automatic interval and tracking start so the app can describe the server's actual policy.

Within 24 hours of a UTC month boundary, each reservation counts in both adjacent months, conservatively covering timezone/processing ambiguity. Unexpected page counts or response sizes latch a persistent billing block; further paid calls require review. Keys can be replaced only through authenticated account setup, which preserves the ledger and updates its credential binding. Unapproved direct key changes still fail closed.

The current price review expires **18 November 2026**. Live calls fail closed after that date. Review the provider’s prices and endpoint semantics before explicitly extending `FLIGHTDECK_PRICING_VALID_UNTIL`; it is not automatically rolled forward.

## What a local gate can guarantee

It enforces a durable, conservative request budget for **this installation at the reviewed prices**. It cannot control charges generated by other applications, other people, provider billing changes, taxes, subscription minimums, or deliberate deletion of the database. Account metering is delayed, so shared-account external usage cannot be perfectly bounded. Use a dedicated Personal account for this app and a provider-side spending cap if available. The $5 free allowance is not treated as spendable credit; all requests count against our limit before any free allowance.

Never delete, reset, edit downward, restore an old copy of, or switch around the usage ledger in order to resume calls. When migrating the service, stop it and back up the entire SQLite database consistently (including WAL state using SQLite's backup API). Do not copy only the main database file while it is running. If the ledger is lost or a billing block appears, disable live mode, reconcile the provider dashboard including pending usage, and establish a conservative baseline before resuming. User trip deletion does not delete billing records.

With accounts, preserve the account database (including key ownership) and every per-user database. Never assign shared legacy data or reservations to an arbitrary new registrant. See `SECURITY.md` for upgrade and key-backup requirements.

## Sources

- [Current pricing](https://www.flightaware.com/commercial/aeroapi/)
- [Official current OpenAPI specification](https://static.flightaware.com/rsrc/aeroapi/aeroapi-openapi.yml), reviewed version 4.30.0
- [FlightAware usage cadence and free usage endpoint](https://support.flightaware.com/hc/en-us/articles/32551385660055-How-Do-I-Check-My-API-Usage)
- [Personal licence](https://www.flightaware.com/commercial/aeroapi/AeroAPI_Personal_License.pdf)
