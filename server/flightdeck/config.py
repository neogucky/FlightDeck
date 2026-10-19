from dataclasses import dataclass
from datetime import date
from decimal import Decimal
import os
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    mode: str = "demo"
    database: str = "data/flightdeck.sqlite3"
    access_token: str = ""
    api_key: str = ""
    budget_micro: int = 4_500_000
    pricing_valid_until: date = date(2026, 11, 18)
    cache_seconds: int = 900

    def __post_init__(self):
        if self.mode not in {"demo", "live"}:
            raise ValueError("FLIGHTDECK_MODE must be demo or live")
        if not 0 < self.budget_micro <= 4_500_000:
            raise ValueError("The operational budget must be between $0 and $4.50")
        if len(self.access_token) < 32:
            raise ValueError("Set FLIGHTDECK_ACCESS_TOKEN to at least 32 random characters. Run python -m flightdeck configure.")
        if self.mode == "live" and not self.api_key:
            raise ValueError("Live mode requires FLIGHTAWARE_API_KEY")

    @classmethod
    def from_env(cls):
        return cls(
            mode=os.getenv("FLIGHTDECK_MODE", "demo"),
            database=os.getenv("FLIGHTDECK_DATABASE", "data/flightdeck.sqlite3"),
            access_token=os.getenv("FLIGHTDECK_ACCESS_TOKEN", ""),
            api_key=os.getenv("FLIGHTAWARE_API_KEY", ""),
            budget_micro=int(Decimal(os.getenv("FLIGHTDECK_BUDGET_USD", "4.50")) * 1_000_000),
            pricing_valid_until=date.fromisoformat(os.getenv("FLIGHTDECK_PRICING_VALID_UNTIL", "2026-11-18")),
        )

    def prepare_directory(self):
        Path(self.database).resolve().parent.mkdir(parents=True, exist_ok=True)
