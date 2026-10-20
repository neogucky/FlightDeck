import asyncio
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import datetime, date, timedelta, timezone
from decimal import Decimal
import httpx
import pytest
from flightdeck.config import Settings
from flightdeck.database import Database
from flightdeck.connector import AeroAPI, BudgetGate, ConnectorError

NOW=datetime(2026,10,19,12,tzinfo=timezone.utc)


def setup(tmp_path, **kwargs):
    settings=Settings(database=str(tmp_path/'test.sqlite3'),**kwargs)
    db=Database(settings.database)
    gate=BudgetGate(db,settings,lambda:NOW)
    gate.account_observed(0,NOW)
    return settings,db,gate


def test_atomic_reservations_cannot_overrun_budget(tmp_path):
    _,db,gate=setup(tmp_path,budget_micro=30_000)
    def buy(_):
        try: gate.reserve('flights');return True
        except ConnectorError: return False
    with ThreadPoolExecutor(max_workers=12) as pool:
        results=list(pool.map(buy,range(24)))
    assert sum(results)==3
    assert gate.summary()['conservative_used_usd']==0.03
    assert BudgetGate(Database(db.path),gate.settings,lambda:NOW).summary()['request_count']==3


def test_reported_account_usage_is_added_not_subtracted(tmp_path):
    _,_,gate=setup(tmp_path,budget_micro=50_000)
    gate.reserve('flights')
    gate.account_observed(Decimal('0.0350001'),NOW)
    assert gate.summary()['conservative_used_usd']==pytest.approx(0.045001)
    with pytest.raises(ConnectorError,match='Monthly safety'):
        gate.reserve('flights')
    gate.account_observed(0,NOW)
    assert gate.summary()['provider_reported_usd']==pytest.approx(0.035001)


def test_stale_or_unknown_usage_blocks_calls(tmp_path):
    settings,db,gate=setup(tmp_path)
    later=BudgetGate(db,settings,lambda:NOW+timedelta(minutes=6))
    with pytest.raises(ConnectorError,match='recent account'):
        later.reserve('flights')
    for cost in [float('nan'),float('inf'),-1,None,'bad']:
        with pytest.raises(ConnectorError): gate.account_observed(cost,NOW)


def test_unknown_prices_expiration_and_higher_budget_fail_closed(tmp_path):
    _,_,gate=setup(tmp_path)
    with pytest.raises(ConnectorError,match='Unpriced'):gate.reserve('owner')
    expired=BudgetGate(gate.db,replace(gate.settings,pricing_valid_until=date(2026,10,18)),lambda:NOW)
    with pytest.raises(ConnectorError,match='expired'):expired.reserve('flights')
    with pytest.raises(ValueError):replace(gate.settings,budget_micro=5_000_000)


def test_month_boundary_reserves_both_months(tmp_path):
    settings,db,_=setup(tmp_path,budget_micro=10_000)
    first=datetime(2026,10,31,23,59,tzinfo=timezone.utc)
    gate=BudgetGate(db,settings,lambda:first);gate.account_observed(0,first)
    gate.reserve('flights')
    following=first+timedelta(minutes=2)
    gate=BudgetGate(db,settings,lambda:following);gate.account_observed(0,following)
    with pytest.raises(ConnectorError,match='Monthly safety'):gate.reserve('flights')
    assert gate.summary()['reserved_usd']==0.01


def test_provider_errors_and_timeouts_are_never_refunded(tmp_path):
    settings,db,_=setup(tmp_path)
    count=[]
    def response(request):
        count.append(request.url.path)
        if request.url.path.endswith('/account/usage'):return httpx.Response(200,json={'total_cost':0})
        raise httpx.ReadTimeout('uncertain',request=request)
    async def run():
        api=AeroAPI(db,settings,lambda:NOW,httpx.MockTransport(response))
        with pytest.raises(ConnectorError):await api.flights('LX1055')
        assert api.gate.summary()['reserved_usd']==0.01
        await api.close()
    asyncio.run(run())
    assert len(count)==2  # No retries, including ambiguous network failures.


def test_usage_failure_never_reaches_paid_endpoint(tmp_path):
    settings,db,_=setup(tmp_path)
    seen=[]
    def response(request):
        seen.append(request.url.path);return httpx.Response(503)
    async def run():
        api=AeroAPI(db,settings,lambda:NOW,httpx.MockTransport(response))
        with pytest.raises(ConnectorError,match='verify'):await api.flights('LX1055')
        assert api.gate.summary()['request_count']==0
        await api.close()
    asyncio.run(run());assert seen==['/aeroapi/account/usage']


def test_pagination_is_bounded_and_unexpected_pages_latch_block(tmp_path):
    settings,db,_=setup(tmp_path)
    def response(request):
        if request.url.path.endswith('/account/usage'):
            assert request.url.params['all_keys']=='true'
            return httpx.Response(200,json={'total_cost':0})
        assert request.url.params['max_pages']=='1'
        assert 'cursor' not in request.url.params
        return httpx.Response(200,json={'num_pages':2,'flights':[],'links':{'next':'/paid-next'}})
    async def run():
        api=AeroAPI(db,settings,lambda:NOW,httpx.MockTransport(response))
        with pytest.raises(ConnectorError,match='pagination'):await api.flights('LX1055')
        with pytest.raises(ConnectorError,match='unexpected page'):await api.flights('LX1056')
        assert api.gate.summary()['request_count']==1
        await api.close()
    asyncio.run(run())


def test_cached_results_do_not_spend_and_key_change_cannot_reset_budget(tmp_path):
    settings,db,_=setup(tmp_path)
    def response(request):
        if request.url.path.endswith('/account/usage'):return httpx.Response(200,json={'total_cost':0})
        return httpx.Response(200,json={'num_pages':1,'flights':[],'links':{'next':'/another-page'}})
    async def run():
        api=AeroAPI(db,settings,lambda:NOW,httpx.MockTransport(response))
        await api.flights('LX1055');await api.flights('LX1055',force=True)
        assert api.gate.summary()['request_count']==1
        await api.close()
        with pytest.raises(ValueError,match='key changed'):
            AeroAPI(db,replace(settings,api_key='different'),lambda:NOW)
    asyncio.run(run())


def test_concurrent_rate_gate(tmp_path):
    _,_,gate=setup(tmp_path)
    for _ in range(4):gate.reserve('flights')
    with pytest.raises(ConnectorError,match='rate limit'):gate.reserve('flights')
