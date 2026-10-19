import argparse
from pathlib import Path
import getpass
import secrets


def main():
    parser=argparse.ArgumentParser(description='FlightDeck server')
    parser.add_argument('command',choices=['configure','run'],nargs='?',default='run')
    parser.add_argument('--host',default='127.0.0.1')
    parser.add_argument('--port',type=int,default=8787)
    args=parser.parse_args()
    if args.command=='configure':
        file=Path('.env')
        if file.exists():
            raise SystemExit('.env already exists; edit it directly to avoid replacing your credentials.')
        mode=input('Mode [demo/live] (demo): ').strip() or 'demo'
        if mode not in ['demo','live']: raise SystemExit('Choose demo or live.')
        api_key=getpass.getpass('FlightAware API key: ') if mode=='live' else ''
        token=secrets.token_urlsafe(32)
        file.write_text(f'FLIGHTDECK_MODE={mode}\nFLIGHTDECK_ACCESS_TOKEN={token}\nFLIGHTAWARE_API_KEY={api_key}\nFLIGHTDECK_DATABASE=data/{mode}.sqlite3\nFLIGHTDECK_BUDGET_USD=4.50\nFLIGHTDECK_PRICING_VALID_UNTIL=2026-11-18\n')
        try: file.chmod(0o600)
        except OSError: pass
        print('Configuration written to .env. Copy FLIGHTDECK_ACCESS_TOKEN into the app’s connection settings.')
        return
    from dotenv import load_dotenv
    load_dotenv()
    import uvicorn
    uvicorn.run('flightdeck.main:create_app',factory=True,host=args.host,port=args.port,workers=1,access_log=False)


if __name__=='__main__': main()
