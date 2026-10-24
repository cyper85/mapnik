#!/bin/bash
set -e

RENDERD_CONF=/etc/renderd.conf
CYCLOSM_DATA=/var/lib/cyclosm

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

# Shapefiles für CyclOSM (Landflächen) laden, später nur noch, wenn es auf dem Server eine neuere Version gibt
cyclosm=1
while read -r url shp; do
    dir="$(dirname "$shp")"
    zip="$CYCLOSM_DATA/$dir.zip"
    stamp="$CYCLOSM_DATA/$dir/.download"
    rm --recursive --force "$zip" "$CYCLOSM_DATA/.extract"
    echo "Prüfe $url ..."
    if curl --fail --location --show-error --silent --remote-time \
            $([ -f "$CYCLOSM_DATA/$shp" ] && [ -f "$stamp" ] && echo --time-cond "$stamp") \
            --output "$zip" "$url"; then
        if [ -s "$zip" ]; then
            echo "Entpacke $zip ..."
            python3 -m zipfile --extract "$zip" "$CYCLOSM_DATA/.extract" && \
                touch --reference="$zip" "$CYCLOSM_DATA/.extract/$dir/.download" && \
                rm --recursive --force "$CYCLOSM_DATA/$dir" && \
                mv "$CYCLOSM_DATA/.extract/$dir" "$CYCLOSM_DATA/$dir" \
                || echo "WARNUNG: $zip konnte nicht entpackt werden" >&2
        fi
    else
        echo "WARNUNG: Download von $url fehlgeschlagen" >&2
    fi
    rm --recursive --force "$zip" "$CYCLOSM_DATA/.extract"
    if [ ! -f "$CYCLOSM_DATA/$shp" ]; then
        echo "WARNUNG: $CYCLOSM_DATA/$shp fehlt" >&2
        cyclosm=0
    elif [ ! -f "$CYCLOSM_DATA/${shp%.shp}.index" ]; then
        # Räumlicher Index, ohne ihn liest Mapnik bei jeder Metatile das ganze Shapefile
        # (land_polygons.shp ca. 1 GB), das Rendern dauert dann länger als ModTileMissingRequestTimeout
        echo "Erstelle Index für $shp ..."
        shapeindex --shape_files "$CYCLOSM_DATA/$shp" >/dev/null \
            || echo "WARNUNG: Index für $shp konnte nicht erstellt werden" >&2
    fi
done < /usr/local/share/cyclosm/shapefiles.txt

# Die Views für CyclOSM legt der Import an, Datenbanken aus älteren Versionen haben sie noch nicht
if ! python3 - <<'EOF'
import os, sys, psycopg2
with psycopg2.connect(host=os.environ['POSTGRES_HOST'], port=os.environ['POSTGRES_PORT'],
                      dbname=os.environ['POSTGRES_DB'], user=os.environ['POSTGRES_USER'],
                      password=os.environ['POSTGRES_PASSWORD']) as conn:
    cur = conn.cursor()
    cur.execute("SELECT to_regclass('public.cyclosm_ways') IS NOT NULL")
    sys.exit(0 if cur.fetchone()[0] else 1)
EOF
then
    echo "WARNUNG: View cyclosm_ways fehlt in der Datenbank, der nächste Import legt sie an" >&2
    cyclosm=0
fi

# renderd-Konfiguration immer ausgehend vom unveränderten Original erzeugen,
# ohne CyclOSM, solange Shapefiles oder Views fehlen (sonst würde renderd das Stylesheet nicht laden)
if [ "$cyclosm" = 1 ]; then
    cp "$RENDERD_CONF.orig" "$RENDERD_CONF"
else
    echo "WARNUNG: CyclOSM deaktiviert, nur der Standard-Stil wird gerendert" >&2
    awk '/^\[/ { skip = ($0 == "[cyclosm]") } !skip' "$RENDERD_CONF.orig" > "$RENDERD_CONF"
fi

# Datenbank-Zugang in alle Mapnik-Stylesheets eintragen, immer ausgehend vom unveränderten Original
for xml in $(sed --quiet 's/^XML=//p' "$RENDERD_CONF"); do
    python3 /usr/local/bin/editmapnikconfig.py "$xml.orig" "$xml"
done

# Configure renderd threads
sed --in-place --regexp-extended "s/^num_threads=[0-9]+/num_threads=${THREADS:-4}/" "$RENDERD_CONF"

# Socket- und Tile-Verzeichnis liegen auf Volumes, die auch der Apache-Container mountet
mkdir --parents /run/renderd /var/cache/renderd/tiles
chown "$RENDERD_USER": /run/renderd /var/cache/renderd/tiles
rm --force /run/renderd/renderd.sock /run/renderd/renderd.pid

# renderd im Vordergrund als PID 1, ohne Root-Rechte
exec setpriv --reuid="$RENDERD_USER" --regid="$(id --group "$RENDERD_USER")" --init-groups \
    renderd --foreground --config "$RENDERD_CONF"
