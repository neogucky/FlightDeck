# Accounts, credentials and deployment

FlightDeck 0.2 uses an account per person, on the server they choose. There is no shared client token and no global provider key.

## What is isolated

The account database holds usernames, Argon2id password hashes, session-token hashes, encrypted provider keys and permanent key-ownership fingerprints. Each authenticated server-generated user UUID selects a separate SQLite file under `data/users/`. User input cannot select a database or another user's identity. Trips, normalized snapshots, raw API cache, refresh throttles, provider request limits, account usage and paid-request reservations live in that user's database. Requests for another user's trip return 404. Each request constructs and closes its own provider client with that user's key; no global authenticated HTTP client is reused.

The same exact API key cannot be attached to multiple users on an installation, including after removal. Replacing/removing a key keeps every spending reservation and usage high-water mark. Cache entries are invalidated on replacement. The provider's usage report includes all keys in the corresponding FlightAware account; use one FlightDeck user per FlightAware account, preferably a dedicated provider account. Different keys from one provider account still share a provider bill. Other installations and external applications cannot be controlled by this server's local budget gate.

## Passwords and sessions

Passwords have 12–128 characters and use Argon2id (19 MiB, two iterations, one lane, random salt). Login failures use the same message for unknown users and incorrect passwords and perform a dummy hash check for unknown users. Registration can be disabled with `FLIGHTDECK_REGISTRATION_OPEN=false`. Durable authentication limits apply by username and network peer; JSON request bodies are capped at 64 KiB, including chunked requests. Behind a reverse proxy the network-peer limit is shared unless a separate trusted proxy policy is introduced. The shipped runner does not trust forwarded identity headers.

Sessions are random 256-bit opaque bearer tokens. Only their SHA-256 digests are stored on the server. They expire after 90 days by default, configurable downward with `FLIGHTDECK_SESSION_DAYS`. Sign-out revokes one session; sign-out-all revokes all sessions for that user. The iPhone stores its session in a `ThisDeviceOnly` Keychain item. Passwords and provider keys are not written to device storage. Offline journal caches are partitioned by server and user, protected by iOS file protection and removed on sign-out. Late responses from a previous session cannot update another user's screen or cache. Legacy unscoped caches/tokens are not used for new accounts.

If the server cannot be reached during sign-out, the app removes the local session and explains that remote revocation could not be completed. The user can later sign in and sign out all devices.

There is no email-based recovery service in this version. A trusted server administrator can recover an account using:

```powershell
python -m flightdeck reset-password --username alice
```

The command reads the new password without echoing it, preserves account data and billing records, and revokes all existing sessions.

## Write-only provider-key setup

An authenticated user sends the key over HTTPS using `PUT /v1/account/api-key`. It is verified with the account-usage endpoint before saving; no paid flight request is needed for verification. Responses contain only `has_api_key` and a last-updated timestamp. There is **no GET endpoint for the saved key**, no key preview, and no key export. Validation failures do not echo submitted input. Upstream errors are sanitized. Responses use `Cache-Control: no-store`; the shipped server disables HTTP access logging. Reverse proxies must also avoid recording authorization headers and request/response bodies.

At rest, keys use Fernet authenticated encryption, with the owning user ID inside the authenticated encrypted payload. Moving ciphertext to another user fails verification. The random master key is stored in a separate file, normally `secrets/master.key`, outside the database. File modes are private on Unix; the Windows installer restricts account data and the master key to the administrator/System/service identities, with read-only master-key access for the service. Back up the master key separately and securely. A missing or incorrect master key with existing encrypted credentials fails closed; it is never silently replaced.

**Write-only means through the application API.** The server process must decrypt a key to call FlightAware. A server administrator or attacker who controls the running server and its master key can therefore access it. Users must trust the operator of the server they select. Encryption protects database-only disclosure; it does not protect a fully compromised host.

## Hosting and upgrades

Run one worker using `python -m flightdeck run`, or use the Windows service installer. Terminate HTTPS at a trusted reverse proxy and forward to loopback port 8787. Preserve Authorization and HTTP methods, avoid redirects, and never expose the checkout, data, `.env` or `secrets` as static files. A hostname-matching certificate must be trusted by the iPhone. The client accepts HTTP only for localhost development and does not follow redirects.

Fresh installs generate a master key during configuration. Users then connect, register/sign in and add their own keys in the app. Registration is open by default and can be closed after invited users have registered.

This is a breaking upgrade from the shared-token prototype. The new configurator uses `data/live-accounts.sqlite3` and `data/users/`, with no global provider key. Back up an existing `.env` and shared database, then configure a new account database. A nonempty shared database is rejected at startup rather than assigned to the first registrant. There is no automatic ownership migration: an existing live installation needs an explicit offline administrator migration that preserves its entire spending ledger and conservatively reconciles provider usage. Do not use a fresh database to bypass reservations already incurred. The local development environment had no live provider key configured.

Back up SQLite databases consistently using SQLite's backup API, including the account database and every user database. Do not copy just the main file while WAL writes are active, restore older spending totals to resume calls, or lose the key-ownership registry. Reconcile provider usage and revoke restored sessions after recovery before reopening the service.

## References

- [OWASP password storage guidance](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)
- [Fernet authenticated-encryption documentation](https://cryptography.io/en/stable/fernet/)
- [FlightAware AeroAPI](https://www.flightaware.com/commercial/aeroapi/)

See `BUDGET.md` for the conservative accounting rules and their limits. Native tests and provider mocks are development validation, not an independent security audit.

## Calendar imports

Calendar discovery takes place in the iOS app through EventKit, restricted by the app to selected calendars. iOS requires full calendar permission for reads; FlightDeck never edits calendar events. The server receives no calendar credentials, event descriptions, source IDs, calendar names or event titles. Only explicitly accepted flight metadata and a hashed import ID are submitted under the current authenticated session. Source times have UTC offsets and are validated against the departure date and chronological connection order.

Calendar imports use an atomic per-tenant transaction to deduplicate both import identities and existing flight number/date pairs. Duplicate retries return existing account state without provider refreshes. They do not reset, delete or reduce billing reservations. Device calendar preferences and hashed dismissals are separated by server/account and remain on the device; leaving or signing out of an account clears the active suggestion state.
