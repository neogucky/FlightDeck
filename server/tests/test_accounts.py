from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
import json
import sqlite3
import httpx
import pytest
from fastapi.testclient import TestClient
from cryptography.fernet import Fernet

from flightdeck.main import create_app
from flightdeck.accounts import Accounts, AccountError, fingerprint
from flightdeck.config import Settings
from flightdeck.connector import BudgetGate, ConnectorError

NOW = datetime(2026,10,19,12,tzinfo=timezone.utc)
PASSWORD = 'a long test-only password'
KEY_A = 'test-only-alice-provider-key'
KEY_B = 'test-only-bob-provider-key'


def credentials(name): return {'username':name,'password':PASSWORD}
def register(client,name):
    response = client.post('/v1/auth/register',json=credentials(name))
    assert response.status_code == 201,response.text
    session = response.json()
    return session,{'Authorization':'Bearer '+session['session_token']}

def itinerary(number='LH2055'):
    return {'legs':[{'flight_number':number,'departure_date':'2026-10-19','origin_iata':'HAM','destination_iata':'MUC'}]}


def provider(seen):
    def respond(request):
        key = request.headers['x-apikey'];seen.append((key,request.url.path))
        if key.startswith('invalid'): return httpx.Response(401)
        if request.url.path.endswith('/account/usage'):
            return httpx.Response(200,json={'total_cost':0.01 if key == KEY_A else 0})
        return httpx.Response(200,json={'num_pages':1,'flights':[{
            'fa_flight_id':'alice-flight' if key == KEY_A else 'bob-flight','ident_iata':'LH2055','scheduled_out':'2026-10-19T13:00:00Z',
            'scheduled_in':'2026-10-19T14:20:00Z','origin':{'code_iata':'HAM','city':'Hamburg','timezone':'Europe/Berlin'},
            'destination':{'code_iata':'MUC','city':'Munich','timezone':'Europe/Berlin'},'status':'Scheduled',
            'registration':'ALICE-PLANE' if key == KEY_A else 'BOB-PLANE','aircraft_type':'A20N'}]})
    return httpx.MockTransport(respond)


def test_sessions_persist_expire_and_revoke_without_storing_plain_tokens(tmp_path):
    settings = Settings(database=str(tmp_path/'accounts.sqlite3'),mode='demo')
    with TestClient(create_app(settings,clock=lambda:NOW)) as client:
        session,headers = register(client,'Alice')
        assert session['account']['username'] == 'alice'
        assert client.get('/v1/state',headers=headers).status_code == 200
        assert client.get('/v1/state',headers={'Authorization':'Bearer wrong'}).status_code == 401
        response = client.post('/v1/auth/login',json={'username':'alice','password':'wrong-but-long-password'})
        assert response.status_code == 401
        token2 = client.post('/v1/auth/login',json=credentials('ALICE')).json()['session_token']
        assert token2 != session['session_token']
        with sqlite3.connect(settings.database) as con:
            assert con.execute('SELECT password_hash FROM users').fetchone()[0].startswith('$argon2id$')
            assert con.execute('SELECT digest FROM sessions WHERE digest=?',(fingerprint(session['session_token']),)).fetchone()
        assert session['session_token'].encode() not in Path(settings.database).read_bytes()
    with TestClient(create_app(settings,clock=lambda:NOW+timedelta(days=1))) as client:
        assert client.get('/v1/state',headers=headers).status_code == 200
        assert client.post('/v1/auth/logout',headers=headers).status_code == 204
        assert client.get('/v1/state',headers=headers).status_code == 401
        second={'Authorization':'Bearer '+token2}
        assert client.get('/v1/state',headers=second).status_code == 200
        assert client.post('/v1/auth/logout-all',headers=second).status_code == 204
        assert client.get('/v1/state',headers=second).status_code == 401
    with TestClient(create_app(settings,clock=lambda:NOW+timedelta(days=91))) as client:
        assert client.get('/v1/state',headers=headers).status_code == 401


