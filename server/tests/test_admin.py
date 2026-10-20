from datetime import datetime, timezone, timedelta
import sys
from fastapi.testclient import TestClient
from flightdeck.config import Settings
from flightdeck.main import create_app
from flightdeck.accounts import Accounts
from flightdeck.__main__ import main


def test_admin_password_recovery_revokes_sessions_but_preserves_account(tmp_path,monkeypatch):
    settings=Settings(database=str(tmp_path/'accounts.sqlite3'),mode='demo')
    accounts=Accounts(settings)
    auth=accounts.register('recover','Original test password')
    monkeypatch.setenv('FLIGHTDECK_DATABASE',settings.database)
    monkeypatch.setenv('FLIGHTDECK_MODE','demo')
    monkeypatch.setattr(sys,'argv',['flightdeck','reset-password','--username','recover'])
    monkeypatch.setattr('getpass.getpass',lambda prompt:'A replacement test password')
    main()
    with TestClient(create_app(settings)) as client:
        assert client.get('/v1/state',headers={'Authorization':'Bearer '+auth['session_token']}).status_code==401
        assert client.post('/v1/auth/login',json={'username':'recover','password':'Original test password'}).status_code==401
        new=client.post('/v1/auth/login',json={'username':'recover','password':'A replacement test password'})
        assert new.status_code==200 and new.json()['account']['id']==auth['account']['id']


def test_unrevoked_session_expires_at_absolute_deadline(tmp_path):
    settings=Settings(database=str(tmp_path/'accounts.sqlite3'),mode='demo',session_days=2)
    now=datetime(2026,10,20,tzinfo=timezone.utc)
    accounts=Accounts(settings,clock=lambda:now)
    session=accounts.register('expiry','A test-only long password')
    header={'Authorization':'Bearer '+session['session_token']}
    with TestClient(create_app(settings,clock=lambda:now+timedelta(days=1))) as client:
        assert client.get('/v1/state',headers=header).status_code==200
    with TestClient(create_app(settings,clock=lambda:now+timedelta(days=2))) as client:
        assert client.get('/v1/state',headers=header).status_code==401
