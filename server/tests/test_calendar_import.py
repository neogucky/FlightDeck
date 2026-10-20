from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib

import httpx
import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from flightdeck.config import Settings
from flightdeck.database import Database
from flightdeck.main import create_app
from flightdeck.models import TripInput
from flightdeck.service import FlightService

NOW=datetime(2026,10,20,9,tzinfo=timezone.utc)


def payload():
    return {'import_id':hashlib.sha256(b'calendar trip').hexdigest(),'legs':[
        {'flight_number':'LH 1189','departure_date':'2026-10-20','calendar_departure':'2026-10-20T13:00:00+02:00',
         'calendar_arrival':'2026-10-20T14:30:00+02:00','calendar_time_zone':'Europe/Berlin'},
        {'flight_number':'LX 1107','departure_date':'2026-10-20','calendar_departure':'2026-10-20T15:00:00+02:00',
         'calendar_arrival':'2026-10-20T16:00:00+02:00','calendar_time_zone':'Europe/Berlin'}]}


def test_calendar_import_retries_and_other_import_ids_cannot_duplicate_or_buy_more_calls(tmp_path):
    calls=[]
    def respond(request):
        if request.url.path.endswith('/account/usage'):return httpx.Response(200,json={'total_cost':0})
        calls.append((request.url.path,request.headers['x-apikey']))
        number=request.url.path.rsplit('/',1)[-1]
        origin,dest=('HAM','FRA') if number=='LH1189' else ('FRA','ZRH')
        return httpx.Response(200,json={'num_pages':1,'flights':[{'ident_iata':number,'fa_flight_id':number,
            'scheduled_out':'2026-10-20T11:00:00Z','origin':{'code_iata':origin,'timezone':'Europe/Berlin'},
            'destination':{'code_iata':dest,'timezone':'Europe/Berlin'},'status':'Scheduled'}]})
    settings=Settings(database=str(tmp_path/'accounts.sqlite3'))
    with TestClient(create_app(settings,transport=httpx.MockTransport(respond),clock=lambda:NOW)) as client:
        def account(name):
            session=client.post('/v1/auth/register',json={'username':name,'password':'calendar test password'}).json()
            headers={'Authorization':'Bearer '+session['session_token']}
            assert client.put('/v1/account/api-key',headers=headers,json={'api_key':'fake-calendar-key-'+name}).status_code==200
            return headers
        alice=account('alice');bob=account('bobby')
        state=client.post('/v1/trips',headers=alice,json=payload()).json()
        original=state['trips'][0]
        assert len(original['legs'])==2 and original['legs'][0]['flight_number']=='LH1189'
        assert original['legs'][0]['calendar_departure']=='2026-10-20T13:00:00+02:00'
        assert len(calls)==2 and state['usage']['reserved_usd']==0.02
        for import_id in [payload()['import_id'],hashlib.sha256(b'other calendar').hexdigest()]:
            state=client.post('/v1/trips',headers=alice,json=dict(payload(),import_id=import_id)).json()
            assert len(state['trips'])==1 and state['trips'][0]['id']==original['id']
            assert len(calls)==2 and state['usage']['reserved_usd']==0.02
        other=client.post('/v1/trips',headers=bob,json=payload()).json()
        assert len(other['trips'])==1 and other['trips'][0]['id']!=original['id']
        assert len(calls)==4 and calls[-1][1]=='fake-calendar-key-bobby'


def test_concurrent_calendar_import_is_atomic(tmp_path):
    settings=Settings(database=str(tmp_path/'user.sqlite3'),mode='demo')
    service=FlightService(Database(settings.database),settings,clock=lambda:NOW)
    parsed=TripInput.model_validate(payload())
    with ThreadPoolExecutor(max_workers=8) as pool:
        results=list(pool.map(lambda _:service.create(parsed),range(16)))
    assert sum(t is not None for t in results)==1
    assert len(service.list())==1


def test_calendar_connections_use_instants_across_date_line():
    p=payload();first,second=p['legs']
    first.update(departure_date='2026-10-21',calendar_departure='2026-10-21T00:30:00+14:00',calendar_arrival='2026-10-21T02:30:00+14:00')
    second.update(departure_date='2026-10-20',calendar_departure='2026-10-20T03:30:00-10:00',calendar_arrival='2026-10-20T04:30:00-10:00')
    assert TripInput.model_validate(p).legs[0].departure_date>TripInput.model_validate(p).legs[1].departure_date


@pytest.mark.parametrize('change',[
    {'calendar_arrival':'2026-10-20T12:00:00+02:00'},
    {'calendar_departure':'2026-10-21T13:00:00+02:00'},
    {'calendar_departure':'2026-10-20T13:00:00'},
    {'calendar_time_zone':None},
])
def test_invalid_calendar_times_are_rejected(change):
    p=payload();p['legs'][0].update(change)
    with pytest.raises(ValidationError):TripInput.model_validate(p)
