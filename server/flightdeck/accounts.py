"""Account/session storage. Provider keys are encrypted and never part of a response."""
from datetime import datetime, timedelta
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import sqlite3
from uuid import uuid4

from argon2 import PasswordHasher, Type
from argon2.exceptions import VerificationError, InvalidHashError
from cryptography.fernet import Fernet, InvalidToken

from .database import Database, utcnow


class AccountError(Exception):
    def __init__(self, message, status=400):
        self.message, self.status = message, status


def fingerprint(key):
    return hashlib.sha256(key.encode()).hexdigest()


class KeyVault:
    def __init__(self, path, *, encrypted_keys_exist=False):
        path = Path(path)
        if not path.exists():
            if encrypted_keys_exist:
                raise RuntimeError('Encryption key missing. Restore the original key; it must not be regenerated.')
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            try:
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, 'wb') as file:
                    file.write(Fernet.generate_key())
            except FileExistsError:
                pass
        try:
            self.cipher = Fernet(path.read_bytes().strip())
        except (ValueError, OSError):
            raise RuntimeError('The server encryption key could not be loaded.') from None

    def encrypt(self, user_id, key):
        return self.cipher.encrypt(json.dumps({'owner':user_id, 'key':key}).encode()).decode()

    def decrypt(self, user_id, ciphertext):
        try:
            value = json.loads(self.cipher.decrypt(ciphertext.encode()))
            if not hmac.compare_digest(value['owner'], user_id):
                raise ValueError()
            return value['key']
        except (InvalidToken, ValueError, KeyError, TypeError):
            raise AccountError('The server could not unlock this account’s API key.',503) from None


