#!/bin/bash
set -e

RENDERD_CONF=/etc/renderd.conf

# Datenbank, externe Daten und CyclOSM vorbereiten, setzt $cyclosm
. /usr/local/bin/render-prepare.sh

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
