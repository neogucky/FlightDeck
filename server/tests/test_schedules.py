import asyncio
from datetime import datetime, timedelta, timezone
from dataclasses import replace

import httpx
import pytest
from fastapi.testclient import TestClient

from flightdeck.config import Settings
from flightdeck.connector import AeroAPI, BudgetGate, ConnectorError
from flightdeck.database import Database
from flightdeck.main import create_app
from flightdeck.models import TripInput
from flightdeck.service import FlightService

NOW=datetime(2026,10,20,9,tzinfo=timezone.utc)
AIRPORTS={
    'LSZH':{'airport_code':'LSZH','code_icao':'LSZH','code_iata':'ZRH','name':'Zurich Airport','city':'Zurich','timezone':'Europe/Zurich'},
    'EDDH':{'airport_code':'EDDH','code_icao':'EDDH','code_iata':'HAM','name':'Hamburg Airport','city':'Hamburg','timezone':'Europe/Berlin'},
}


def scheduled(**changes):
    return dict({'ident':'SWR1052','ident_iata':'LX1052','ident_icao':'SWR1052','fa_flight_id':None,
        'origin':'LSZH','origin_icao':'LSZH','origin_iata':'ZRH','destination':'EDDH','destination_icao':'EDDH','destination_iata':'HAM',
        'scheduled_out':'2026-10-23T13:00:00Z','scheduled_in':'2026-10-23T14:25:00Z','aircraft_type':'BCS3'},**changes)


class Clock:
    now=NOW
    def __call__(self):return self.now


def fixture(tmp_path, *, budget=4_500_000, rows=None):
    clock=Clock();seen=[]
    settings=Settings(database=str(tmp_path/'user.sqlite3'),api_key='fake-schedule-test-key',budget_micro=budget)
    db=Database(settings.database)
    def respond(request):
        path=request.url.path;seen.append(path)
        if path.endswith('/account/usage'):return httpx.Response(200,json={'total_cost':0})
        if '/schedules/' in path:
            assert request.url.params['airline']=='LX'
            assert request.url.params['flight_number']=='1052'
            assert request.url.params['max_pages']=='1'
            assert 'cursor' not in request.url.params
            return httpx.Response(200,json={'num_pages':1,'scheduled':rows if rows is not None else [scheduled()]})
        if '/airports/' in path:return httpx.Response(200,json=AIRPORTS[path.rsplit('/',1)[-1]])
        if '/flights/' in path:
            if datetime.fromisoformat(scheduled()['scheduled_out'].replace('Z','+00:00'))>clock.now+timedelta(hours=47):
                return httpx.Response(200,json={'num_pages':1,'flights':[]})
            return httpx.Response(200,json={'num_pages':1,'flights':[dict(scheduled(),origin=AIRPORTS['LSZH'],destination=AIRPORTS['EDDH'],
                fa_flight_id='live-1052',registration='HB-TEST',status='Scheduled')]})
        raise AssertionError(path)
    api=AeroAPI(db,settings,clock,httpx.MockTransport(respond))
    service=FlightService(db,settings,api,clock)
    trip=service.create(TripInput.model_validate({'legs':[{'flight_number':'LX 1052','departure_date':'2026-10-23'}]}))
    return clock,seen,api,service,trip


def test_future_schedule_derives_route_local_times_and_aircraft_type_with_exact_budget(tmp_path):
    clock,seen,api,service,trip=fixture(tmp_path)
    async def run():
        assert await service.refresh(trip['id'])==[]
        snapshot=service.list()[0]['legs'][0]['snapshot']
        assert snapshot['source']=='schedule'
        assert snapshot['flight']['status']=='Schedule only'
        assert snapshot['flight']['origin']['iata']=='ZRH'
        assert snapshot['flight']['destination']['iata']=='HAM'
        assert snapshot['flight']['origin']['timezone']=='Europe/Zurich'
        assert snapshot['flight']['aircraft_type']=='BCS3'
        assert snapshot['flight']['registration'] is None and snapshot['inbound'] is None
        assert api.gate.summary()['reserved_usd']==0.10
        assert api.gate.summary()['request_count']==3
        assert not any('/flights/' in p for p in seen)
        initial=list(seen);clock.now+=timedelta(hours=1)
        assert await service.refresh()==[]
        assert seen==initial  # Repeated foreground polling buys no more schedule calls.
        await service.refresh(trip['id'],force=True)
        assert api.gate.summary()['reserved_usd']==0.14
        assert sum('/airports/' in p for p in seen)==2  # Pull refresh reuses airport metadata.
        await api.close()
    asyncio.run(run())