def test_cross_account_trips_refresh_delete_and_cache_are_isolated(tmp_path):
    settings = Settings(database=str(tmp_path/'accounts.sqlite3'))
    seen=[];app=create_app(settings,clock=lambda:NOW,transport=provider(seen))
    with TestClient(app) as client:
        alice,a=register(client,'alice');bob,b=register(client,'bob')
        assert client.put('/v1/account/api-key',headers=a,json={'api_key':KEY_A}).status_code == 200
        assert client.put('/v1/account/api-key',headers=b,json={'api_key':KEY_B}).status_code == 200
        state_a=client.post('/v1/trips',headers=a,json=itinerary()).json();trip=state_a['trips'][0]
        assert trip['legs'][0]['snapshot']['flight']['registration']=='ALICE-PLANE'
        assert client.get('/v1/state',headers=b).json()['trips']==[]
        assert client.delete('/v1/trips/'+trip['id'],headers=b).status_code==404
        assert client.post('/v1/refresh?trip_id='+trip['id'],headers=b).status_code==404
        state_b=client.post('/v1/trips',headers=b,json=itinerary()).json()
        assert state_b['trips'][0]['legs'][0]['snapshot']['flight']['registration']=='BOB-PLANE'
        # Same flight number requires a separate request with Bob's key, never Alice's cache.
        assert sum(1 for k,p in seen if k==KEY_A and '/flights/' in p)==1
        assert sum(1 for k,p in seen if k==KEY_B and '/flights/' in p)==1
        ua=client.get('/v1/usage',headers=a).json();ub=client.get('/v1/usage',headers=b).json()
        assert ua['usage']['reserved_usd']==ub['usage']['reserved_usd']==0.01
        assert ua['usage']['provider_reported_usd']==0.01
        assert ub['usage']['provider_reported_usd']==0
        assert ua['history'][0]['request_count']==1
        assert KEY_A not in json.dumps(state_a) and KEY_B not in json.dumps(state_b)
        assert 'password' not in json.dumps(state_a)
        # Request data may not choose another user's account/credential/storage.
        assert client.post('/v1/trips',headers=b,json=dict(itinerary(),user_id=alice['account']['id'])).json()['account']['id']==bob['account']['id']


def test_keys_encrypted_write_only_owner_bound_and_not_echoed_on_errors(tmp_path):
    settings=Settings(database=str(tmp_path/'accounts.sqlite3'));app=create_app(settings,clock=lambda:NOW,transport=provider([]))
    with TestClient(app) as client:
        alice,a=register(client,'alice');bob,b=register(client,'bob')
        assert client.put('/v1/account/api-key',headers=a,json={'api_key':KEY_A}).status_code==200
        assert client.get('/v1/account/api-key',headers=a).status_code==405
        assert client.put('/v1/account/api-key',headers=b,json={'api_key':KEY_A}).status_code==409
        assert not client.get('/v1/account',headers=b).json()['has_api_key']
        for body in [{'api_key':'secret short'}, {'api_key':KEY_B+'\n'}]:
            response=client.put('/v1/account/api-key',headers=a,json=body)
            assert response.status_code==422 and body['api_key'] not in response.text
        response=client.post('/v1/auth/register',json={'username':'invalid','password':'secret'})
        assert response.status_code==422 and 'secret' not in response.text
        with app.state.accounts.db.connect() as con:
            cipher=con.execute('SELECT key_cipher FROM users WHERE id=?',(alice['account']['id'],)).fetchone()[0]
        assert KEY_A not in cipher
        with pytest.raises(AccountError):app.state.accounts.vault.decrypt(bob['account']['id'],cipher)
        for path in tmp_path.rglob('*.sqlite3*'):
            assert KEY_A.encode() not in path.read_bytes()
        assert client.delete('/v1/account/api-key',headers=a).status_code==200
        assert client.put('/v1/account/api-key',headers=b,json={'api_key':KEY_A}).status_code==409
        assert client.put('/v1/account/api-key',headers=a,json={'api_key':'invalid-test-key'}).status_code==400
        assert not client.get('/v1/account',headers=a).json()['has_api_key']


def test_replacing_or_removing_keys_never_resets_spending(tmp_path):
    settings=Settings(database=str(tmp_path/'accounts.sqlite3'));app=create_app(settings,clock=lambda:NOW,transport=provider([]))
    with TestClient(app) as client:
        _,a=register(client,'alice')
        client.put('/v1/account/api-key',headers=a,json={'api_key':KEY_A})
        client.post('/v1/trips',headers=a,json=itinerary())
        before=client.get('/v1/usage',headers=a).json()
        client.delete('/v1/account/api-key',headers=a)
        client.put('/v1/account/api-key',headers=a,json={'api_key':'replacement-test-key'})
        after=client.get('/v1/usage',headers=a).json()
        assert after['usage']['reserved_usd']==before['usage']['reserved_usd']==0.01
        assert after['usage']['provider_reported_usd']>=before['usage']['provider_reported_usd']
        assert after['history']==before['history']


