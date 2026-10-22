#!/bin/bash
set -e

# Regex für die freigegebenen Seiten (inkl. Subdomains) aus ALLOWED_DOMAINS bauen,
# leere Liste = keine Einschränkung
domains="$(echo "$ALLOWED_DOMAINS" | tr ', ' '\n\n' | sed '/^$/d; s/\./\\./g' | paste --serial --delimiters='|')"
if [ -n "$domains" ]; then
    export ALLOWED_ORIGIN_REGEX="^https?://([a-z0-9-]+\.)*(${domains})(:[0-9]+)?(/.*)?\$"
else
    export ALLOWED_ORIGIN_REGEX=".*"
    ALLOW_EMPTY_REFERER=1
fi
echo "Erlaubte Referer/Origins: $ALLOWED_ORIGIN_REGEX"

defines=()
if [ "$ALLOW_EMPTY_REFERER" = "1" ]; then
    defines+=(-D ALLOW_EMPTY_REFERER)
fi

# Apache im Vordergrund als PID 1 starten (statt "service apache2 start")
. /etc/apache2/envvars
mkdir --parents "$APACHE_RUN_DIR" "$APACHE_LOCK_DIR"
rm --force "$APACHE_PID_FILE"

exec apache2 -D FOREGROUND "${defines[@]}" "$@"
