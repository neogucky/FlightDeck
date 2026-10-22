"""Verify paid provider traffic at tracking-window boundaries; no real API calls."""
import asyncio
from datetime import datetime,timedelta,timezone

import httpx

from flightdeck.config import Settings
from flightdeck.connector import AeroAPI
from flightdeck.database import Database
from flightdeck.models import TripInput
from flightdeck.service import FlightService,normalize

NOW=datetime(2026,10,22,12,tzinfo=timezone.utc)


def setup(tmp_path, hours, *, age=180):
    clock=[NOW];seen=[];status=[200]
    departures={f'LX{100+i}':NOW+timedelta(hours=h) for i,h in enumerate(hours)}
    def raw(number):
        inbound=number.startswith('inbound-');number=number.removeprefix('inbound-')
        departure=departures[number]-(timedelta(hours=3) if inbound else timedelta())
        airport=lambda code:{'code_iata':code,'timezone':'UTC'}
        return {'ident_iata':number,'fa_flight_id':('inbound-' if inbound else '')+number,
                'inbound_fa_flight_id':None if inbound else 'inbound-'+number,
                'scheduled_out':departure.isoformat(),'scheduled_in':(departure+timedelta(hours=1)).isoformat(),
                'origin':airport('HAM' if inbound else 'ZRH'),'destination':airport('ZRH' if inbound else 'MUC'),
                'registration':'HB-TEST','status':'Scheduled'}
    def respond(request):
        seen.append(request.url.path)
        if request.url.path.endswith('/account/usage'):return httpx.Response(200,json={'total_cost':0})
        assert '/flights/' in request.url.path
        if status[0]!=200:return httpx.Response(status[0])
        return httpx.Response(200,json={'num_pages':1,'flights':[raw(request.url.path.rsplit('/',1)[-1])]})
    settings=Settings(database=str(tmp_path/'tracking.sqlite3'),api_key='fake-window-test-key')
    db=Database(settings.database);api=AeroAPI(db,settings,lambda:clock[0],httpx.MockTransport(respond))
    service=FlightService(db,settings,api,lambda:clock[0])
    trip=service.create(TripInput.model_validate({'legs':[{'flight_number':n,'departure_date':d.date().isoformat()} for n,d in departures.items()]}))
    for leg in trip['legs']:
        db.save_snapshot(leg['id'],{'fetched_at':(NOW-timedelta(minutes=age)).isoformat(),
            'source':'live','flight':normalize(raw(leg['flight_number'])),'inbound':None,'inbound_note':None})
    paid=lambda:[p for p in seen if '/flights/' in p]
    return clock,seen,status,api,service,trip,paid


def test_no_automatic_calls_before_48h_then_outbound_and_inbound_every_two_hours(tmp_path):
    clock,seen,_,api,service,_,paid=setup(tmp_path,[49])
    async def run():
        await service.refresh();assert seen==[]
        assert service.list()[0]['legs'][0]['automatic_refresh_interval_seconds']==0
        # At exactly 48h the provider may still supply schedule-only data; inspect
        # the policy here, then exercise live traffic once inside its 47h range.
        clock[0]+=timedelta(hours=1)
        assert service.list()[0]['legs'][0]['automatic_refresh_interval_seconds']==7200
        clock[0]+=timedelta(hours=1)
        await service.refresh();assert len(paid())==2
        clock[0]+=timedelta(hours=2,seconds=-1)
        await service.refresh();assert len(paid())==2
        clock[0]+=timedelta(seconds=1)
        await service.refresh();assert len(paid())==4
        await api.close()
    asyncio.run(run())


def test_switches_to_fifteen_minutes_at_exactly_six_hours(tmp_path):
    clock,seen,_,api,service,_,paid=setup(tmp_path,[7],age=60)
    async def run():
        await service.refresh();assert seen==[]
        clock[0]+=timedelta(hours=1)
        assert service.list()[0]['legs'][0]['automatic_refresh_interval_seconds']==900
        await service.refresh();assert len(paid())==2
        clock[0]+=timedelta(minutes=15,seconds=-1)
        await service.refresh();assert len(paid())==2
        clock[0]+=timedelta(seconds=1)
        await service.refresh();assert len(paid())==4
        await api.close()
    asyncio.run(run())


def test_each_connection_uses_its_own_departure_and_manual_refresh_bypasses_interval(tmp_path):
    clock,_,_,api,service,trip,paid=setup(tmp_path,[5,9],age=40)
    async def run():
        await service.refresh()
        assert paid()==['/aeroapi/flights/LX100','/aeroapi/flights/inbound-LX100']
        legs=service.list()[0]['legs']
        assert [l['automatic_refresh_interval_seconds'] for l in legs]==[900,7200]
        await service.refresh(trip['id'],force=True)
        # The first leg shares the 60s safety gate; the second can be requested now.
        assert paid()[-2:]==['/aeroapi/flights/LX101','/aeroapi/flights/inbound-LX101']
        assert len(paid())==4
        # Arrived flights do not generate automatic updates.
        first=trip['legs'][0];snapshot=service.db.snapshot(first['id'])
        snapshot['flight']['actual_arrival']=clock[0].isoformat();service.db.save_snapshot(first['id'],snapshot)
        clock[0]+=timedelta(minutes=16)
        await service.refresh();assert len(paid())==4
        await api.close()
    asyncio.run(run())


def test_failed_lookups_do_not_retry_more_often_than_the_selected_interval(tmp_path):
    clock,_,status,api,service,trip,paid=setup(tmp_path,[24])
    status[0]=503
    async def run():
        await service.refresh();assert len(paid())==1
        clock[0]+=timedelta(minutes=5)
        await service.refresh();assert len(paid())==1
        clock[0]+=timedelta(minutes=115)
        await service.refresh();assert len(paid())==2
        clock[0]+=timedelta(seconds=61)
        status[0]=200
        await service.refresh(trip['id'],force=True);assert len(paid())==4
        assert service.issues()==[]
        await api.close()
    asyncio.run(run())


def test_calendar_time_is_used_when_no_snapshot_is_available(tmp_path):
    _,_,_,api,service,trip,_=setup(tmp_path,[24])
    leg=trip['legs'][0]
    assert service.refresh_interval(leg,None)==0
    leg['calendar_departure']=(NOW+timedelta(hours=24)).isoformat()
    assert service.refresh_interval(leg,None)==7200
    leg['calendar_departure']=(NOW+timedelta(hours=6)).isoformat()
    assert service.refresh_interval(leg,None)==900
    asyncio.run(api.close())


def test_failed_initial_resolution_is_not_repeated_without_a_verified_departure(tmp_path):
    clock,_,status,api,service,trip,paid=setup(tmp_path,[24])
    with service.db.connect() as db:db.execute('DELETE FROM snapshots')
    status[0]=503
    async def run():
        await service.refresh();assert len(paid())==1
        clock[0]+=timedelta(hours=2)
        await service.refresh();assert len(paid())==1
        status[0]=200
        await service.refresh(trip['id'],force=True);assert len(paid())==3
        assert service.list()[0]['legs'][0]['automatic_refresh_interval_seconds']==7200
        await api.close()
    asyncio.run(run())
