from datetime import datetime, date, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
from uuid import uuid4
from .connector import ConnectorError
from .database import utcnow


def normalize(raw):
    def airport(value):
        value=value or {}
        return {'iata':value.get('code_iata') or value.get('code') or '—','name':value.get('name') or '',
                'city':value.get('city') or '', 'timezone':value.get('timezone') or 'UTC'}
    return {'provider_id':raw.get('fa_flight_id'),'flight_number':raw.get('ident_iata') or raw.get('ident') or '',
        'origin':airport(raw.get('origin')),'destination':airport(raw.get('destination')),
        'status':raw.get('status') or 'Scheduled','cancelled':bool(raw.get('cancelled')),
        'diverted':bool(raw.get('diverted')),'registration':raw.get('registration'),
        'aircraft_type':raw.get('aircraft_type'),'operator':raw.get('operator_iata') or raw.get('operator'),
        'scheduled_departure':raw.get('scheduled_out') or raw.get('scheduled_off'),
        'estimated_departure':raw.get('estimated_out') or raw.get('estimated_off'),
        'actual_departure':raw.get('actual_out') or raw.get('actual_off'),
        'scheduled_arrival':raw.get('scheduled_in') or raw.get('scheduled_on'),
        'estimated_arrival':raw.get('estimated_in') or raw.get('estimated_on'),
        'actual_arrival':raw.get('actual_in') or raw.get('actual_on'),
        'departure_gate':raw.get('gate_origin'),'arrival_gate':raw.get('gate_destination'),
        'departure_terminal':raw.get('terminal_origin'),'arrival_terminal':raw.get('terminal_destination'),
        'arrival_delay_minutes':round((raw.get('arrival_delay') or 0)/60),
        'departure_delay_minutes':round((raw.get('departure_delay') or 0)/60),
        'progress':raw.get('progress_percent'),'inbound_provider_id':raw.get('inbound_fa_flight_id')}


def local_departure_day(raw):
    stamp=raw.get('scheduled_out') or raw.get('scheduled_off')
    if not stamp: return None
    try:
        return datetime.fromisoformat(stamp.replace('Z','+00:00')).astimezone(ZoneInfo((raw.get('origin') or {}).get('timezone') or 'UTC')).date()
    except (ValueError,ZoneInfoNotFoundError):
        return None


def match_flight(rows, leg):
    matches=[r for r in rows if local_departure_day(r)==date.fromisoformat(leg['departure_date'])]
    if leg.get('origin_iata'):
        matches=[r for r in matches if (r.get('origin') or {}).get('code_iata')==leg['origin_iata']]
    if leg.get('destination_iata'):
        matches=[r for r in matches if (r.get('destination') or {}).get('code_iata')==leg['destination_iata']]
    # A diverted continuation can reuse a provider ID. Never pick an arbitrary occurrence.
    if len(matches)>1:
        raise ConnectorError('More than one occurrence matches this flight number and departure date. The route could not be identified safely.', 'ambiguous_flight')
    return matches[0] if matches else None


class FlightService:
    def __init__(self,db,settings,connector=None,clock=utcnow):
        self.db,self.settings,self.connector,self.clock=db,settings,connector,clock

    def create(self, payload):
        trip={'id':str(uuid4()),'title':payload.title.strip(),'created_at':self.clock().isoformat(),
              'legs':[dict(l.model_dump(mode='json'),id=str(uuid4())) for l in payload.legs]}
        self.db.save_trip(trip)
        return trip

    def list(self):
        self.db.purge_provider_data(self.clock())
        trips=self.db.trips()
        for t in trips:
            for leg in t['legs']:
                leg['snapshot']=self.db.snapshot(leg['id'])
        return trips

    async def refresh_leg(self, leg, force):
        now=self.clock()
        snapshot=self.db.snapshot(leg['id'])
        if snapshot and not force and (now-datetime.fromisoformat(snapshot['fetched_at'])).total_seconds()<900:
            return
        day=date.fromisoformat(leg['departure_date'])
        if day<now.date()-timedelta(days=9) or day>now.date()+timedelta(days=2):
            # Personal-tier recent-flight endpoint only; never silently buy history/schedule endpoints.
            raise ConnectorError('Saved. Live status is available close to departure; old flights remain in your history.', 'outside_live_window')
        if self.settings.mode == 'live' and self.connector is None:
            raise ConnectorError('Add your AeroAPI key in Settings to enable live flight information.','api_key_required')
        if not self.db.claim_refresh(leg['id'],now):
            return
        if self.settings.mode=='demo':
            from .demo import snapshot_for
            self.db.save_snapshot(leg['id'],snapshot_for(leg,now))
            return
        start=max(datetime.combine(day-timedelta(days=1),time.min,timezone.utc),now-timedelta(days=9,hours=23))
        end=min(datetime.combine(day+timedelta(days=2),time.min,timezone.utc),now+timedelta(hours=47))
        rows=await self.connector.flights(leg['flight_number'],start=start.isoformat(),end=end.isoformat(),force=force)
        raw=match_flight(rows,leg)
        if not raw:
            raise ConnectorError('No matching occurrence returned on the first API page. Check the flight number and departure date; no additional pages were purchased.', 'flight_not_found')
        current=normalize(raw)
        # Keep partial current-flight updates if the inbound call exhausts the budget or fails.
        result={'fetched_at':raw.get('_flightdeck_fetched_at',now.isoformat()),'flight':current,'inbound':None,'inbound_note':None}
        inbound_id=current.get('inbound_provider_id')
        if inbound_id:
            try:
                candidates=await self.connector.flights(inbound_id,ident_type='fa_flight_id',force=force)
                candidates=[c for c in candidates if c.get('fa_flight_id')==inbound_id]
                if len(candidates)==1:
                    inbound=normalize(candidates[0])
                    same_plane=not (current['registration'] and inbound['registration']) or current['registration']==inbound['registration']
                    same_airport=inbound['destination']['iata']==current['origin']['iata']
                    if same_plane and same_airport:
                        result['inbound']=inbound
                        inbound_fetched=candidates[0].get('_flightdeck_fetched_at',now.isoformat())
                        if datetime.fromisoformat(inbound_fetched)<datetime.fromisoformat(result['fetched_at']):
                            result['fetched_at']=inbound_fetched
                    else:
                        result['inbound_note']='Aircraft assignment changed; incoming flight is awaiting confirmation.'
            except ConnectorError as error:
                result['inbound_note']=error.message
        else:
            result['inbound_note']='The incoming aircraft has not been identified yet.'
        self.db.save_snapshot(leg['id'],result)

    async def refresh(self, trip_id=None, force=False):
        issues=[]
        selected=[t for t in self.db.trips() if not trip_id or t['id']==trip_id]
        if trip_id and not selected:
            raise KeyError(trip_id)
        for trip in selected:
            for leg in trip['legs']:
                if not trip_id:
                    previous=self.db.snapshot(leg['id'])
                    if (previous and previous.get('flight',{}).get('actual_arrival')) or date.fromisoformat(leg['departure_date']) < self.clock().date()-timedelta(days=1):
                        continue
                    if date.fromisoformat(leg['departure_date']) > self.clock().date()+timedelta(days=2):
                        continue
                try:
                    await self.refresh_leg(leg,force)
                except ConnectorError as error:
                    issues.append({'leg_id':leg['id'],'code':error.code,'message':error.message})
        return issues
