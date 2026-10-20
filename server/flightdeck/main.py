from contextlib import asynccontextmanager
from dataclasses import replace
import asyncio

from fastapi import FastAPI, Depends, HTTPException, Header, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from .accounts import Accounts, AccountError
from .config import Settings
from .connector import AeroAPI, BudgetGate, ConnectorError, verify_api_key
from .service import FlightService
from .models import TripInput, Credentials, APIKeyInput


class BodyLimit:
    """Bound JSON buffering before validation, including chunked requests."""
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http':
            return await self.app(scope,receive,send)
        body = bytearray()
        while True:
            message = await receive()
            if message['type'] == 'http.disconnect': return
            body.extend(message.get('body',b''))
            if len(body) > 65536:
                return await JSONResponse({'detail':'Request too large.'},status_code=413)(scope,receive,send)
            if not message.get('more_body',False): break
        delivered = False
        async def replay():
            nonlocal delivered
            if not delivered:
                delivered = True
                return {'type':'http.request','body':bytes(body),'more_body':False}
            return await receive()
        await self.app(scope,replay,send)


def create_app(settings=None, *, transport=None, clock=None):
    settings = settings or Settings.from_env()
    from .database import utcnow
    clock = clock or utcnow
    accounts = Accounts(settings,clock)
    locks = {}
    app = FastAPI(title='FlightDeck',version='0.2.0',docs_url=None,redoc_url=None,openapi_url=None)
    app.add_middleware(BodyLimit)
    app.state.accounts = accounts

    @app.middleware('http')
    async def private_responses(request,call_next):
        response = await call_next(request)
        response.headers['Cache-Control'] = 'no-store'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        return response

    @app.exception_handler(AccountError)
    async def account_error(request,error):
        headers = {'WWW-Authenticate':'Bearer'} if error.status == 401 else {}
        if error.status == 429: headers['Retry-After'] = '600'
        return JSONResponse({'detail':error.message},status_code=error.status,headers=headers)

    @app.exception_handler(ConnectorError)
    async def provider_error(request,error):
        status = 429 if error.code == 'rate_limited' else 400 if error.code == 'invalid_api_key' else 503
        return JSONResponse({'detail':error.message,'code':error.code},status_code=status)

    @app.exception_handler(RequestValidationError)
    async def safe_validation(request,error):
        # Default validation responses echo rejected input, including secrets.
        if request.url.path.startswith('/v1/auth/'):
            detail = 'Use a username with 3–32 letters, numbers, dots, underscores or hyphens, and a password with 12–128 characters.'
        elif request.url.path == '/v1/account/api-key':
            detail = 'Paste your AeroAPI key without spaces or line breaks (10–512 characters).'
        else:
            detail = 'Check the flight numbers and departure dates. Connected flights must be different and in date order.'
        return JSONResponse({'detail':detail},status_code=422)

    async def authenticated(authorization: str | None = Header(default=None)):
        return await run_in_threadpool(accounts.authenticate,authorization)

    @asynccontextmanager
    async def scoped(user):
        # Only this user's authenticated UUID chooses credentials and storage.
        async with locks.setdefault(user['id'],asyncio.Lock()):
            user = accounts.user(user['id'])
            db = accounts.tenant(user['id'])
            per_user = replace(settings,api_key=accounts.provider_key(user)) if settings.mode == 'live' and user['key_cipher'] else replace(settings,api_key='')
            api = AeroAPI(db,per_user,clock,transport) if per_user.api_key and settings.mode == 'live' else None
            try:
                yield user,db,FlightService(db,per_user,api,clock),BudgetGate(db,per_user,clock),api
            finally:
                if api: await api.close()

    def state(user,service,gate,issues=None):
        return {'mode':settings.mode,'account':accounts.public(user),'trips':service.list(),'usage':gate.summary(),'issues':service.issues() if issues is None else issues}

    @app.get('/health')
    def health():
        return {'status':'ok','version':'0.2.0'}

    @app.get('/v1/server')
    def server_info():
        return {'service':'FlightDeck','protocol_version':2,'registration_open':settings.registration_open,'mode':settings.mode}

    async def credentials_action(payload,request,register):
        peer = request.client.host if request.client else 'unknown'
        # Never trust a caller-supplied forwarding header for rate limits.
        accounts.throttle('auth-ip:'+peer,40,600)
        accounts.throttle('auth-user:'+payload.username,10,600)
        if register: accounts.throttle('register:'+peer,5,3600)
        action = accounts.register if register else accounts.login
        return await run_in_threadpool(action,payload.username,payload.password.get_secret_value())

    @app.post('/v1/auth/register',status_code=201)
    async def register(payload: Credentials,request: Request):
        return await credentials_action(payload,request,True)

    @app.post('/v1/auth/login')
    async def login(payload: Credentials,request: Request):
        return await credentials_action(payload,request,False)

    @app.post('/v1/auth/logout',status_code=204)
    def logout(user=Depends(authenticated),authorization: str = Header()):
        accounts.logout(authorization,user['id'])
        return Response(status_code=204)

    @app.post('/v1/auth/logout-all',status_code=204)
    def logout_all(user=Depends(authenticated),authorization: str = Header()):
        accounts.logout(authorization,user['id'],all_sessions=True)
        return Response(status_code=204)

    @app.get('/v1/account')
    def account(user=Depends(authenticated)):
        return accounts.public(user)

    @app.put('/v1/account/api-key')
    async def save_api_key(payload: APIKeyInput,user=Depends(authenticated)):
        if settings.mode != 'live': raise AccountError('This demo server does not accept provider keys.',409)
        async with locks.setdefault(user['id'],asyncio.Lock()):
            key = payload.api_key.get_secret_value()
            accounts.assert_key_owner(user['id'],key)
            gate = BudgetGate(accounts.tenant(user['id']),settings,clock)
            cost = await verify_api_key(key,gate,transport=transport)
            accounts.save_key(user['id'],key)
            gate.account_observed(cost,clock())
        async with scoped(user) as (user,db,service,gate,api):
            return state(user,service,gate)

    @app.delete('/v1/account/api-key')
    async def remove_api_key(user=Depends(authenticated)):
        async with locks.setdefault(user['id'],asyncio.Lock()):
            accounts.remove_key(user['id'])
        async with scoped(user) as (user,db,service,gate,api):
            return state(user,service,gate)

    @app.get('/v1/state')
    async def get_state(user=Depends(authenticated)):
        async with scoped(user) as (user,db,service,gate,api): return state(user,service,gate)

    @app.get('/v1/usage')
    async def usage(user=Depends(authenticated)):
        async with scoped(user) as (user,db,service,gate,api): return {'usage':gate.summary(),'history':gate.history()}

    @app.post('/v1/usage/refresh')
    async def refresh_usage(user=Depends(authenticated)):
        async with scoped(user) as (user,db,service,gate,api):
            if api: await api.account_usage()
            return {'usage':gate.summary(),'history':gate.history()}

    @app.post('/v1/trips',status_code=201)
    async def add_trip(payload: TripInput,user=Depends(authenticated)):
        async with scoped(user) as (user,db,service,gate,api):
            trip = service.create(payload)
            issues = await service.refresh(trip['id']) if trip else None
            return state(user,service,gate,issues)

    @app.delete('/v1/trips/{trip_id}')
    async def delete_trip(trip_id: str,user=Depends(authenticated)):
        async with scoped(user) as (user,db,service,gate,api):
            if trip_id not in [t['id'] for t in db.trips()]: raise HTTPException(404,'Trip not found.')
            db.delete_trip(trip_id)
            return state(user,service,gate)

    @app.post('/v1/refresh')
    async def refresh(force: bool = False,trip_id: str | None = None,user=Depends(authenticated)):
        async with scoped(user) as (user,db,service,gate,api):
            try: issues = await service.refresh(trip_id,force)
            except KeyError: raise HTTPException(404,'Trip not found.') from None
            return state(user,service,gate,issues)

    return app
