"""The ONLY module permitted to contact AeroAPI. No automatic retries or pagination."""
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_CEILING
import hashlib
import json
import re
from urllib.parse import quote
from uuid import uuid4
import httpx
from .database import utcnow

BASE_URL = 'https://aeroapi.flightaware.com/aeroapi'
# Reviewed 2026-10-20. Reserve DOUBLE each published endpoint price.
FLIGHT_RESERVATION_MICRO = 10_000
RESERVATIONS_MICRO = {'flights':FLIGHT_RESERVATION_MICRO,'schedules':40_000,'airports':30_000}


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
        if endpoint not in RESERVATIONS_MICRO:
            raise ConnectorError('Unpriced endpoint blocked.', 'pricing_unverified')
        amount = RESERVATIONS_MICRO[endpoint]
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
                if effective+amount > self.settings.budget_micro:
                    raise ConnectorError('Monthly safety budget reached. Saved flight information is still available.', 'budget_exhausted')
            for month in self.months(now):
                con.execute('INSERT INTO reservations VALUES (?,?,?,?,?,?)',
                    (request_id+':'+month,month,amount,now.isoformat(),'reserved',endpoint))
        return request_id

    def claim_provider_call(self, kind):
        now = self.clock()
        with self.db.transaction() as con:
            cutoff = (now-timedelta(seconds=60)).isoformat()
            con.execute('DELETE FROM provider_attempts WHERE created_at < ?',(cutoff,))
            if con.execute('SELECT COUNT(*) FROM provider_attempts').fetchone()[0] >= 10:
                raise ConnectorError('API request rate reached. Please wait one minute.','rate_limited')
            con.execute('INSERT INTO provider_attempts VALUES (?,?,?)',(str(uuid4()),now.isoformat(),kind))

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


    def history(self):
        with self.db.connect() as con:
            rows = con.execute('SELECT month FROM reservations UNION SELECT month FROM account_usage ORDER BY month DESC LIMIT 12').fetchall()
            result = []
            for row in rows:
                local = con.execute('SELECT COALESCE(SUM(amount_micro),0),COUNT(*) FROM reservations WHERE month=?',(row[0],)).fetchone()
                reported = con.execute('SELECT high_water_micro FROM account_usage WHERE month=?',(row[0],)).fetchone()
                reported_micro = reported[0] if reported else 0
                result.append({'month':row[0],'reserved_usd':local[0]/1_000_000,'provider_reported_usd':reported_micro/1_000_000,
                               'conservative_used_usd':(local[0]+reported_micro)/1_000_000,'request_count':local[1]})
        return result


