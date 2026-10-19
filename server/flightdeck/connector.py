"""The ONLY module permitted to contact AeroAPI. No automatic retries or pagination."""
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_CEILING
import hashlib
import json
from urllib.parse import quote
from uuid import uuid4
import httpx
from .database import utcnow

BASE_URL = 'https://aeroapi.flightaware.com/aeroapi'
# Reviewed 2026-10-19: /flights/{ident} = $0.005/result set, /account/usage = $0.
# Reserve DOUBLE the published flight price. Never credit failures or uncertain requests.
FLIGHT_RESERVATION_MICRO = 10_000


class ConnectorError(Exception):
    def __init__(self, message, code='provider_unavailable'):
        self.message, self.code = message, code
        super().__init__(message)


class BudgetGate:
    def __init__(self, db, settings, clock=utcnow):
        self.db, self.settings, self.clock = db, settings, clock

    @staticmethod
    def months(now):
        """Charge adjacent month too within 24h of a boundary (timezone/processing buffer)."""
        result={now.strftime('%Y-%m')}
        result.add((now-timedelta(hours=24)).strftime('%Y-%m'))
        result.add((now+timedelta(hours=24)).strftime('%Y-%m'))
        return sorted(result)

    def account_observed(self, cost, now):
        try:
            amount=Decimal(str(cost))
            if not amount.is_finite() or amount < 0:
                raise ValueError()
            micro=int((amount*1_000_000).to_integral_value(rounding=ROUND_CEILING))
        except Exception:
            raise ConnectorError('Account usage could not be verified. Live calls are paused.', 'usage_unverified')
        with self.db.transaction() as con:
            con.execute('''INSERT INTO account_usage VALUES (?,?,?) ON CONFLICT(month) DO UPDATE SET
                high_water_micro=MAX(high_water_micro,excluded.high_water_micro), checked_at=excluded.checked_at''',
                (now.strftime('%Y-%m'),micro,now.isoformat()))

    def reserve(self, endpoint):
        now=self.clock()
        if endpoint != 'flights':
            raise ConnectorError('Unpriced endpoint blocked.', 'pricing_unverified')
        if now.date() > self.settings.pricing_valid_until:
            raise ConnectorError('The API price review has expired. Review prices before making more calls.', 'pricing_expired')
        request_id=str(uuid4())
        with self.db.transaction() as con:
            block=con.execute("SELECT value FROM meta WHERE key='billing_block'").fetchone()
            if block:
                raise ConnectorError(block[0], 'billing_blocked')
            count=con.execute('SELECT COUNT(DISTINCT substr(id,1,36)) FROM reservations WHERE created_at >= ?',
                              ((now-timedelta(seconds=60)).isoformat(),)).fetchone()[0]
            # Each paid lookup is preceded by a free usage lookup. Budget both against
            # the 10-result-set/minute tier rather than assuming free calls are exempt.
            if count >= 4:
                raise ConnectorError('Refresh rate limit reached. Please wait one minute.', 'rate_limited')
            for month in self.months(now):
                local=con.execute('SELECT COALESCE(SUM(amount_micro),0) FROM reservations WHERE month=?',(month,)).fetchone()[0]
                account=con.execute('SELECT high_water_micro,checked_at FROM account_usage WHERE month=?',(month,)).fetchone()
                if month == now.strftime('%Y-%m') and (not account or (now-datetime.fromisoformat(account[1])).total_seconds()>300):
                    raise ConnectorError('A recent account-wide usage check is required.', 'usage_unverified')
                # Intentionally double-count our own usage: reported account usage PLUS every local reservation.
                effective=local+(account[0] if account else 0)
                if effective+FLIGHT_RESERVATION_MICRO > self.settings.budget_micro:
                    raise ConnectorError('Monthly safety budget reached. Saved flight information is still available.', 'budget_exhausted')
            for month in self.months(now):
                con.execute('INSERT INTO reservations VALUES (?,?,?,?,?,?)',
                    (request_id+':'+month,month,FLIGHT_RESERVATION_MICRO,now.isoformat(),'reserved',endpoint))
        return request_id

    def finish(self, request_id, outcome):
        with self.db.connect() as con:
            con.execute('UPDATE reservations SET outcome=? WHERE substr(id,1,36)=?',(outcome,request_id))

    def summary(self):
        now=self.clock();month=now.strftime('%Y-%m')
        with self.db.connect() as con:
            local=con.execute('SELECT COALESCE(SUM(amount_micro),0),COUNT(*) FROM reservations WHERE month=?',(month,)).fetchone()
            account=con.execute('SELECT high_water_micro,checked_at FROM account_usage WHERE month=?',(month,)).fetchone()
        effective=local[0]+(account[0] if account else 0)
        return {'month':month,'limit_usd':self.settings.budget_micro/1_000_000,
                'hard_limit_usd':5.0,'reserved_usd':local[0]/1_000_000,
                'provider_reported_usd':(account[0] if account else 0)/1_000_000,
                'conservative_used_usd':effective/1_000_000,
                'remaining_usd':max(0,self.settings.budget_micro-effective)/1_000_000,
                'request_count':local[1],'pricing_valid_until':str(self.settings.pricing_valid_until),
                'blocked':bool(self.db.meta('billing_block')) or effective+FLIGHT_RESERVATION_MICRO>self.settings.budget_micro or now.date()>self.settings.pricing_valid_until,
                'account_checked_at':account[1] if account else None}


