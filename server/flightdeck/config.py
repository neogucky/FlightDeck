from dataclasses import dataclass
from datetime import date
from decimal import Decimal
import os
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    mode: str = "live"
    database: str = "data/accounts.sqlite3"
    encryption_key_file: str = ""
    registration_open: bool = True
    session_days: int = 90
    # Internal per-request credentials only. Never loaded from a global environment key.
    api_key: str = ""
    budget_micro: int = 4_500_000
    pricing_valid_until: date = date(2026, 11, 18)
    cache_seconds: int = 900

    def __post_init__(self):
        if self.mode not in {"demo", "live"}:
            raise ValueError("FLIGHTDECK_MODE must be demo or live")
        if not 0 < self.budget_micro <= 4_500_000:
            raise ValueError("The operational budget must be between $0 and $4.50")
        if not 1 <= self.session_days <= 90:
            raise ValueError("Session lifetime must be between 1 and 90 days")

    @classmethod
    def from_env(cls):
        return cls(
            mode=os.getenv("FLIGHTDECK_MODE", "live"),
            database=os.getenv("FLIGHTDECK_DATABASE", "data/accounts.sqlite3"),
            encryption_key_file=os.getenv("FLIGHTDECK_ENCRYPTION_KEY_FILE", ""),
            registration_open=os.getenv("FLIGHTDECK_REGISTRATION_OPEN", "true").lower() == "true",
            session_days=int(os.getenv("FLIGHTDECK_SESSION_DAYS", "90")),
            budget_micro=int(Decimal(os.getenv("FLIGHTDECK_BUDGET_USD", "4.50")) * 1_000_000),
            pricing_valid_until=date.fromisoformat(os.getenv("FLIGHTDECK_PRICING_VALID_UNTIL", "2026-11-18")),
        )

    def prepare_directory(self):
        Path(self.database).resolve().parent.mkdir(parents=True, exist_ok=True, mode=0o700)

    @property
    def key_file(self):
        return Path(self.encryption_key_file) if self.encryption_key_file else Path(self.database).resolve().parent / "secrets" / "master.key"

    @property
    def user_directory(self):
        return Path(self.database).resolve().parent / "users"
