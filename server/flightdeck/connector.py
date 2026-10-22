"""The ONLY module permitted to contact AeroAPI. No automatic retries or pagination."""
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_CEILING
import hashlib
import json
import logging
import re
import ssl
from urllib.parse import quote
from uuid import uuid4
import httpx
from .database import utcnow

BASE_URL = 'https://aeroapi.flightaware.com/aeroapi'
# Reviewed 2026-10-20. Reserve DOUBLE each published endpoint price.
FLIGHT_RESERVATION_MICRO = 10_000
RESERVATIONS_MICRO = {'flights':FLIGHT_RESERVATION_MICRO,'schedules':40_000,'airports':30_000}
# FlightAware publishes a 10-minute reporting cadence, without a watermark.
# Query a disjoint settled period with another 5 minutes of processing headroom.
REPORTING_DELAY = timedelta(minutes=15)
log=logging.getLogger(__name__)


def provider_datetime(value):
    """Use the provider's canonical UTC representation, without fractional seconds."""
    if isinstance(value,str): value=datetime.fromisoformat(value.replace('Z','+00:00'))
    if value.tzinfo is None: value=value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat(timespec='seconds').replace('+00:00','Z')


class ConnectorError(Exception):
    def __init__(self, message, code='provider_unavailable', *, http_status=None):
        self.message, self.code = message, code
        self.http_status=http_status
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

    def account_observed(self, cost, now, *, month=None, covered_through=None):
        try:
            amount=Decimal(str(cost))
            if not amount.is_finite() or amount < 0:
                raise ValueError()
            micro=int((amount*1_000_000).to_integral_value(rounding=ROUND_CEILING))
        except Exception:
            raise ConnectorError('Account usage could not be verified. Live calls are paused.', 'usage_unverified')
        with self.db.transaction() as con:
            month=month or now.strftime('%Y-%m')
            previous=con.execute('SELECT * FROM account_usage WHERE month=?',(month,)).fetchone()
            if previous and previous['covered_through'] and covered_through and datetime.fromisoformat(previous['covered_through'])>covered_through:
                return  # An older concurrent report cannot roll coverage backwards.
            # A replacement key must not erase spend already confirmed by the provider.
            if previous: micro=max(micro,previous['high_water_micro'])
            con.execute('''INSERT INTO account_usage(month,high_water_micro,checked_at,covered_through) VALUES (?,?,?,?)
                ON CONFLICT(month) DO UPDATE SET high_water_micro=excluded.high_water_micro,
                checked_at=excluded.checked_at,covered_through=excluded.covered_through''',
                (month,micro,now.isoformat(),covered_through.isoformat() if covered_through else None))
            if covered_through:
                con.execute('''UPDATE reservations SET reconciled_at=? WHERE month=? AND reconciled_at IS NULL
                    AND completed_at IS NOT NULL AND completed_at<?''',(now.isoformat(),month,covered_through.isoformat()))

    @staticmethod
    def pending(con, month):
        return con.execute("SELECT COALESCE(SUM(amount_micro),0),COUNT(*) FROM reservations WHERE month=? AND reconciled_at IS NULL AND outcome!='not_sent'",(month,)).fetchone()

    def unsettled_months(self):
        with self.db.connect() as con:
            return [r[0] for r in con.execute("SELECT DISTINCT month FROM reservations WHERE reconciled_at IS NULL AND outcome!='not_sent' AND month>=? AND month<? ORDER BY month DESC",((self.clock()-timedelta(days=330)).strftime('%Y-%m'),self.clock().strftime('%Y-%m')))]

    @staticmethod
    def request_count(con,month):
        return con.execute("SELECT COUNT(*) FROM reservations WHERE month=? AND substr(created_at,1,7)=? AND outcome!='not_sent'",(month,month)).fetchone()[0]

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
                local=self.pending(con,month)[0]
                account=con.execute('SELECT high_water_micro,checked_at FROM account_usage WHERE month=?',(month,)).fetchone()
                if month == now.strftime('%Y-%m') and (not account or (now-datetime.fromisoformat(account[1])).total_seconds()>300):
                    raise ConnectorError('A recent account-wide usage check is required.', 'usage_unverified')
                # The provider report and pending requests cover disjoint periods.
                effective=local+(account[0] if account else 0)
                if effective+amount > self.settings.budget_micro:
                    raise ConnectorError('Monthly safety budget reached. Saved flight information is still available.', 'budget_exhausted')
            for month in self.months(now):
                con.execute('INSERT INTO reservations(id,month,amount_micro,created_at,outcome,endpoint) VALUES (?,?,?,?,?,?)',
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
            con.execute('UPDATE reservations SET outcome=?,completed_at=? WHERE substr(id,1,36)=?',(outcome,self.clock().isoformat(),request_id))

    def summary(self):
        now=self.clock();month=now.strftime('%Y-%m')
        with self.db.connect() as con:
            local=self.pending(con,month)
            count=self.request_count(con,month)
            account=con.execute('SELECT high_water_micro,checked_at,covered_through FROM account_usage WHERE month=?',(month,)).fetchone()
        effective=local[0]+(account[0] if account else 0)
        return {'month':month,'limit_usd':self.settings.budget_micro/1_000_000,
                'hard_limit_usd':5.0,'reserved_usd':local[0]/1_000_000,
                'pending_estimated_usd':local[0]/1_000_000,'pending_request_count':local[1],
                'provider_reported_usd':(account[0] if account else 0)/1_000_000,
                'conservative_used_usd':effective/1_000_000,
                'remaining_usd':max(0,self.settings.budget_micro-effective)/1_000_000,
                'request_count':count,'pricing_valid_until':str(self.settings.pricing_valid_until),
                'blocked':bool(self.db.meta('billing_block')) or effective+FLIGHT_RESERVATION_MICRO>self.settings.budget_micro or now.date()>self.settings.pricing_valid_until,
                'account_checked_at':account[1] if account else None,
                'reported_through':account[2] if account else None,'reporting_delay_seconds':int(REPORTING_DELAY.total_seconds())}


    def history(self):
        with self.db.connect() as con:
            month=self.clock().strftime('%Y-%m')
            rows = con.execute('SELECT month FROM reservations WHERE month<=? UNION SELECT month FROM account_usage WHERE month<=? ORDER BY month DESC LIMIT 12',(month,month)).fetchall()
            result = []
            for row in rows:
                local = self.pending(con,row[0])
                count = self.request_count(con,row[0])
                reported = con.execute('SELECT high_water_micro FROM account_usage WHERE month=?',(row[0],)).fetchone()
                reported_micro = reported[0] if reported else 0
                result.append({'month':row[0],'reserved_usd':local[0]/1_000_000,'provider_reported_usd':reported_micro/1_000_000,
                               'conservative_used_usd':(local[0]+reported_micro)/1_000_000,'request_count':count})
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
        # One historical period per check also settles old ledgers after an upgrade.
        for month in [now.strftime('%Y-%m')]+self.gate.unsettled_months()[:1]:
            start=datetime.fromisoformat(month+'-01T00:00:00+00:00')
            end_month=(start+timedelta(days=32)).replace(day=1)
            through=min(end_month,max(start,now-REPORTING_DELAY)).replace(microsecond=0)
            self.gate.claim_provider_call('usage')
            try:
                response=await self.client.get('/account/usage',params={'start':provider_datetime(start),'end':provider_datetime(through if through>start else now),'all_keys':'true'})
                response.raise_for_status()
                payload=response.json(parse_float=Decimal)
                self.gate.account_observed(payload['total_cost'],self.clock(),month=month,covered_through=through)
            except ConnectorError:
                raise
            except httpx.HTTPStatusError as error:
                status=error.response.status_code
                log.warning('provider_request endpoint=usage http_status=%s code=usage_unverified',status)
                raise ConnectorError(f'Could not verify account usage: FlightAware returned HTTP {status}. Live calls are paused.','usage_unverified',http_status=status) from None
            except (httpx.ConnectError,httpx.ConnectTimeout,httpx.PoolTimeout):
                log.warning('provider_request endpoint=usage outcome=not_sent code=usage_connection_error')
                raise ConnectorError('Could not verify account usage: your server could not connect to FlightAware. No paid lookup was sent.','usage_unverified') from None
            except Exception:
                raise ConnectorError('Could not verify account-wide API spend. Live calls are paused.', 'usage_unverified') from None

    async def flights(self, ident, *, ident_type='designator', start=None, end=None, force=False):
        params={'max_pages':1,'ident_type':ident_type}
        if start: params['start']=provider_datetime(start)
        if end: params['end']=provider_datetime(end)
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
        sent=False
        outcome='uncertain'
        try:
            self.gate.claim_provider_call(endpoint)
            sent=True
            response=await self.client.get(path,params=params)
            response.raise_for_status()
            try: payload=response.json()
            except ValueError:
                raise ConnectorError('FlightAware returned an unreadable response. Your saved flight information has been kept.','provider_invalid_response') from None
            if not isinstance(payload,dict) or (result_field and (not isinstance(payload.get(result_field),list) or payload.get('num_pages') != 1 or len(payload[result_field])>15)):
                self.db.set_meta('billing_block','Provider returned an unexpected page structure. Review usage and pricing before resuming.')
                raise ConnectorError('Unexpected API pagination. Further calls have been blocked.', 'billing_blocked')
            fetched_at=self.clock().isoformat()
            result=payload[result_field] if result_field else payload
            for record in result if result_field else [result]:
                if not isinstance(record,dict): raise ConnectorError('FlightAware returned incomplete flight data.','provider_invalid_response')
                record['_flightdeck_fetched_at']=fetched_at
            outcome='success'
        except (httpx.ConnectError,httpx.ConnectTimeout,httpx.PoolTimeout) as error:
            outcome='not_sent'
            cause=error
            while cause is not None and not isinstance(cause,ssl.SSLCertVerificationError): cause=cause.__cause__
            code='provider_tls_error' if cause else 'provider_connection_error'
            message=('The server could not verify FlightAware’s TLS certificate. Check the server’s certificate store.' if cause else
                     'Your server could not connect to FlightAware. No new lookup cost was recorded.')
            log.warning('provider_request endpoint=%s outcome=not_sent code=%s',endpoint,code)
            raise ConnectorError(message,code) from None
        except httpx.HTTPStatusError as error:
            status=error.response.status_code
            if status in (401,403):
                code='provider_access_denied';message=f'FlightAware denied this lookup (HTTP {status}). Check your account’s API access.'
            elif status==429:
                code='rate_limited';message='FlightAware’s request rate limit was reached (HTTP 429). Please wait one minute.'
            elif status==400:
                code='provider_request_rejected';message='FlightAware rejected the lookup parameters (HTTP 400). Your saved flight is unchanged.'
            elif status==404:
                code='provider_not_found';message='FlightAware could not find this flight (HTTP 404). Your saved flight is unchanged.'
            else:
                code='provider_http_error';message=f'FlightAware returned an error (HTTP {status}). Your saved flight information has been kept.'
            log.warning('provider_request endpoint=%s outcome=uncertain http_status=%s code=%s',endpoint,status,code)
            raise ConnectorError(message,code,http_status=status) from None
        except httpx.TimeoutException:
            log.warning('provider_request endpoint=%s outcome=uncertain code=provider_timeout',endpoint)
            raise ConnectorError('FlightAware did not finish responding in time. Its usage report will confirm any charge. Your saved information has been kept.','provider_timeout') from None
        except httpx.RequestError:
            log.warning('provider_request endpoint=%s outcome=uncertain code=provider_response_interrupted',endpoint)
            raise ConnectorError('The response from FlightAware was interrupted. Your saved information has been kept.','provider_response_interrupted') from None
        except ConnectorError as error:
            if not sent: outcome='not_sent'
            log.warning('provider_request endpoint=%s outcome=%s code=%s',endpoint,outcome,error.code)
            raise
        finally:
            self.gate.finish(reservation,outcome)
        self.db.cache(key,self.clock(),result)
        return result


async def verify_api_key(key, gate, *, transport=None):
    """Validate using only the free usage endpoint; never return provider credentials."""
    gate.claim_provider_call('key_verification')
    try:
        async with httpx.AsyncClient(base_url=BASE_URL,headers={'x-apikey':key,'Accept':'application/json'},
                                    timeout=httpx.Timeout(15),follow_redirects=False,transport=transport) as client:
            now=gate.clock();start=now.replace(day=1,hour=0,minute=0,second=0,microsecond=0)
            through=max(start,now-REPORTING_DELAY).replace(microsecond=0)
            response = await client.get('/account/usage',params={'start':provider_datetime(start),'end':provider_datetime(through if through>start else now),'all_keys':'true'})
            if response.status_code in (401,403):
                raise ConnectorError('This AeroAPI key was not accepted. Check your FlightAware account.','invalid_api_key')
            response.raise_for_status()
            cost = Decimal(str(response.json(parse_float=Decimal)['total_cost']))
            if not cost.is_finite() or cost < 0:
                raise ValueError()
            return cost,through
    except ConnectorError:
        raise
    except Exception:
        raise ConnectorError('The key could not be verified with FlightAware. It has not been saved.','usage_unverified') from None