class Accounts:
    def __init__(self, settings, clock=utcnow):
        self.settings, self.clock = settings, clock
        settings.prepare_directory()
        self.db = Database(settings.database)
        # Old shared data must never become visible to a new registrant.
        with self.db.connect() as con:
            legacy = any(con.execute('SELECT COUNT(*) FROM '+table).fetchone()[0] for table in ('trips','reservations','snapshots','api_cache','account_usage'))
            if legacy or con.execute("SELECT 1 FROM meta WHERE key='mode'").fetchone():
                raise RuntimeError('Legacy shared database detected. Keep its backup and use a new accounts database; see SECURITY.md for migration.')
            con.executescript('''
                CREATE TABLE IF NOT EXISTS users(
                    id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL,
                    created_at TEXT NOT NULL, key_cipher TEXT, key_updated_at TEXT);
                CREATE TABLE IF NOT EXISTS sessions(
                    digest TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
                    created_at TEXT NOT NULL, expires_at TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);
                CREATE TABLE IF NOT EXISTS key_owners(fingerprint TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id));
                CREATE TABLE IF NOT EXISTS auth_limits(bucket TEXT PRIMARY KEY, started_at TEXT NOT NULL, count INTEGER NOT NULL);
            ''')
            encrypted = bool(con.execute('SELECT 1 FROM users WHERE key_cipher IS NOT NULL LIMIT 1').fetchone())
        self.vault = KeyVault(settings.key_file, encrypted_keys_exist=encrypted)
        self.hasher = PasswordHasher(time_cost=2, memory_cost=19456, parallelism=1, type=Type.ID)
        self.dummy_hash = self.hasher.hash(secrets.token_urlsafe(32))
        # A wrong restored master key must fail at startup, before any new keys are stored.
        with self.db.connect() as con:
            for row in con.execute('SELECT id,key_cipher FROM users WHERE key_cipher IS NOT NULL'):
                self.vault.decrypt(row['id'],row['key_cipher'])

    def throttle(self, bucket, limit, seconds):
        now = self.clock()
        with self.db.transaction() as con:
            row = con.execute('SELECT started_at,count FROM auth_limits WHERE bucket=?',(bucket,)).fetchone()
            if row and (now-datetime.fromisoformat(row[0])).total_seconds() < seconds:
                if row[1] >= limit:
                    raise AccountError('Too many attempts. Please try again later.',429)
                con.execute('UPDATE auth_limits SET count=count+1 WHERE bucket=?',(bucket,))
            else:
                con.execute('INSERT OR REPLACE INTO auth_limits VALUES (?,?,1)',(bucket,now.isoformat()))
            con.execute('DELETE FROM auth_limits WHERE started_at < ?',((now-timedelta(days=1)).isoformat(),))

    @staticmethod
    def public(user):
        return {'id':user['id'],'username':user['username'],'has_api_key':bool(user['key_cipher']),
                'api_key_updated_at':user['key_updated_at']}

    def user(self, user_id):
        with self.db.connect() as con:
            row = con.execute('SELECT * FROM users WHERE id=?',(user_id,)).fetchone()
            if not row:
                raise AccountError('Please sign in again.',401)
            return dict(row)

    def register(self, username, password):
        if not self.settings.registration_open:
            raise AccountError('Registration is closed on this server.',403)
        user_id = str(uuid4())
        encoded = self.hasher.hash(password)
        try:
            with self.db.connect() as con:
                con.execute('INSERT INTO users VALUES (?,?,?,?,NULL,NULL)',(user_id,username,encoded,self.clock().isoformat()))
        except sqlite3.IntegrityError:
            raise AccountError('This username is unavailable.',409) from None
        return self.issue_session(self.user(user_id))

    def login(self, username, password):
        with self.db.connect() as con:
            row = con.execute('SELECT * FROM users WHERE username=?',(username,)).fetchone()
        try:
            valid = self.hasher.verify(row['password_hash'] if row else self.dummy_hash,password)
        except (VerificationError,InvalidHashError):
            valid = False
        if not row or not valid:
            raise AccountError('Username or password not accepted.',401)
        if self.hasher.check_needs_rehash(row['password_hash']):
            with self.db.connect() as con:
                con.execute('UPDATE users SET password_hash=? WHERE id=?',(self.hasher.hash(password),row['id']))
        return self.issue_session(dict(row))

    def issue_session(self, user):
        token = secrets.token_urlsafe(32)
        now = self.clock(); expires = now+timedelta(days=self.settings.session_days)
        with self.db.transaction() as con:
            con.execute('DELETE FROM sessions WHERE expires_at <= ?',(now.isoformat(),))
            con.execute('INSERT INTO sessions VALUES (?,?,?,?)',(fingerprint(token),user['id'],now.isoformat(),expires.isoformat()))
        return {'session_token':token,'expires_at':expires.isoformat(),'account':self.public(user)}

    def authenticate(self, authorization):
        if not authorization or not authorization.startswith('Bearer ') or len(authorization) > 256:
            raise AccountError('Please sign in to this server.',401)
        digest = fingerprint(authorization[7:])
        with self.db.connect() as con:
            row = con.execute('SELECT users.* FROM sessions JOIN users ON users.id=sessions.user_id WHERE digest=? AND expires_at>?',
                              (digest,self.clock().isoformat())).fetchone()
        if not row:
            raise AccountError('Your session has expired. Please sign in again.',401)
        return dict(row)

    def logout(self, authorization, user_id, all_sessions=False):
        with self.db.connect() as con:
            if all_sessions:
                con.execute('DELETE FROM sessions WHERE user_id=?',(user_id,))
            else:
                con.execute('DELETE FROM sessions WHERE digest=? AND user_id=?',(fingerprint(authorization[7:]),user_id))

    def tenant(self, user_id):
        # Only an authenticated, server-generated UUID may choose a database path.
        from uuid import UUID
        if str(UUID(user_id)) != user_id:
            raise AccountError('Invalid account.',401)
        root = self.settings.user_directory
        root.mkdir(parents=True,exist_ok=True,mode=0o700)
        db = Database(str(root/(user_id+'.sqlite3')))
        old_mode = db.meta('mode')
        if old_mode and old_mode != self.settings.mode:
            raise AccountError('This account database belongs to a different server mode.',503)
        db.set_meta('mode',self.settings.mode)
        return db

    def save_key(self, user_id, key):
        digest = fingerprint(key)
        cipher = self.vault.encrypt(user_id,key)
        with self.db.transaction() as con:
            owner = con.execute('SELECT user_id FROM key_owners WHERE fingerprint=?',(digest,)).fetchone()
            if owner and owner[0] != user_id:
                raise AccountError('This key cannot be assigned to this account. Use your own AeroAPI key.',409)
            # Permanent ownership tombstone: moving/removing a key cannot reset its budget.
            con.execute('INSERT OR IGNORE INTO key_owners VALUES (?,?)',(digest,user_id))
            con.execute('UPDATE users SET key_cipher=?,key_updated_at=? WHERE id=?',(cipher,self.clock().isoformat(),user_id))
        db = self.tenant(user_id)
        # Explicit replacement keeps every reservation/high-water mark, and invalidates
        # key-specific cached data. The connector still rejects unapproved key changes.
        with db.transaction() as con:
            con.execute('DELETE FROM api_cache')
            con.execute('INSERT OR REPLACE INTO meta VALUES (?,?)',('api_key_fingerprint',digest))

    def remove_key(self, user_id):
        with self.db.connect() as con:
            con.execute('UPDATE users SET key_cipher=NULL,key_updated_at=NULL WHERE id=?',(user_id,))
        with self.tenant(user_id).connect() as con:
            con.execute('DELETE FROM api_cache')
        # Never erase key ownership or the usage ledger.

    def assert_key_owner(self, user_id, key):
        with self.db.connect() as con:
            owner = con.execute('SELECT user_id FROM key_owners WHERE fingerprint=?',(fingerprint(key),)).fetchone()
        if owner and owner[0] != user_id:
            raise AccountError('This key cannot be assigned to this account. Use your own AeroAPI key.',409)

    def provider_key(self, user):
        if not user['key_cipher']:
            raise AccountError('Add your AeroAPI key to enable live flight information.',409)
        return self.vault.decrypt(user['id'],user['key_cipher'])
