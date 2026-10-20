#Requires -RunAsAdministrator
param([int]$Port = 8787)
$ErrorActionPreference = 'Stop'
$InstallRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $InstallRoot
$Existing = Get-Service -Name FlightDeck -ErrorAction SilentlyContinue
if ($Existing -and $Existing.Status -ne 'Stopped') {
    Stop-Service -Name FlightDeck
    $Existing.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30))
}

function Assert-Exit([string]$Operation) {
    if ($LASTEXITCODE -ne 0) { throw "$Operation failed (exit $LASTEXITCODE)." }
}

if (-not (Test-Path '.venv\Scripts\python.exe')) {
    if (Get-Command py -ErrorAction SilentlyContinue) { & py -3 -m venv .venv }
    elseif (Get-Command python -ErrorAction SilentlyContinue) { & python -m venv .venv }
    else { throw 'Install Python 3.11 or newer with the Python launcher, then rerun this installer.' }
    Assert-Exit 'Creating the Python environment'
}
$Python = Join-Path $InstallRoot '.venv\Scripts\python.exe'
& $Python -c "import sys; assert sys.version_info >= (3,11), 'Python 3.11+ required'"
Assert-Exit 'Checking Python version'
& $Python -m pip install --requirement requirements.lock
Assert-Exit 'Installing dependencies'
if (-not (Test-Path '.env')) { & $Python -m flightdeck configure; Assert-Exit 'Configuring the server' }

$ServiceDir = Join-Path $InstallRoot '.service'
$DataDir = Join-Path $InstallRoot 'data'
$LogsDir = Join-Path $InstallRoot 'logs'
New-Item -ItemType Directory -Force -Path $ServiceDir,$DataDir,$LogsDir | Out-Null
$Exe = Join-Path $ServiceDir 'FlightDeckService.exe'
$ExpectedHash = '05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da'
if (-not (Test-Path $Exe)) {
    Invoke-WebRequest -Uri 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe' -OutFile $Exe
}
if ((Get-FileHash $Exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExpectedHash) { throw 'The service wrapper hash does not match the pinned release.' }

$Escape = { param($s) [Security.SecurityElement]::Escape($s) }
$PythonXML = & $Escape $Python
$RootXML = & $Escape $InstallRoot
$LogsXML = & $Escape $LogsDir
@"
<service>
  <id>FlightDeck</id><name>FlightDeck</name><description>Personal flight API and durable spending ledger</description>
  <executable>$PythonXML</executable><arguments>-m flightdeck run --host 127.0.0.1 --port $Port</arguments>
  <workingdirectory>$RootXML</workingdirectory><startmode>Automatic</startmode>
  <serviceaccount><username>NT AUTHORITY\LocalService</username></serviceaccount>
  <logpath>$LogsXML</logpath><log mode="roll-by-size"><sizeThreshold>10240</sizeThreshold><keepFiles>4</keepFiles></log>
  <onfailure action="restart" delay="10 sec"/><stoptimeout>20 sec</stoptimeout>
</service>
"@ | Set-Content -Encoding UTF8 (Join-Path $ServiceDir 'FlightDeckService.xml')

# LocalService can read code/configuration and modify only the data and log folders.
& icacls $InstallRoot /grant '*S-1-5-19:(OI)(CI)(RX)' /T /C | Out-Null
Assert-Exit 'Granting service read access'
foreach ($dir in @($DataDir,$LogsDir)) {
    & icacls $dir /grant '*S-1-5-19:(OI)(CI)(M)' /T /C | Out-Null
    Assert-Exit 'Granting service data access'
}
$Principal = [Security.Principal.WindowsIdentity]::GetCurrent().Name
# Account data and provider caches must not inherit access for other local users.
& icacls $DataDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-19:(OI)(CI)(M)' "${Principal}:(OI)(CI)(F)" /T /C | Out-Null
Assert-Exit 'Protecting account data'
$KeyFile = & $Python -c "from dotenv import load_dotenv; load_dotenv(); from flightdeck.config import Settings; from flightdeck.accounts import Accounts; s=Settings.from_env(); Accounts(s); print(s.key_file.resolve())"
Assert-Exit 'Preparing account encryption'
$KeyFolder = Split-Path $KeyFile
& icacls $KeyFolder /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-19:(OI)(CI)(RX)' "${Principal}:(OI)(CI)(F)" /T /C | Out-Null
Assert-Exit 'Protecting the encryption key folder'
& icacls $KeyFile /inheritance:r /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' '*S-1-5-19:(R)' "${Principal}:(F)" | Out-Null
Assert-Exit 'Protecting the encryption key'
& icacls (Join-Path $InstallRoot '.env') /inheritance:r /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' '*S-1-5-19:(R)' "${Principal}:(F)" | Out-Null
Assert-Exit 'Protecting configuration secrets'

if ($Existing) {
    & $Exe refresh
} else { & $Exe install }
Assert-Exit 'Registering the service'
& $Exe start
Assert-Exit 'Starting FlightDeck'
Start-Sleep -Seconds 2
$Health = Invoke-RestMethod "http://127.0.0.1:$Port/health"
if ($Health.status -ne 'ok') { throw 'The health check did not succeed.' }
Write-Host "FlightDeck is running at http://127.0.0.1:$Port. Point your HTTPS reverse proxy here."
Write-Host 'Users register and add their own AeroAPI keys in the app. Keep .env, data and secrets private.'
