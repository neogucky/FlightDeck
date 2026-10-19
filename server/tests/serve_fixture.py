"""Local-only integration fixture. Never contacts FlightAware or uses real credentials."""
from pathlib import Path
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from flightdeck.config import Settings
from flightdeck.main import create_app
import uvicorn

if __name__=='__main__':
    with tempfile.TemporaryDirectory(prefix='flightdeck-integration-') as directory:
        settings=Settings(mode='demo',database=str(Path(directory)/'fixture.sqlite3'),
            access_token='flightdeck-local-integration-token-not-a-secret')
        uvicorn.run(create_app(settings),host='127.0.0.1',port=18787,log_level='warning',access_log=False)
