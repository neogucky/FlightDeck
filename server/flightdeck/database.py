from contextlib import contextmanager
import json
import os
import sqlite3
from datetime import datetime, timedelta, timezone


def utcnow():
    return datetime.now(timezone.utc)


class Database:
    def __init__(self, path: str):
        self.path = path
        # SQLite WAL files inherit the main database's private file mode.
        try:
            fd = os.open(path,os.O_WRONLY | os.O_CREAT | os.O_EXCL,0o600)
            os.close(fd)
        except FileExistsError:
            pass
        os.chmod(path,0o600)
        with self.connect() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS trips(id TEXT PRIMARY KEY, created_at TEXT NOT NULL, payload TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS snapshots(leg_id TEXT PRIMARY KEY, fetched_at TEXT NOT NULL, payload TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS api_cache(key TEXT PRIMARY KEY, fetched_at TEXT NOT NULL, payload TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS reservations(
                    id TEXT PRIMARY KEY, month TEXT NOT NULL, amount_micro INTEGER NOT NULL,
                    created_at TEXT NOT NULL, outcome TEXT NOT NULL, endpoint TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS reservation_month ON reservations(month);
                CREATE TABLE IF NOT EXISTS account_usage(
                    month TEXT PRIMARY KEY, high_water_micro INTEGER NOT NULL, checked_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS refresh_attempts(leg_id TEXT PRIMARY KEY, attempted_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS refresh_issues(leg_id TEXT PRIMARY KEY, payload TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS provider_attempts(id TEXT PRIMARY KEY, created_at TEXT NOT NULL, kind TEXT NOT NULL);
            """)
            # Preserve the original ledger; add settlement metadata in place.
            columns={r['name'] for r in db.execute('PRAGMA table_info(reservations)')}
            if 'completed_at' not in columns:
                db.execute('ALTER TABLE reservations ADD COLUMN completed_at TEXT')
                for row in db.execute('SELECT id,created_at FROM reservations').fetchall():
                    completed=datetime.fromisoformat(row['created_at'])+timedelta(minutes=1)
                    db.execute('UPDATE reservations SET completed_at=? WHERE id=?',(completed.isoformat(),row['id']))
            if 'reconciled_at' not in columns:
                db.execute('ALTER TABLE reservations ADD COLUMN reconciled_at TEXT')
            if 'covered_through' not in {r['name'] for r in db.execute('PRAGMA table_info(account_usage)')}:
                db.execute('ALTER TABLE account_usage ADD COLUMN covered_through TEXT')

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=30, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA busy_timeout=30000")
        db.execute("PRAGMA foreign_keys=ON")
        try:
            yield db
        finally:
            db.close()

    @contextmanager
    def transaction(self):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                yield db
                db.execute("COMMIT")
            except BaseException:
                db.execute("ROLLBACK")
                raise

    def meta(self, key):
        with self.connect() as db:
            row = db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
            return row[0] if row else None

    def set_meta(self, key, value):
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", (key, value))

    def trips(self):
        with self.connect() as db:
            return [json.loads(r[0]) for r in db.execute("SELECT payload FROM trips ORDER BY created_at")]

    def save_trip(self, trip):
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO trips VALUES (?,?,?)", (trip['id'], trip['created_at'], json.dumps(trip)))

    def save_imported_trip(self, trip, import_id):
        # Idempotency and flight-level deduplication are atomic and scoped to this tenant.
        with self.transaction() as db:
            existing=[json.loads(row[0]) for row in db.execute('SELECT payload FROM trips')]
            if any(t.get('import_id')==import_id for t in existing): return None
            known={(l['flight_number'],l['departure_date']) for t in existing for l in t['legs']}
            trip['legs']=[l for l in trip['legs'] if (l['flight_number'],l['departure_date']) not in known]
            if not trip['legs']: return None
            trip['import_id']=import_id
            db.execute('INSERT INTO trips VALUES (?,?,?)',(trip['id'],trip['created_at'],json.dumps(trip)))
        return trip

    def delete_trip(self, trip_id):
        with self.transaction() as db:
            row = db.execute("SELECT payload FROM trips WHERE id=?", (trip_id,)).fetchone()
            if row:
                for leg in json.loads(row[0])['legs']:
                    db.execute("DELETE FROM snapshots WHERE leg_id=?", (leg['id'],))
                    db.execute("DELETE FROM refresh_attempts WHERE leg_id=?", (leg['id'],))
                    db.execute("DELETE FROM refresh_issues WHERE leg_id=?", (leg['id'],))
            db.execute("DELETE FROM trips WHERE id=?", (trip_id,))

    def snapshot(self, leg_id):
        with self.connect() as db:
            row = db.execute("SELECT payload FROM snapshots WHERE leg_id=?", (leg_id,)).fetchone()
            return json.loads(row[0]) if row else None

    def save_snapshot(self, leg_id, snapshot):
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO snapshots VALUES (?,?,?)", (leg_id, snapshot['fetched_at'], json.dumps(snapshot)))

    def refresh_issue(self, leg_id):
        with self.connect() as db:
            row=db.execute('SELECT payload FROM refresh_issues WHERE leg_id=?',(leg_id,)).fetchone()
            return json.loads(row[0]) if row else None

    def set_refresh_issue(self, leg_id, issue):
        with self.connect() as db:
            if issue:
                db.execute('INSERT OR REPLACE INTO refresh_issues VALUES (?,?)',(leg_id,json.dumps(issue)))
            else:
                db.execute('DELETE FROM refresh_issues WHERE leg_id=?',(leg_id,))

    def cached(self, key, now, ttl=900):
        with self.connect() as db:
            row = db.execute("SELECT fetched_at,payload FROM api_cache WHERE key=?", (key,)).fetchone()
        if row and (now - datetime.fromisoformat(row[0])).total_seconds() < ttl:
            return json.loads(row[1])
        return None

    def cache(self, key, now, payload):
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO api_cache VALUES (?,?,?)", (key, now.isoformat(), json.dumps(payload)))

    def last_refresh_attempt(self, leg_id):
        with self.connect() as db:
            row=db.execute('SELECT attempted_at FROM refresh_attempts WHERE leg_id=?',(leg_id,)).fetchone()
            return datetime.fromisoformat(row[0]) if row else None

    def claim_refresh(self, leg_id, now, min_seconds=60):
        with self.transaction() as db:
            row = db.execute("SELECT attempted_at FROM refresh_attempts WHERE leg_id=?", (leg_id,)).fetchone()
            if row and (now-datetime.fromisoformat(row[0])).total_seconds() < min_seconds:
                return False
            db.execute("INSERT OR REPLACE INTO refresh_attempts VALUES (?,?)", (leg_id, now.isoformat()))
            return True

    def purge_provider_data(self, now):
        # Keep raw and normalized provider payloads for at most 29 days. User itinerary remains.
        cutoff = (now-timedelta(days=29)).isoformat()
        with self.connect() as db:
            db.execute("DELETE FROM api_cache WHERE fetched_at < ?", (cutoff,))
            db.execute("DELETE FROM snapshots WHERE fetched_at < ?", (cutoff,))