def test_missing_wrong_master_key_registration_closed_and_legacy_fail_closed(tmp_path):
    settings=Settings(database=str(tmp_path/'accounts.sqlite3'));app=create_app(settings,clock=lambda:NOW,transport=provider([]))
    with TestClient(app) as client:
        _,a=register(client,'alice');client.put('/v1/account/api-key',headers=a,json={'api_key':KEY_A})
    original=settings.key_file.read_bytes();settings.key_file.unlink()
    with pytest.raises(RuntimeError,match='Encryption key missing'):create_app(settings)
    settings.key_file.write_bytes(Fernet.generate_key())
    with pytest.raises(AccountError):create_app(settings)
    settings.key_file.write_bytes(original)
    with TestClient(create_app(replace(settings,registration_open=False))) as client:
        assert client.post('/v1/auth/register',json=credentials('newuser')).status_code==403
        assert client.post('/v1/auth/login',json=credentials('alice')).status_code==200
    from flightdeck.database import Database
    legacy=Database(str(tmp_path/'legacy.sqlite3'));legacy.save_trip({'id':'old','created_at':NOW.isoformat(),'legs':[]})
    with pytest.raises(RuntimeError,match='Legacy shared'):create_app(replace(settings,database=legacy.path))


def test_auth_rate_limits_body_size_and_budget_exhaustion_are_per_account(tmp_path):
    settings=Settings(database=str(tmp_path/'accounts.sqlite3'),budget_micro=20_000)
    app=create_app(settings,clock=lambda:NOW,transport=provider([]))
    with TestClient(app) as client:
        alice,a=register(client,'alice');bob,b=register(client,'bob')
        for _ in range(9):assert client.post('/v1/auth/login',json={'username':'alice','password':'bad-test-password'}).status_code==401
        assert client.post('/v1/auth/login',json=credentials('alice')).status_code==429
        assert client.post('/v1/auth/login',json=credentials('bob')).status_code==200
        assert client.post('/v1/auth/login',content=b'x'*65537,headers={'Content-Type':'application/json'}).status_code==413
        client.put('/v1/account/api-key',headers=a,json={'api_key':KEY_A})
        client.put('/v1/account/api-key',headers=b,json={'api_key':KEY_B})
        # Alice's reported external usage plus one reservation reaches her ceiling.
        assert client.post('/v1/trips',headers=a,json=itinerary()).json()['usage']['blocked']
        assert not client.post('/v1/trips',headers=b,json=itinerary()).json()['usage']['blocked']
        assert client.get('/v1/state',headers=a).headers['cache-control']=='no-store'


def test_concurrent_users_and_all_provider_calls_have_separate_durable_limits(tmp_path):
    accounts=Accounts(Settings(database=str(tmp_path/'accounts.sqlite3')),clock=lambda:NOW)
    a=accounts.register('alice',PASSWORD)['account']['id'];b=accounts.register('bob',PASSWORD)['account']['id']
    ga=BudgetGate(accounts.tenant(a),replace(accounts.settings,budget_micro=30_000),lambda:NOW)
    gb=BudgetGate(accounts.tenant(b),replace(accounts.settings,budget_micro=50_000),lambda:NOW)
    for gate in [ga,gb]:gate.account_observed(0,NOW)
    def reserve(gate):
        try:gate.reserve('flights');return True
        except ConnectorError:return False
    with ThreadPoolExecutor(max_workers=12) as pool:
        results=list(pool.map(reserve,[ga]*12+[gb]*12))
    assert sum(results[:12])==3 and sum(results[12:])==4 # Bob's independent four/minute gate.
    for _ in range(10):ga.claim_provider_call('usage')
    with pytest.raises(ConnectorError):ga.claim_provider_call('flight')
    gb.claim_provider_call('usage')


def test_missing_key_never_falls_back_to_a_global_or_another_users_key(tmp_path):
    settings=Settings(database=str(tmp_path/'accounts.sqlite3'),api_key='unused-global-owner-key')
    seen=[]
    with TestClient(create_app(settings,clock=lambda:NOW,transport=provider(seen))) as client:
        _,a=register(client,'alice');_,b=register(client,'bob')
        assert client.put('/v1/account/api-key',headers=a,json={'api_key':KEY_A}).status_code==200
        seen.clear()
        response=client.post('/v1/trips',headers=b,json=dict(itinerary(),api_key=KEY_A))
        assert response.status_code==201
        state=response.json()
        assert state['trips'][0]['legs'][0]['snapshot'] is None
        assert state['issues'][0]['code']=='api_key_required'
        assert state['usage']['request_count']==0
        assert client.post('/v1/usage/refresh',headers=b).json()['usage']['request_count']==0
        assert seen==[]
        client.delete('/v1/account/api-key',headers=a)
        assert client.post('/v1/trips',headers=a,json=itinerary()).json()['issues'][0]['code']=='api_key_required'
        assert seen==[]
