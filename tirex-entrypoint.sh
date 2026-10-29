#!/bin/bash
set -e

TIREX_CONF=/etc/tirex
MAPS="$TIREX_CONF/renderer/mapnik"
TILE_DIR=/var/cache/renderd/tiles

# Datenbank, externe Daten und CyclOSM vorbereiten, setzt $cyclosm
. /usr/local/bin/render-prepare.sh

# Kartenstile immer ausgehend von den unveränderten Originalen erzeugen,
# ohne CyclOSM, solange Shapefiles oder Views fehlen (sonst würde das Backend das Stylesheet nicht laden)
rm --force "$MAPS"/*.conf
cp "$MAPS.orig"/*.conf "$MAPS/"
if [ "$cyclosm" != 1 ]; then
    echo "WARNUNG: CyclOSM deaktiviert, nur der Standard-Stil wird gerendert" >&2
    rm "$MAPS/cyclosm.conf"
fi

# Datenbank-Zugang in alle Mapnik-Stylesheets eintragen, immer ausgehend vom unveränderten Original
for xml in $(sed --quiet 's/^mapfile=//p' "$MAPS"/*.conf); do
    python3 /usr/local/bin/editmapnikconfig.py "$xml.orig" "$xml"
done

# Render-Prozesse
sed --in-place --regexp-extended "s/^procs=[0-9]+/procs=${THREADS:-4}/" "$TIREX_CONF/renderer/mapnik.conf"
sed --in-place --regexp-extended "/^bucket name=live /s/maxproc=[0-9]+/maxproc=${THREADS:-4}/" "$TIREX_CONF/tirex.conf"

# Socket- und Tile-Verzeichnis liegen auf Volumes, die auch der Apache-Container mountet
mkdir --parents /run/tirex /run/renderd /var/cache/tirex/stats "$TILE_DIR"
chown "$TIREX_USER": /run/tirex /run/renderd /var/cache/tirex/stats "$TILE_DIR"
# Anders als renderd legt das Mapnik-Backend die Tile-Verzeichnisse der Kartenstile nicht selbst an
for dir in $(sed --quiet 's/^tiledir=//p' "$MAPS"/*.conf); do
    mkdir --parents "$dir"
    chown "$TIREX_USER": "$dir"
done
rm --force /run/renderd/renderd.sock /run/renderd/renderd.pid
# Tiles, die renderd gerendert hat, gehören dessen Benutzer, Tirex könnte sie sonst nicht aktualisieren
if [ -n "$(find "$TILE_DIR" -mindepth 1 -maxdepth 2 ! -user "$TIREX_USER" ! -name planet-import-complete -print -quit)" ]; then
    echo "Übernehme vorhandene Tiles für $TIREX_USER ..."
    find "$TILE_DIR" -mindepth 1 ! -user "$TIREX_USER" ! -name planet-import-complete -exec chown "$TIREX_USER": {} +
fi

as_tirex() {
    setpriv --reuid="$TIREX_USER" --regid="$(id --group "$TIREX_USER")" --init-groups "$@"
}

# Tirex protokolliert nur per syslog: busybox-syslogd nimmt die Meldungen an /dev/log an und gibt sie auf stdout aus
rm --force /dev/log
busybox syslogd -n -O - &
syslogd=$!
until [ -S /dev/log ]; do
    sleep 0.1
done

# Tirex besteht aus zwei Prozessen, beide im Vordergrund und ohne Root-Rechte.
# Endet einer davon, wird auch der andere beendet, damit Docker den Container neu startet
as_tirex tirex-backend-manager --foreground &
pids=($!)
as_tirex tirex-master --foreground &
pids+=($!)

stop() {
    kill -TERM "${pids[@]}" 2>/dev/null || true
    wait "${pids[@]}" || true
    kill -TERM "$syslogd" 2>/dev/null || true
    wait "$syslogd" || true
}
trap 'stop; exit 0' TERM INT

wait -n "${pids[@]}" || true
echo "FEHLER: Ein Tirex-Prozess wurde beendet" >&2
stop
exit 1
