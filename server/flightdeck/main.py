from contextlib import asynccontextmanager
import hmac
from fastapi import FastAPI, Depends, HTTPException, Header, Request
from .config import Settings
from .database import Database
from .connector import AeroAPI, BudgetGate
from .service import FlightService
from .models import TripInput


def create_app(settings=None, connector=None, clock=None):
    settings=settings or Settings.from_env()
    settings.prepare_directory()
    db=Database(settings.database)
    old_mode=db.meta('mode')
    if old_mode and old_mode!=settings.mode:
        raise ValueError('Use a separate database for demo and live data.')
    db.set_meta('mode',settings.mode)
    kwargs={'clock':clock} if clock else {}
    api=connector or (AeroAPI(db,settings,**kwargs) if settings.mode=='live' else None)
    service=FlightService(db,settings,api,**kwargs)
    gate=BudgetGate(db,settings,**kwargs)

    @asynccontextmanager
    async def lifespan(app):
        yield
        if api: await api.close()

    app=FastAPI(title='FlightDeck',version='0.1.0',lifespan=lifespan,docs_url=None,redoc_url=None,openapi_url=None)
    app.state.db=db;app.state.service=service

    async def authenticated(authorization: str | None = Header(default=None)):
        expected='Bearer '+settings.access_token
        if authorization is None or not hmac.compare_digest(authorization.encode(),expected.encode()):
            raise HTTPException(401,'A valid connection token is required.',headers={'WWW-Authenticate':'Bearer'})

    def state(issues=None):
        return {'mode':settings.mode,'trips':service.list(),'usage':gate.summary(),'issues':issues or []}

    @app.get('/health')
    def health():
        return {'status':'ok','version':'0.1.0'}

    @app.get('/v1/state',dependencies=[Depends(authenticated)])
    def get_state():
        return state()

    @app.post('/v1/trips',dependencies=[Depends(authenticated)],status_code=201)
    async def add_trip(payload: TripInput):
        trip=service.create(payload)
        issues=await service.refresh(trip['id'])
        return state(issues)

    @app.delete('/v1/trips/{trip_id}',dependencies=[Depends(authenticated)])
    def delete_trip(trip_id: str):
        if trip_id not in [t['id'] for t in db.trips()]: raise HTTPException(404,'Trip not found.')
        db.delete_trip(trip_id)
        return state()

    @app.post('/v1/refresh',dependencies=[Depends(authenticated)])
    async def refresh(force: bool = False, trip_id: str | None = None):
        try:
            issues=await service.refresh(trip_id,force)
        except KeyError:
            raise HTTPException(404,'Trip not found.')
        return state(issues)

    return app
