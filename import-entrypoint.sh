#!/bin/bash
set -e

if [ -z "$PBF_URL" ]; then
    echo "FEHLER: PBF_URL ist nicht gesetzt" >&2
    exit 1
fi

export PGHOST="$POSTGRES_HOST" PGPORT="$POSTGRES_PORT" PGDATABASE="$POSTGRES_DB" PGUSER="$POSTGRES_USER" PGPASSWORD="$POSTGRES_PASSWORD"
CARTO=/usr/share/openstreetmap-carto-common
PBF="/data/$(basename "${PBF_URL%%\?*}")"
TILE_DIR=/var/cache/renderd/tiles
# Neuer Import landet erst in IMPORT_SCHEMA, die bisherigen Tabellen kurz vor dem Löschen in OLD_SCHEMA
IMPORT_SCHEMA=osm_import
OLD_SCHEMA=osm_old

# docker stop auch während "sleep" sofort beenden
trap 'exit 0' TERM INT

import_if_new() {
    # Auf die Datenbank warten
    until pg_isready --quiet; do
        echo "Warte auf Datenbank $PGHOST:$PGPORT ..."
        sleep 2
    done

    # PBF herunterladen (nur wenn die Datei auf dem Server neuer ist als die lokale)
    echo "Prüfe $PBF_URL ..."
    curl --fail --location --show-error --silent --remote-time \
        $([ -f "$PBF" ] && echo --time-cond "$PBF") \
        --output "$PBF" "$PBF_URL"

    # Nur importieren, wenn sich die PBF seit dem letzten Import geändert hat
    signature="$PBF_URL $(stat --format='%s %Y' "$PBF")"
    imported="$(psql --tuples-only --no-align --command "SELECT pbf_signature FROM mapnik_import" 2>/dev/null || true)"
    if [ "$FORCE_IMPORT" != "1" ] && [ "$signature" = "$imported" ]; then
        echo "PBF unverändert seit dem letzten Import, nichts zu tun"
        return
    fi
    FORCE_IMPORT=0

    echo "Importiere $PBF nach Schema $IMPORT_SCHEMA ..."
    psql --quiet --set ON_ERROR_STOP=1 <<SQL
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS hstore;
DROP SCHEMA IF EXISTS $IMPORT_SCHEMA CASCADE;
CREATE SCHEMA $IMPORT_SCHEMA;
SQL

    osm2pgsql --create --slim --drop --schema "$IMPORT_SCHEMA" \
        --output=pgsql --multi-geometry --hstore \
        --style "$CARTO/openstreetmap-carto.style" \
        --tag-transform-script "$CARTO/openstreetmap-carto.lua" \
        --cache "$OSM2PGSQL_CACHE" --number-processes "$THREADS" \
        "$PBF"

    PGOPTIONS="-c search_path=$IMPORT_SCHEMA,public" psql --quiet --set ON_ERROR_STOP=1 --file "$CARTO/indexes.sql"
    psql --quiet --set ON_ERROR_STOP=1 --file "$CARTO/functions.sql"

    # Produktivnahme: alle importierten Tabellen in einer Transaktion gegen die bisherigen tauschen.
    # Andere Tabellen in public (externe Daten von get-external-data.py) bleiben unberührt.
    echo "Schalte neue Daten produktiv ..."
    psql --quiet --set ON_ERROR_STOP=1 --set signature="$signature" <<SQL
BEGIN;
DROP SCHEMA IF EXISTS $OLD_SCHEMA CASCADE;
CREATE SCHEMA $OLD_SCHEMA;
DO \$\$
DECLARE t text;
BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = '$IMPORT_SCHEMA' LOOP
        IF to_regclass(format('public.%I', t)) IS NOT NULL THEN
            EXECUTE format('ALTER TABLE public.%I SET SCHEMA $OLD_SCHEMA', t);
        END IF;
        EXECUTE format('ALTER TABLE $IMPORT_SCHEMA.%I SET SCHEMA public', t);
    END LOOP;
END
\$\$;
CREATE TABLE IF NOT EXISTS mapnik_import (id int PRIMARY KEY DEFAULT 1 CHECK (id = 1), pbf_signature text, imported_at timestamptz);
INSERT INTO mapnik_import (pbf_signature, imported_at) VALUES (:'signature', now())
    ON CONFLICT (id) DO UPDATE SET pbf_signature = EXCLUDED.pbf_signature, imported_at = EXCLUDED.imported_at;
DROP SCHEMA $IMPORT_SCHEMA CASCADE;
DROP SCHEMA $OLD_SCHEMA CASCADE;
COMMIT;
SQL

    # Vorhandene Tiles als veraltet markieren, mod_tile lässt sie dann im Hintergrund neu rendern
    if [ -d "$TILE_DIR" ]; then
        touch "$TILE_DIR/planet-import-complete"
    fi

    echo "Import abgeschlossen"
}

while true; do
    import_if_new
    if [ "${UPDATE_INTERVAL:-0}" -le 0 ]; then
        break
    fi
    echo "Nächste Prüfung in $UPDATE_INTERVAL Sekunden"
    sleep "$UPDATE_INTERVAL" &
    wait $!
done