def test_schedule_transitions_to_live_even_when_daily_snapshot_is_fresh(tmp_path):
    clock,seen,api,service,trip=fixture(tmp_path)
    async def run():
        clock.now=datetime(2026,10,21,12,tzinfo=timezone.utc)
        await service.refresh()
        assert service.list()[0]['legs'][0]['snapshot']['source']=='schedule'
        clock.now=datetime(2026,10,21,15,tzinfo=timezone.utc)
        await service.refresh()
        snapshot=service.list()[0]['legs'][0]['snapshot']
        assert snapshot['source']=='live' and snapshot['flight']['registration']=='HB-TEST'
        assert any('/flights/LX1052' in p for p in seen)
        assert api.gate.summary()['reserved_usd']==0.12
        await api.close()
    asyncio.run(run())


def test_schedule_and_airport_calls_fail_closed_when_their_full_reservation_wont_fit(tmp_path):
    _,seen,api,service,trip=fixture(tmp_path,budget=35_000)
    async def run():
        issues=await service.refresh()
        assert issues[0]['code']=='budget_exhausted'
        assert seen==['/aeroapi/account/usage']
        assert api.gate.summary()['request_count']==0
        await api.close()
    asyncio.run(run())
    db=Database(str(tmp_path/'other.sqlite3'))
    gate=BudgetGate(db,replace(api.settings,budget_micro=60_000),lambda:NOW)
    gate.account_observed(0,NOW);gate.reserve('schedules')
    with pytest.raises(ConnectorError,match='Monthly safety'):gate.reserve('airports')
    assert gate.summary()['reserved_usd']==0.04


def test_ambiguous_schedule_never_chooses_a_route(tmp_path):
    _,_,api,service,trip=fixture(tmp_path,rows=[scheduled(),scheduled(scheduled_out='2026-10-23T17:00:00Z')])
    async def run():
        assert (await service.refresh())[0]['code']=='ambiguous_flight'
        leg=service.list()[0]['legs'][0]
        assert leg['snapshot'] is None and leg['issue']['code']=='ambiguous_flight'
        await api.close()
    asyncio.run(run())


def test_schedule_errors_survive_state_reads_and_throttled_refreshes(tmp_path):
    seen=[]
    def response(request):
        seen.append(request.url.path)
        if request.url.path.endswith('/account/usage'):return httpx.Response(200,json={'total_cost':0})
        return httpx.Response(403)
    settings=Settings(database=str(tmp_path/'accounts.sqlite3'))
    with TestClient(create_app(settings,transport=httpx.MockTransport(response),clock=lambda:NOW)) as client:
        session=client.post('/v1/auth/register',json={'username':'tester','password':'schedule test password'}).json()
        headers={'Authorization':'Bearer '+session['session_token']}
        assert client.put('/v1/account/api-key',headers=headers,json={'api_key':'fake-schedule-test-key'}).status_code==200
        state=client.post('/v1/trips',headers=headers,json={'legs':[{'flight_number':'LX1052','departure_date':'2026-10-23'}]}).json()
        issue=state['issues'][0]
        assert issue['code']=='provider_access_denied'
        before=len(seen)
        assert client.get('/v1/state',headers=headers).json()['issues']==[issue]
        assert client.post('/v1/refresh',headers=headers).json()['issues']==[issue]
        assert len(seen)==before
        assert state['trips'][0]['legs'][0]['issue']==issue
    with TestClient(create_app(settings,transport=httpx.MockTransport(response),clock=lambda:NOW)) as client:
        assert client.get('/v1/state',headers=headers).json()['issues']==[issue]


def test_schedule_date_matching_uses_verified_origin_timezone(tmp_path):
    _,_,api,service,trip=fixture(tmp_path,rows=[scheduled(scheduled_out='2026-10-22T23:30:00Z')])
    async def run():
        assert await service.refresh()==[]  # 01:30 on 23 October in Zurich.
        assert service.list()[0]['legs'][0]['snapshot']['flight']['scheduled_departure']=='2026-10-22T23:30:00Z'
        await api.close()
    asyncio.run(run())


def test_rate_limited_future_lookup_recovers_after_one_minute_and_clears_issue(tmp_path):
    clock=Clock();db=Database(str(tmp_path/'retry.sqlite3'))
    class Stub:
        attempts=0
        async def schedules(self,ident,day,**kwargs):
            self.attempts+=1
            if self.attempts==1:raise ConnectorError('Wait one minute.','rate_limited')
            return [scheduled()]
        async def airport(self,code):return AIRPORTS[code]
    stub=Stub();service=FlightService(db,Settings(api_key='fake'),stub,clock)
    service.create(TripInput.model_validate({'legs':[{'flight_number':'LX1052','departure_date':'2026-10-23'}]}))
    async def run():
        assert (await service.refresh())[0]['code']=='rate_limited'
        clock.now+=timedelta(seconds=30)
        assert (await service.refresh())[0]['code']=='rate_limited'
        assert stub.attempts==1
        clock.now+=timedelta(seconds=31)
        assert await service.refresh()==[]
        assert stub.attempts==2 and service.list()[0]['legs'][0]['issue'] is None
    asyncio.run(run())
