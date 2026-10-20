"""Local-only integration fixture. Accepts fake keys; never contacts FlightAware."""
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from flightdeck.config import Settings
from flightdeck.main import create_app
import httpx
import uvicorn


def mock_provider(request):
    if not request.headers.get('x-apikey','').startswith('flightdeck-test-'):
        return httpx.Response(401)
    if request.url.path.endswith('/account/usage'):
        return httpx.Response(200,json={'total_cost':0.025})
    if '/schedules/' in request.url.path:
        start=datetime.fromisoformat(request.url.path.split('/')[-2])+timedelta(days=1,hours=12)
        return httpx.Response(200,json={'num_pages':1,'scheduled':[{
            'ident':'SWR1052','ident_iata':'LX1052','ident_icao':'SWR1052','fa_flight_id':None,
            'origin':'LSZH','origin_icao':'LSZH','origin_iata':'ZRH','destination':'EDDH','destination_icao':'EDDH','destination_iata':'HAM',
            'scheduled_out':start.isoformat()+'Z','scheduled_in':(start+timedelta(minutes=85)).isoformat()+'Z','aircraft_type':'BCS3'}]})
    if '/airports/' in request.url.path:
        code=request.url.path.rsplit('/',1)[-1]
        iata,city,zone=('ZRH','Zurich','Europe/Zurich') if code=='LSZH' else ('HAM','Hamburg','Europe/Berlin')
        return httpx.Response(200,json={'airport_code':code,'code_icao':code,'code_iata':iata,'city':city,'name':city+' Airport','timezone':zone})
    number=request.url.path.rsplit('/',1)[-1]
    if number=='LX1052':return httpx.Response(200,json={'num_pages':1,'flights':[]})
    origin,destination=('MUC','ZRH') if number.startswith('LX') else ('HAM','MUC')
    airports={'HAM':('Hamburg','Europe/Berlin'),'MUC':('Munich','Europe/Berlin'),'ZRH':('Zurich','Europe/Zurich')}
    def airport(code):return {'code_iata':code,'city':airports[code][0],'timezone':airports[code][1]}
    now=datetime.now(timezone.utc).replace(hour=15,minute=0,second=0,microsecond=0)
    return httpx.Response(200,json={'num_pages':1,'flights':[{
        'fa_flight_id':'fixture-'+number,'ident_iata':number,'scheduled_out':now.isoformat(),
        'scheduled_in':(now+timedelta(minutes=80)).isoformat(),'origin':airport(origin),'destination':airport(destination),
        'status':'Scheduled','registration':'D-TEST','aircraft_type':'A20N','gate_origin':'A24'}]})

if __name__=='__main__':
    with tempfile.TemporaryDirectory(prefix='flightdeck-integration-') as directory:
        settings=Settings(mode='live',database=str(Path(directory)/'accounts.sqlite3'))
        uvicorn.run(create_app(settings,transport=httpx.MockTransport(mock_provider)),host='127.0.0.1',port=18787,
                    log_level='warning',access_log=False,proxy_headers=False)
