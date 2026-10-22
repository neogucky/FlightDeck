import asyncio
from datetime import datetime,timedelta,timezone
import json
import sqlite3
from uuid import uuid4

import httpx
import pytest

from flightdeck.config import Settings
from flightdeck.connector import AeroAPI,BudgetGate,ConnectorError,verify_api_key
from flightdeck.database import Database

NOW=datetime(2026,10,22,12,tzinfo=timezone.utc)


def fixture(tmp_path,respond):
    settings=Settings(database=str(tmp_path/'usage.sqlite3'),api_key='private-test-key-never-log')
    db=Database(settings.database);clock=[NOW]
    api=AeroAPI(db,settings,lambda:clock[0],httpx.MockTransport(respond))
    return api,clock


def test_settlement_uses_a_fresh_disjoint_report_not_just_elapsed_time(tmp_path):
    checks=[];fail=[False]
    def respond(request):
        if request.url.path.endswith('/account/usage'):
            assert request.url.params['all_keys']=='true'
            through=datetime.fromisoformat(request.url.params['end']);checks.append(through)
            if fail[0]:return httpx.Response(503)
            return httpx.Response(200,json={'total_cost':0.005 if through>NOW else 0})
        return httpx.Response(200,json={'num_pages':1,'flights':[]})
    api,clock=fixture(tmp_path,respond)
    async def run():
        await api.flights('LX1055')
        assert api.gate.summary()['pending_estimated_usd']==0.01
        clock[0]+=timedelta(minutes=14)
        await api.account_usage()
        assert api.gate.summary()['pending_estimated_usd']==0.01
        clock[0]+=timedelta(minutes=2);fail[0]=True
        with pytest.raises(ConnectorError):await api.account_usage()
        assert api.gate.summary()['pending_estimated_usd']==0.01
        fail[0]=False;await api.account_usage()
        usage=api.gate.summary()
        assert usage['pending_estimated_usd']==0
        assert usage['conservative_used_usd']==usage['provider_reported_usd']==0.005
        assert usage['request_count']==1 and api.gate.history()[0]['conservative_used_usd']==0.005
        assert checks[-1]==clock[0]-timedelta(minutes=15)
        # Settlement survives a process restart and retains the complete audit ledger.
        reopened=BudgetGate(Database(api.db.path),api.settings,lambda:clock[0])
        assert reopened.summary()['pending_estimated_usd']==0
        with api.db.connect() as con:
            row=con.execute('SELECT * FROM reservations').fetchone()
            assert row['amount_micro']==10_000 and row['reconciled_at'] is not None
        await api.close()
    asyncio.run(run())


@pytest.mark.parametrize('failure',[httpx.ConnectError,httpx.ConnectTimeout,httpx.PoolTimeout])
def test_proven_pre_send_failure_adds_no_pending_cost(tmp_path,failure,caplog):
    def respond(request):
        if request.url.path.endswith('/account/usage'):return httpx.Response(200,json={'total_cost':0})
        raise failure('private-test-key-never-log',request=request)
    api,_=fixture(tmp_path,respond)
    async def run():
        with pytest.raises(ConnectorError) as caught:await api.flights('LX1055')
        assert caught.value.code=='provider_connection_error'
        assert api.gate.summary()['pending_estimated_usd']==0
        assert api.gate.summary()['request_count']==0
        assert 'private-test-key-never-log' not in str(caught.value)+caplog.text
        await api.close()
    asyncio.run(run())


def test_response_timeout_remains_pending_until_provider_report(tmp_path):
    def respond(request):
        if request.url.path.endswith('/account/usage'):return httpx.Response(200,json={'total_cost':0})
        raise httpx.ReadTimeout('response uncertain',request=request)
    api,clock=fixture(tmp_path,respond)
    async def run():
        with pytest.raises(ConnectorError) as caught:await api.flights('LX1055')
        assert caught.value.code=='provider_timeout'
        assert api.gate.summary()['pending_estimated_usd']==0.01
        clock[0]+=timedelta(minutes=16);await api.account_usage()
        assert api.gate.summary()['pending_estimated_usd']==0
        await api.close()
    asyncio.run(run())


@pytest.mark.parametrize(('status','code'),[(400,'provider_request_rejected'),(403,'provider_access_denied'),(404,'provider_not_found'),(429,'rate_limited'),(503,'provider_http_error')])
def test_http_errors_are_not_reported_as_connection_failures(tmp_path,status,code,caplog):
    def respond(request):
        if request.url.path.endswith('/account/usage'):return httpx.Response(200,json={'total_cost':0})
        return httpx.Response(status,json={'detail':'private-test-key-never-log'})
    api,_=fixture(tmp_path,respond)
    async def run():
        with pytest.raises(ConnectorError) as caught:await api.flights('LX1055')
        assert caught.value.code==code and caught.value.http_status==status
        assert str(status) in str(caught.value)
        assert 'could not be reached' not in str(caught.value)
        assert 'private-test-key-never-log' not in str(caught.value)+caplog.text
        assert api.gate.summary()['pending_estimated_usd']==0.01
        await api.close()
    asyncio.run(run())