class AeroAPI:
    def __init__(self, db, settings, clock=utcnow, transport=None):
        self.db,self.settings,self.clock=db,settings,clock
        self.gate=BudgetGate(db,settings,clock)
        self.client=httpx.AsyncClient(base_url=BASE_URL,headers={'x-apikey':settings.api_key,'Accept':'application/json'},
                                     timeout=httpx.Timeout(15),follow_redirects=False,transport=transport)
        # Swapping keys cannot reset the durable ledger; switching keys in an existing DB fails closed.
        fingerprint=hashlib.sha256(settings.api_key.encode()).hexdigest()
        previous=db.meta('api_key_fingerprint')
        if previous and previous != fingerprint:
            raise ValueError('The API key changed. Reconcile billing before switching accounts; do not reset the ledger.')
        db.set_meta('api_key_fingerprint',fingerprint)

    async def close(self):
        await self.client.aclose()

    async def account_usage(self):
        now=self.clock()
        try:
            response=await self.client.get('/account/usage',params={'start':now.strftime('%Y-%m-01'),'all_keys':'true'})
            response.raise_for_status()
            payload=response.json(parse_float=Decimal)
            self.gate.account_observed(payload['total_cost'],now)
        except ConnectorError:
            raise
        except Exception:
            raise ConnectorError('Could not verify account-wide API spend. Live calls are paused.', 'usage_unverified')

    async def flights(self, ident, *, ident_type='designator', start=None, end=None, force=False):
        params={'max_pages':1,'ident_type':ident_type}
        if start: params['start']=start
        if end: params['end']=end
        key=json.dumps([ident,params],sort_keys=True)
        # Pull-to-refresh can bypass the 15min cache, but never the 60sec safety cache.
        cached=self.db.cached(key,self.clock(),60 if force else 900)
        if cached is not None:
            return cached
        await self.account_usage()  # Free endpoint, all keys, no unverified spending.
        reservation=self.gate.reserve('flights')
        try:
            response=await self.client.get('/flights/'+quote(ident,safe=''),params=params)
            response.raise_for_status()
            payload=response.json()
            if not isinstance(payload.get('flights'),list) or payload.get('num_pages') != 1 or len(payload['flights'])>15:
                self.db.set_meta('billing_block','Provider returned an unexpected page structure. Review usage and pricing before resuming.')
                raise ConnectorError('Unexpected API pagination. Further calls have been blocked.', 'billing_blocked')
            self.gate.finish(reservation,'success')
            fetched_at=self.clock().isoformat()
            for flight in payload['flights']:
                flight['_flightdeck_fetched_at']=fetched_at
            self.db.cache(key,self.clock(),payload['flights'])
            return payload['flights']
        except ConnectorError:
            self.gate.finish(reservation,'uncertain')
            raise
        except Exception:
            self.gate.finish(reservation,'failed_or_uncertain')
            # Never echo upstream URLs, headers, credentials or provider exception text.
            raise ConnectorError('The flight provider could not be reached. Your saved information has been kept.')
