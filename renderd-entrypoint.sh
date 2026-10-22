#!/bin/bash
set -e

RENDERD_CONF=/etc/renderd.conf
XML="$(sed --quiet 's/^XML=//p' "$RENDERD_CONF" | head --lines=1)"

# Warten, bis die Datenbank erreichbar ist und der erste OSM-Import produktiv geschaltet wurde
python3 - <<'EOF'
import os, time, psycopg2
while True:
    try:
        with psycopg2.connect(host=os.environ['POSTGRES_HOST'], port=os.environ['POSTGRES_PORT'],
                              dbname=os.environ['POSTGRES_DB'], user=os.environ['POSTGRES_USER'],
                              password=os.environ['POSTGRES_PASSWORD']) as conn:
            cur = conn.cursor()
            cur.execute("SELECT to_regclass('public.planet_osm_polygon') IS NOT NULL")
            if cur.fetchone()[0]:
                break
            print('Warte auf den ersten OSM-Import ...', flush=True)
    except psycopg2.OperationalError as e:
        print(f'Warte auf Datenbank ... ({str(e).strip()})', flush=True)
    time.sleep(30)
EOF

# Externe Daten (Wasserflächen, Grenzen, ...) in die Datenbank laden
cd /usr/share/openstreetmap-carto-common
PGPASSWORD="$POSTGRES_PASSWORD" ./get-external-data.py \
    --host "$POSTGRES_HOST" --port "$POSTGRES_PORT" \
    --database "$POSTGRES_DB" --username "$POSTGRES_USER" \
    || echo "WARNUNG: get-external-data.py fehlgeschlagen" >&2

# Datenbank-Zugang ins Mapnik-Stylesheet eintragen
python3 /usr/local/bin/editmapnikconfig.py "$XML"

# Configure renderd threads
sed --in-place --regexp-extended "s/^num_threads=[0-9]+/num_threads=${THREADS:-4}/" "$RENDERD_CONF"

# Socket- und Tile-Verzeichnis liegen auf Volumes, die auch der Apache-Container mountet
mkdir --parents /run/renderd /var/cache/renderd/tiles
chown "$RENDERD_USER": /run/renderd /var/cache/renderd/tiles
rm --force /run/renderd/renderd.sock /run/renderd/renderd.pid

# renderd im Vordergrund als PID 1, ohne Root-Rechte
exec setpriv --reuid="$RENDERD_USER" --regid="$(id --group "$RENDERD_USER")" --init-groups \
    renderd --foreground --config "$RENDERD_CONF"
