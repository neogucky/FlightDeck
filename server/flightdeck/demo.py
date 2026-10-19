from datetime import datetime, time, timedelta, timezone


def snapshot_for(leg, now):
    airports={'HAM':('Hamburg','Hamburg Airport'),'MUC':('Munich','Munich Airport'),'ZRH':('Zurich','Zurich Airport'),
              'LHR':('London','Heathrow'),'JNB':('Johannesburg','O.R. Tambo'),'CPT':('Cape Town','Cape Town International')}
    origin=leg.get('origin_iata') or 'HAM';dest=leg.get('destination_iata') or 'ZRH'
    start=datetime.combine(datetime.fromisoformat(leg['departure_date']).date(),time(13,30),timezone.utc)
    def airport(code):
        names=airports.get(code,(code,code));return {'iata':code,'city':names[0],'name':names[1],'timezone':'Europe/Berlin'}
    f={'provider_id':'demo-'+leg['id'],'flight_number':leg['flight_number'],'origin':airport(origin),'destination':airport(dest),
       'status':'Scheduled','cancelled':False,'diverted':False,'registration':'HB-JDB','aircraft_type':'A20N','operator':'LX',
       'scheduled_departure':start.isoformat(),'estimated_departure':start.isoformat(),'actual_departure':None,
       'scheduled_arrival':(start+timedelta(minutes=85)).isoformat(),'estimated_arrival':(start+timedelta(minutes=85)).isoformat(),
       'actual_arrival':None,'departure_gate':'A24','arrival_gate':'B12','departure_terminal':'2','arrival_terminal':'1',
       'arrival_delay_minutes':0,'departure_delay_minutes':0,'progress':0,'inbound_provider_id':None}
    return {'fetched_at':now.isoformat(),'flight':f,'inbound':None,'inbound_note':'Demo information. No external API calls are made.'}
