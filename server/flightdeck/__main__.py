import argparse
from pathlib import Path
import getpass


def main():
    parser=argparse.ArgumentParser(description='FlightDeck account server')
    parser.add_argument('command',choices=['configure','run','reset-password'],nargs='?',default='run')
    parser.add_argument('--host',default='127.0.0.1')
    parser.add_argument('--port',type=int,default=8787)
    parser.add_argument('--username')
    args=parser.parse_args()
    if args.command=='configure':
        file=Path('.env')
        if file.exists(): raise SystemExit('.env already exists; edit it directly to preserve your server configuration.')
        mode=input('Mode [live/demo] (live): ').strip() or 'live'
        if mode not in ['demo','live']: raise SystemExit('Choose demo or live.')
        file.write_text(f'FLIGHTDECK_MODE={mode}\nFLIGHTDECK_DATABASE=data/{mode}-accounts.sqlite3\nFLIGHTDECK_ENCRYPTION_KEY_FILE=secrets/master.key\nFLIGHTDECK_REGISTRATION_OPEN=true\nFLIGHTDECK_SESSION_DAYS=90\nFLIGHTDECK_BUDGET_USD=4.50\nFLIGHTDECK_PRICING_VALID_UNTIL=2026-11-18\n')
        try: file.chmod(0o600)
        except OSError: pass
        from dotenv import load_dotenv
        load_dotenv()
        from .accounts import Accounts
        from .config import Settings
        Accounts(Settings.from_env())
        print('Server configured. Connect from the app and create an account. Each user adds their own API key in the app.')
        print('Back up secrets/master.key separately and securely; losing it makes saved API keys unreadable.')
        return
    from dotenv import load_dotenv
    load_dotenv()
    if args.command=='reset-password':
        from .accounts import Accounts
        from .config import Settings
        if not args.username: raise SystemExit('Supply --username for the account to recover.')
        accounts=Accounts(Settings.from_env())
        password=getpass.getpass('New password (12–128 characters): ')
        if not 12 <= len(password) <= 128: raise SystemExit('Password length must be 12–128 characters.')
        if password != getpass.getpass('Confirm new password: '): raise SystemExit('Passwords differ.')
        with accounts.db.transaction() as con:
            row=con.execute('SELECT id FROM users WHERE username=?',(args.username.lower().strip(),)).fetchone()
            if not row: raise SystemExit('Account not found.')
            con.execute('UPDATE users SET password_hash=? WHERE id=?',(accounts.hasher.hash(password),row[0]))
            con.execute('DELETE FROM sessions WHERE user_id=?',(row[0],))
        print('Password updated and all sessions revoked.')
        return
    import uvicorn
    uvicorn.run('flightdeck.main:create_app',factory=True,host=args.host,port=args.port,workers=1,access_log=False,proxy_headers=False)


if __name__=='__main__': main()
