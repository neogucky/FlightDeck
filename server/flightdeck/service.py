from datetime import datetime, date, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
from uuid import uuid4
import re
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


def flight_identity(value):
    if not isinstance(value,str): return None
    match=re.fullmatch(r'([A-Z]{3}|[A-Z0-9]{2})([0-9]{1,4})([A-Z]?)',re.sub(r'\s+','',value or '').upper())
    return (match[1],int(match[2]),match[3]) if match else None


def schedule_airport_code(row, side):
    return row.get(side+'_icao') or row.get(side+'_iata') or row.get(side)


class FlightService:
    def __init__(self,db,settings,connector=None,clock=utcnow):
        self.db,self.settings,self.connector,self.clock=db,settings,connector,clock

    def create(self, payload):
        trip={'id':str(uuid4()),'title':payload.title.strip(),'created_at':self.clock().isoformat(),
              'legs':[dict(l.model_dump(mode='json'),id=str(uuid4())) for l in payload.legs]}
        if payload.import_id: return self.db.save_imported_trip(trip,payload.import_id)
        self.db.save_trip(trip)
        return trip

    def list(self):
        self.db.purge_provider_data(self.clock())
        trips=self.db.trips()
        for t in trips:
            for leg in t['legs']:
                leg['snapshot']=self.db.snapshot(leg['id'])
                leg['issue']=self.db.refresh_issue(leg['id'])
        return trips

    def issues(self):
        return [issue for trip in self.db.trips() for leg in trip['legs'] if (issue:=self.db.refresh_issue(leg['id']))]

    async def schedule_snapshot(self, leg, force):
        now=self.clock();day=date.fromisoformat(leg['departure_date'])
        if day+timedelta(days=2)>now.date()+timedelta(days=365):
            raise ConnectorError('This flight is saved. Published schedules are available up to about a year ahead.','outside_schedule_window')
        rows=await self.connector.schedules(leg['flight_number'],day,force=force)
        identity=flight_identity(leg['flight_number'])
        rows=[r for r in rows if any(flight_identity(r.get(k))==identity for k in ['ident','ident_iata','ident_icao'])]
        if not rows:
            raise ConnectorError('No published schedule was returned for this flight number and date. The flight is saved; check its number and departure date.','schedule_not_found')
        codes={schedule_airport_code(r,'origin') for r in rows}
        if None in codes or len(codes)>3:
            raise ConnectorError('The schedule contains multiple possible routes and could not be matched safely.','ambiguous_flight')
        airports={}
        async def airport(code):
            if code not in airports:
                info=await self.connector.airport(code)
                candidates=[a for a in [info]+(info.get('alternatives') or []) if isinstance(a,dict) and code in
                            [a.get(k) for k in ['airport_code','code_icao','code_iata','code_lid']]]
                if len(candidates)!=1:
                    raise ConnectorError('The schedule airport could not be identified safely.','schedule_unresolved')
                detail=dict(candidates[0],_flightdeck_fetched_at=info.get('_flightdeck_fetched_at',now.isoformat()))
                detail['code']=detail.get('airport_code')
                try: ZoneInfo(detail.get('timezone') or '')
                except (ZoneInfoNotFoundError,ValueError,TypeError):
                    raise ConnectorError('The airport timezone could not be verified. Local flight times are unavailable.','schedule_unresolved')
                airports[code]=detail
            return airports[code]
        candidates=[]
        for row in rows:
            origin=await airport(schedule_airport_code(row,'origin'))
            converted=dict(row,origin=origin)
            if local_departure_day(converted)==day:
                if leg.get('origin_iata') and origin.get('code_iata')!=leg['origin_iata']: continue
                if leg.get('destination_iata') and row.get('destination_iata')!=leg['destination_iata']: continue
                candidates.append((row,origin))
        if len(candidates)!=1:
            raise ConnectorError('The published schedule did not identify one unique flight on this departure date.','ambiguous_flight' if candidates else 'schedule_not_found')
        row,origin=candidates[0]
        destination=await airport(schedule_airport_code(row,'destination'))
        current=normalize(dict(row,origin=origin,destination=destination,status='Schedule only',registration=None))
        fetched=min(row.get('_flightdeck_fetched_at',now.isoformat()),origin['_flightdeck_fetched_at'],destination['_flightdeck_fetched_at'])
        return {'fetched_at':fetched,'source':'schedule','flight':current,'inbound':None,
                'inbound_note':'Published schedule only. Live status and the assigned incoming aircraft become available closer to departure.'}

    async def refresh_leg(self, leg, force):
        now=self.clock()
        snapshot=self.db.snapshot(leg['id'])
        day=date.fromisoformat(leg['departure_date'])
        if day<now.date()-timedelta(days=9):
            raise ConnectorError('This flight is saved in your history. Live details are available only for recent flights.', 'outside_live_window')
        live=day<=now.date()+timedelta(days=2)
        if snapshot and snapshot.get('source')=='schedule':
            departure=snapshot['flight'].get('scheduled_departure')
            if departure and datetime.fromisoformat(departure.replace('Z','+00:00'))>now+timedelta(hours=47): live=False
        if snapshot and not force:
            age=(now-datetime.fromisoformat(snapshot['fetched_at'])).total_seconds()
            if snapshot.get('source')=='schedule':
                if not live and age<86400: return True
            elif age<900: return True
        if self.settings.mode == 'live' and self.connector is None:
            raise ConnectorError('Add your AeroAPI key in Settings to enable live flight information.','api_key_required')
        cooldown=60 if force else 900 if live else 86400
        previous_issue=self.db.refresh_issue(leg['id'])
        if previous_issue and previous_issue['code']=='rate_limited': cooldown=60
        if not self.db.claim_refresh(leg['id'],now,min_seconds=cooldown):
            return False
        if self.settings.mode=='demo':
            from .demo import snapshot_for
            self.db.save_snapshot(leg['id'],snapshot_for(leg,now))
            return True
        if not live:
            self.db.save_snapshot(leg['id'],await self.schedule_snapshot(leg,force))
            return True
        start=max(datetime.combine(day-timedelta(days=1),time.min,timezone.utc),now-timedelta(days=9,hours=23))
        end=min(datetime.combine(day+timedelta(days=2),time.min,timezone.utc),now+timedelta(hours=47))
        rows=await self.connector.flights(leg['flight_number'],start=start.isoformat(),end=end.isoformat(),force=force)
        raw=match_flight(rows,leg)
        if not raw:
            self.db.save_snapshot(leg['id'],await self.schedule_snapshot(leg,force))
            return True
        current=normalize(raw)
        # Keep partial current-flight updates if the inbound call exhausts the budget or fails.
        result={'fetched_at':raw.get('_flightdeck_fetched_at',now.isoformat()),'source':'live','flight':current,'inbound':None,'inbound_note':None}
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
        return True

    async def refresh(self, trip_id=None, force=False):
        selected=[t for t in self.db.trips() if not trip_id or t['id']==trip_id]
        if trip_id and not selected:
            raise KeyError(trip_id)
        for trip in selected:
            for leg in trip['legs']:
                if not trip_id:
                    previous=self.db.snapshot(leg['id'])
                    if (previous and previous.get('flight',{}).get('actual_arrival')) or date.fromisoformat(leg['departure_date']) < self.clock().date()-timedelta(days=1):
                        continue
                try:
                    if await self.refresh_leg(leg,force): self.db.set_refresh_issue(leg['id'],None)
                except ConnectorError as error:
                    self.db.set_refresh_issue(leg['id'],{'leg_id':leg['id'],'code':error.code,'message':error.message})
        return self.issues()
