FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    FLIGHTDECK_DATABASE=/data/accounts.sqlite3 \
    FLIGHTDECK_ENCRYPTION_KEY_FILE=/data/secrets/master.key

WORKDIR /app
COPY requirements.lock .
RUN pip install --no-cache-dir -r requirements.lock \
    && groupadd --gid 10001 flightdeck \
    && useradd --uid 10001 --gid flightdeck --no-create-home flightdeck \
    && mkdir /data && chown flightdeck:flightdeck /data
COPY flightdeck ./flightdeck
USER flightdeck
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8787/health', timeout=3)"
CMD ["python", "-m", "flightdeck", "run", "--host", "0.0.0.0", "--port", "8787"]