class AeroAPI:
    def __init__(self, db, settings, clock=utcnow, transport=None):
        self.db,self.settings,self.clock=db,settings,clock
        self.gate=BudgetGate(db,settings,clock)
        # Swapping keys cannot reset the durable ledger; switching keys in an existing DB fails closed.
        fingerprint=hashlib.sha256(settings.api_key.encode()).hexdigest()
        previous=db.meta('api_key_fingerprint')
        if previous and previous != fingerprint:
            raise ValueError('The API key changed. Reconcile billing before switching accounts; do not reset the ledger.')
        db.set_meta('api_key_fingerprint',fingerprint)
        self.client=httpx.AsyncClient(base_url=BASE_URL,headers={'x-apikey':settings.api_key,'Accept':'application/json'},
                                     timeout=httpx.Timeout(15),follow_redirects=False,transport=transport)

    async def close(self):
        await self.client.aclose()

    async def account_usage(self):
        now=self.clock()
        self.gate.claim_provider_call('usage')
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
        return await self._lookup('/flights/'+quote(ident,safe=''),params,'flights','flights',force=force)

    async def schedules(self, ident, day, *, force=False):
        # Never issue an unfiltered all-airline schedule request. Suffixes cannot
        # be represented by the provider's integer flight_number parameter.
        match=re.fullmatch(r'([A-Z]{3}|[A-Z0-9]{2})([0-9]{1,4})',ident)
        if not match:
            raise ConnectorError('Advance schedules require a flight number such as LX1052. Live lookup will be available closer to departure.','schedule_identifier_unsupported')
        start=day-timedelta(days=1);end=day+timedelta(days=2)
        params={'airline':match[1],'flight_number':int(match[2]),'max_pages':1,
                'include_codeshares':'true','include_regional':'true'}
        return await self._lookup(f'/schedules/{start}/{end}',params,'schedules','scheduled',ttl=86400,force=force)

    async def airport(self, code):
        if not isinstance(code,str) or not re.fullmatch(r'[A-Z0-9]{3,4}',code):
            raise ConnectorError('The schedule returned an invalid airport code.','schedule_unresolved')
        # Airport metadata is static; a pull-to-refresh never bypasses this cache.
        return await self._lookup('/airports/'+quote(code,safe=''),{},'airports',None,ttl=86400)

    async def _lookup(self, path, params, endpoint, result_field, *, ttl=900, force=False):
        key=json.dumps([path,params],sort_keys=True)
        # Pull-to-refresh can bypass the 15min cache, but never the 60sec safety cache.
        cached=self.db.cached(key,self.clock(),60 if force else ttl)
        if cached is not None:
            return cached
        await self.account_usage()  # Free endpoint, all keys, no unverified spending.
        reservation=self.gate.reserve(endpoint)
        try:
            self.gate.claim_provider_call(endpoint)
            response=await self.client.get(path,params=params)
            if response.status_code in (401,403):
                raise ConnectorError('Your AeroAPI account did not allow this lookup. Check API access in FlightAware; your flight is still saved.','provider_access_denied')
            response.raise_for_status()
            payload=response.json()
            if not isinstance(payload,dict) or (result_field and (not isinstance(payload.get(result_field),list) or payload.get('num_pages') != 1 or len(payload[result_field])>15)):
                self.db.set_meta('billing_block','Provider returned an unexpected page structure. Review usage and pricing before resuming.')
                raise ConnectorError('Unexpected API pagination. Further calls have been blocked.', 'billing_blocked')
            self.gate.finish(reservation,'success')
            fetched_at=self.clock().isoformat()
            result=payload[result_field] if result_field else payload
            for record in result if result_field else [result]:
                if not isinstance(record,dict): raise ConnectorError('The provider returned incomplete flight data.','provider_unavailable')
                record['_flightdeck_fetched_at']=fetched_at
            self.db.cache(key,self.clock(),result)
            return result
        except ConnectorError:
            self.gate.finish(reservation,'uncertain')
            raise
        except Exception:
            self.gate.finish(reservation,'failed_or_uncertain')
            # Never echo upstream URLs, headers, credentials or provider exception text.
            raise ConnectorError('The flight provider could not be reached. Your saved information has been kept.')


async def verify_api_key(key, gate, *, transport=None):
    """Validate using only the free usage endpoint; never return provider credentials."""
    gate.claim_provider_call('key_verification')
    try:
        async with httpx.AsyncClient(base_url=BASE_URL,headers={'x-apikey':key,'Accept':'application/json'},
                                    timeout=httpx.Timeout(15),follow_redirects=False,transport=transport) as client:
            response = await client.get('/account/usage',params={'start':gate.clock().strftime('%Y-%m-01'),'all_keys':'true'})
            if response.status_code in (401,403):
                raise ConnectorError('This AeroAPI key was not accepted. Check your FlightAware account.','invalid_api_key')
            response.raise_for_status()
            cost = Decimal(str(response.json(parse_float=Decimal)['total_cost']))
            if not cost.is_finite() or cost < 0:
                raise ValueError()
            return cost
    except ConnectorError:
        raise
    except Exception:
        raise ConnectorError('The key could not be verified with FlightAware. It has not been saved.','usage_unverified') from None