def test_rate_gate_failure_before_send_does_not_increase_cost(tmp_path):
    def respond(request):
        assert request.url.path.endswith('/account/usage')
        return httpx.Response(200,json={'total_cost':0})
    api,_=fixture(tmp_path,respond)
    for _ in range(9):api.gate.claim_provider_call('usage')
    async def run():
        with pytest.raises(ConnectorError) as caught:await api.flights('LX1055')
        assert caught.value.code=='rate_limited'
        assert api.gate.summary()['pending_estimated_usd']==0
        await api.close()
    asyncio.run(run())


def test_old_ledger_is_migrated_and_settled_without_deleting_history(tmp_path):
    path=tmp_path/'old.sqlite3'
    with sqlite3.connect(path) as con:
        con.executescript('CREATE TABLE reservations(id TEXT PRIMARY KEY,month TEXT,amount_micro INTEGER,created_at TEXT,outcome TEXT,endpoint TEXT); CREATE TABLE account_usage(month TEXT PRIMARY KEY,high_water_micro INTEGER,checked_at TEXT);')
        con.execute('INSERT INTO reservations VALUES (?,?,?,?,?,?)',(str(uuid4())+':2026-10','2026-10',20_000,(NOW-timedelta(days=1)).isoformat(),'failed_or_uncertain','flights'))
        con.execute('INSERT INTO account_usage VALUES (?,?,?)',('2026-10',10_000,(NOW-timedelta(days=1)).isoformat()))
    db=Database(str(path));gate=BudgetGate(db,Settings(database=str(path)),lambda:NOW)
    assert gate.summary()['conservative_used_usd']==0.03
    gate.account_observed(0.01,NOW,covered_through=NOW-timedelta(minutes=15))
    assert gate.summary()['conservative_used_usd']==0.01
    assert gate.summary()['request_count']==1
    assert gate.history()[0]['reserved_usd']==0
    assert BudgetGate(Database(str(path)),gate.settings,lambda:NOW).summary()['conservative_used_usd']==0.01


def test_report_never_releases_an_in_flight_request(tmp_path):
    db=Database(str(tmp_path/'inflight.sqlite3'));clock=[NOW-timedelta(minutes=30)]
    gate=BudgetGate(db,Settings(database=db.path),lambda:clock[0]);gate.account_observed(0,clock[0])
    request=gate.reserve('flights');clock[0]=NOW
    gate.account_observed(0.005,NOW,covered_through=NOW-timedelta(minutes=15))
    assert gate.summary()['pending_estimated_usd']==0.01
    gate.finish(request,'success')
    gate.account_observed(0.005,NOW,covered_through=NOW-timedelta(minutes=15))
    assert gate.summary()['pending_estimated_usd']==0.01


def test_month_boundary_settles_each_period_without_charging_twice(tmp_path):
    def respond(request):
        if request.url.path.endswith('/account/usage'):
            return httpx.Response(200,json={'total_cost':0.005 if request.url.params['start'].startswith('2026-10') else 0})
        return httpx.Response(200,json={'num_pages':1,'flights':[]})
    api,clock=fixture(tmp_path,respond)
    async def run():
        clock[0]=datetime(2026,10,31,23,58,tzinfo=timezone.utc)
        await api.flights('LX1055')
        assert [r['month'] for r in api.gate.history()]==['2026-10']
        clock[0]=datetime(2026,11,1,0,20,tzinfo=timezone.utc);await api.account_usage()
        assert api.gate.summary()['conservative_used_usd']==0
        assert api.gate.summary()['request_count']==0
        october=next(r for r in api.gate.history() if r['month']=='2026-10')
        assert october['conservative_used_usd']==0.005 and october['request_count']==1
        await api.close()
    asyncio.run(run())


def test_key_verification_returns_the_requested_period_not_response_time(tmp_path):
    clock=[NOW]
    def respond(request):
        through=datetime.fromisoformat(request.url.params['end'])
        assert through==NOW-timedelta(minutes=15)
        clock[0]+=timedelta(seconds=12)
        return httpx.Response(200,json={'total_cost':0})
    db=Database(str(tmp_path/'key.sqlite3'));gate=BudgetGate(db,Settings(database=db.path),lambda:clock[0])
    async def run():
        cost,through=await verify_api_key('test-only-key',gate,transport=httpx.MockTransport(respond))
        assert cost==0 and through==NOW-timedelta(minutes=15)
    asyncio.run(run())


def test_provider_times_use_whole_second_utc_and_exact_report_coverage(tmp_path):
    seen=[]
    def respond(request):
        seen.append(request)
        if request.url.path.endswith('/account/usage'):return httpx.Response(200,json={'total_cost':0})
        assert request.url.params['start']=='2026-10-22T11:00:00Z'
        assert request.url.params['end']=='2026-10-24T05:50:14Z'
        return httpx.Response(200,json={'num_pages':1,'flights':[]})
    api,clock=fixture(tmp_path,respond);clock[0]=NOW.replace(microsecond=999999)
    async def run():
        await api.flights('LX1052',start='2026-10-22T13:00:00.123456+02:00',end='2026-10-24T05:50:14.321174+00:00')
        report=seen[0].url.params
        assert report['end']=='2026-10-22T11:45:00Z'
        assert datetime.fromisoformat(api.gate.summary()['reported_through'])==datetime.fromisoformat(report['end'])
        await api.close()
    asyncio.run(run())
