from datetime import datetime, timedelta, timezone
import asyncio
import copy
import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError
from flightdeck.main import create_app
from flightdeck.config import Settings
from flightdeck.models import TripInput
from flightdeck.service import match_flight, FlightService
from flightdeck.connector import ConnectorError
from flightdeck.database import Database

NOW=datetime(2026,10,19,12,tzinfo=timezone.utc)
TOKEN='test-token-'*4


def payload():
    return {'title':'Zurich via Munich','legs':[
        {'flight_number':' lh2055 ','departure_date':'2026-10-19','origin_iata':'ham','destination_iata':'muc'},
        {'flight_number':'LX1107','departure_date':'2026-10-19','origin_iata':'MUC','destination_iata':'ZRH'}]}


def test_authenticated_connected_trip_round_trip_and_persistence(tmp_path):
    settings=Settings(database=str(tmp_path/'test.sqlite3'),mode='demo')
    app=create_app(settings,clock=lambda:NOW)
    with TestClient(app) as client:
        session=client.post('/v1/auth/register',json={'username':'tester','password':'long-enough-test-password'}).json()
        headers={'Authorization':'Bearer '+session['session_token']}
        assert client.get('/health').status_code==200
        assert client.get('/v1/state').status_code==401
        assert client.post('/v1/refresh').status_code==401
        response=client.post('/v1/trips',json=payload(),headers=headers)
        assert response.status_code==201
        state=response.json();trip=state['trips'][0]
        assert len(trip['legs'])==2
        assert trip['legs'][0]['flight_number']=='LH2055'
        assert trip['legs'][0]['snapshot']['flight']['origin']['iata']=='HAM'
        assert state['usage']['reserved_usd']==0
    with TestClient(create_app(settings,clock=lambda:NOW)) as client:
        state=client.get('/v1/state',headers=headers).json()
        assert state['trips'][0]['id']==trip['id']
        assert client.delete('/v1/trips/'+trip['id'],headers=headers).json()['trips']==[]
        assert client.delete('/v1/trips/'+trip['id'],headers=headers).status_code==404


def test_validation_rejects_disconnected_duplicate_or_reversed_legs():
    p=payload();p['legs'][1]['origin_iata']='LHR'
    with pytest.raises(ValidationError):TripInput.model_validate(p)
    p=payload();p['legs'][1]['departure_date']='2026-10-18'
    with pytest.raises(ValidationError):TripInput.model_validate(p)
    p=payload();p['legs']=[p['legs'][0],p['legs'][0]]
    with pytest.raises(ValidationError):TripInput.model_validate(p)
    p=payload();p['legs'][0]['flight_number']='../../account'
    with pytest.raises(ValidationError):TripInput.model_validate(p)


def test_old_manual_history_survives_provider_retention(tmp_path):
    settings=Settings(database=str(tmp_path/'test.sqlite3'),mode='demo')
    app=create_app(settings,clock=lambda:NOW)
    with TestClient(app) as client:
        session=client.post('/v1/auth/register',json={'username':'tester','password':'long-enough-test-password'}).json()
        headers={'Authorization':'Bearer '+session['session_token']}
        p=payload();p['legs']=[p['legs'][0]];p['legs'][0]['departure_date']='2024-04-01'
        state=client.post('/v1/trips',headers=headers,json=p).json()
        leg=state['trips'][0]['legs'][0]
        assert leg['snapshot'] is None
        assert state['issues'][0]['code']=='outside_live_window'
        assert leg['origin_iata']=='HAM'
        app.state.accounts.tenant(state['account']['id']).save_snapshot(leg['id'],{'fetched_at':(NOW-timedelta(days=30)).isoformat(),'flight':{'private':'expired'}})
        state=client.get('/v1/state',headers=headers).json()
        assert state['trips'][0]['legs'][0]['snapshot'] is None
        assert state['trips'][0]['legs'][0]['flight_number']=='LH2055'


def raw(origin='HAM',destination='MUC',registration='D-AINQ'):
    return {'fa_flight_id':'a','ident_iata':'LH2055','scheduled_out':'2026-10-18T23:30:00Z',
        'origin':{'code_iata':origin,'timezone':'Europe/Berlin'},'destination':{'code_iata':destination,'timezone':'Europe/Berlin'},
        'registration':registration,'inbound_fa_flight_id':'inbound','status':'Scheduled'}


def test_matching_uses_local_departure_date_and_never_guesses():
    leg=TripInput.model_validate(payload()).legs[0].model_dump(mode='json')
    assert match_flight([raw()],leg)['fa_flight_id']=='a'
    assert match_flight([raw(origin='FRA')],leg) is None
    with pytest.raises(ConnectorError,match='More than one'):match_flight([raw(),raw()],leg)


def test_incoming_aircraft_swap_invalidates_previous_link_and_cache_ttl(tmp_path):
    settings=Settings(database=str(tmp_path/'test.sqlite3'),mode='live',api_key='not-a-real-key')
    db=Database(settings.database)
    class Stub:
        calls=0
        async def flights(self,ident,**kwargs):
            self.calls+=1
            if ident=='inbound':return [dict(raw('MUC','HAM','OTHER'),fa_flight_id='inbound')]
            return [raw()]
    stub=Stub();service=FlightService(db,settings,stub,lambda:NOW)
    p=payload();p['legs']=[p['legs'][0]];trip=service.create(TripInput.model_validate(p))
    asyncio.run(service.refresh(trip['id']))
    snapshot=db.snapshot(trip['legs'][0]['id'])
    assert snapshot['inbound'] is None
    assert 'assignment changed' in snapshot['inbound_note']
    asyncio.run(service.refresh(trip['id']))
    assert stub.calls==2


def test_shared_api_cache_does_not_make_old_data_appear_fresh(tmp_path):
    settings=Settings(database=str(tmp_path/'test.sqlite3'),mode='live',api_key='not-a-real-key')
    db=Database(settings.database)
    fetched=(NOW-timedelta(minutes=14)).isoformat()
    class Stub:
        async def flights(self,ident,**kwargs):
            return [dict(raw(),inbound_fa_flight_id=None,_flightdeck_fetched_at=fetched)]
    service=FlightService(db,settings,Stub(),lambda:NOW)
    p=payload();p['legs']=[p['legs'][0]]
    trip=service.create(TripInput.model_validate(p))
    asyncio.run(service.refresh(trip['id']))
    assert db.snapshot(trip['legs'][0]['id'])['fetched_at']==fetched
