# Mapnik-Tile-Server

Ein OpenStreetMap-Tile-Server mit zwei Kartenstilen, [openstreetmap-carto](https://github.com/gravitystorm/openstreetmap-carto)
und [CyclOSM](https://github.com/cyclosm/cyclosm-cartocss-style), aufgeteilt in drei Container, die jeweils genau
einen Prozess im Vordergrund ausführen. Beide Stile nutzen dieselbe Datenbank.

Siehe auch [Docker-Hub: cyper85/mapnik](https://hub.docker.com/r/cyper85/mapnik).

## Aufbau

```
                     Reverse-Proxy (TLS)
                            │  X-Forwarded-For
                            ▼
┌────────────────────────────────────────┐
│ apache   (Apache + mod_tile)           │──── liefert vorhandene Tiles direkt aus
│  - Referer-Prüfung, Drosselung pro IP  │
└───────────┬────────────────────────────┘
            │ Unix-Socket /run/renderd/renderd.sock      ┌─────────────────────┐
            ▼                                            │ Volume "tiles"      │
┌────────────────────────────────────────┐  schreibt     │ /var/cache/renderd/ │
│ renderd  (renderd + Mapnik + Carto)    │──────────────▶│ tiles               │
└───────────┬────────────────────────────┘               └─────────────────────┘
            │ SQL                                                  ▲
            ▼                                                      │ markiert Tiles
┌────────────────────────────────────────┐                         │ als veraltet
│ PostGIS  (eigener Container)           │◀────────────────────────┤
└────────────────────────────────────────┘    importiert           │
            ▲                                                      │
┌───────────┴────────────────────────────┐                         │
│ import   (osm2pgsql)                   │─────────────────────────┘
│  - lädt die PBF, importiert bei Bedarf │
└────────────────────────────────────────┘
```

| Container | Image | Aufgabe |
|---|---|---|
| `import` | `Dockerfile.import` | Lädt eine PBF-Datei herunter und importiert sie mit osm2pgsql, sobald sie sich geändert hat |
| `renderd` | `Dockerfile.renderd` | Rendert Tiles mit Mapnik in den Stilen openstreetmap-carto und CyclOSM |
| `apache` | `Dockerfile.apache` | Liefert Tiles unter `/tile/{z}/{x}/{y}.png` (openstreetmap-carto) und `/cyclosm/{z}/{x}/{y}.png` (CyclOSM) aus und beauftragt renderd bei fehlenden Tiles |

Die Datenbank (PostGIS) gehört nicht zum Projekt und läuft in einem eigenen Container.

## Schnellstart mit Docker Compose

Voraussetzung ist ein Docker-Netzwerk `postgis-net` mit einer PostGIS-Datenbank darin:

```bash
docker network create postgis-net
docker run --detach --name test-postgis --network postgis-net \
    --env POSTGRES_PASSWORD=geheim postgis/postgis:16-3.4
```

Dann den Tile-Server bauen und starten:

```bash
git clone https://github.com/cyper85/mapnik.git
cd mapnik/

POSTGRES_HOST=test-postgis POSTGRES_PASSWORD=geheim \
PBF_URL=https://download.geofabrik.de/europe/germany/thueringen-latest.osm.pbf \
docker compose up --detach --build
```

Die Variablen lassen sich auch dauerhaft in einer Datei `.env` neben der `docker-compose.yml` ablegen:

```ini
POSTGRES_HOST=test-postgis
POSTGRES_PASSWORD=geheim
PBF_URL=https://download.geofabrik.de/europe/germany/thueringen-latest.osm.pbf
HTTP_PORT=8080
```

Beim ersten Start passiert Folgendes:

1. `import` lädt die PBF herunter und importiert sie (Thüringen: ca. 5 Minuten, Deutschland: mehrere Stunden).
2. `renderd` wartet, bis der Import abgeschlossen ist, lädt dann die externen Daten (Wasserflächen,
   Grenzen) in die Datenbank, für CyclOSM die Landflächen (ca. 1 GB) ins Volume `cyclosm-data` und startet.
3. `apache` ist sofort erreichbar. Bis renderd läuft, werden fehlende Tiles mit 404 beantwortet.

Fortschritt verfolgen:

```bash
docker compose logs --follow import renderd
```

## Start ohne Docker Compose

```bash
# Gemeinsame Volumes: Socket zwischen apache und renderd, Tile-Cache für alle drei
docker volume create renderd-socket
docker volume create tiles
docker volume create cyclosm-data

# Import (mit UPDATE_INTERVAL=0 einmalig, danach beendet sich der Container)
docker run --detach --name mapnik-import --network postgis-net \
    --env POSTGRES_HOST=test-postgis --env POSTGRES_PASSWORD=geheim \
    --env PBF_URL=https://download.geofabrik.de/europe/germany/thueringen-latest.osm.pbf \
    --env UPDATE_INTERVAL=86400 \
    --volume tiles:/var/cache/renderd/tiles \
    cyper85/mapnik:import

# Renderer
docker run --detach --name mapnik-renderd --network postgis-net \
    --env POSTGRES_HOST=test-postgis --env POSTGRES_PASSWORD=geheim \
    --volume renderd-socket:/run/renderd --volume tiles:/var/cache/renderd/tiles \
    --volume cyclosm-data:/var/lib/cyclosm \
    cyper85/mapnik:renderd

# Webserver
docker run --detach --name mapnik-apache --network postgis-net --publish 80:80 \
    --volume renderd-socket:/run/renderd --volume tiles:/var/cache/renderd/tiles:ro \
    cyper85/mapnik:apache
```

Wichtig: `apache` und `renderd` brauchen **beide** Volumes. Über den Socket beauftragt Apache das Rendern,
die fertigen Tiles liest Apache aber direkt aus dem Tile-Volume.

## Karte einbinden

Die Tiles stehen in Zoomstufen 0 bis 20 bereit:

| Stil | URL |
|---|---|
| openstreetmap-carto | `https://<dein-tile-server>/tile/{z}/{x}/{y}.png` |
| CyclOSM | `https://<dein-tile-server>/cyclosm/{z}/{x}/{y}.png` |

Beispiel mit [Leaflet](https://leafletjs.com/), beide Stile zum Umschalten:

```html
<div id="karte" style="height: 500px"></div>
<script>
  const osm = '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>-Mitwirkende';
  const standard = L.tileLayer('https://tile.stadtplan-ilmenau.de/tile/{z}/{x}/{y}.png', {
    maxZoom: 20,
    attribution: osm
  });
  const cyclosm = L.tileLayer('https://tile.stadtplan-ilmenau.de/cyclosm/{z}/{x}/{y}.png', {
    maxZoom: 20,
    attribution: 'Stil: <a href="https://www.cyclosm.org">CyclOSM</a> | ' + osm
  });
  const karte = L.map('karte', { layers: [standard] }).setView([50.686, 10.914], 14);
  L.control.layers({ 'Standard': standard, 'Fahrrad (CyclOSM)': cyclosm }).addTo(karte);
</script>
```

Die Seite, die die Karte einbindet, muss zu den freigegebenen Domains gehören (siehe `ALLOWED_DOMAINS`).
Der Browser darf den `Referer` nicht unterdrücken, also kein `referrerpolicy="no-referrer"` setzen.

## Konfiguration

Alle Einstellungen erfolgen über Umgebungsvariablen. Bei Docker Compose gelten teilweise andere Standardwerte
als im Image (Spalte „Compose“).

### Datenbank (`import`, `renderd`)

| Variable | Standard | Compose | Beschreibung |
|---|---|---|---|
| `POSTGRES_HOST` | `localhost` | `test-postgis` | Hostname der PostGIS-Datenbank |
| `POSTGRES_PORT` | `5432` | | Port |
| `POSTGRES_DB` | `postgres` | | Datenbankname |
| `POSTGRES_USER` | `postgres` | | Benutzer, braucht beim ersten Import das Recht, die Extensions `postgis` und `hstore` anzulegen |
| `POSTGRES_PASSWORD` | leer | | Passwort |
| `THREADS` | `4` | | Render-Threads (renderd) bzw. osm2pgsql-Prozesse (import) |

### Import (`import`)

| Variable | Standard | Compose | Beschreibung |
|---|---|---|---|
| `PBF_URL` | leer, Pflicht | Thüringen | URL der PBF-Datei, z.B. von [Geofabrik](https://download.geofabrik.de/) |
| `UPDATE_INTERVAL` | `0` | `86400` | Sekunden zwischen zwei Prüfungen auf eine neue PBF. `0` = einmal prüfen und beenden |
| `FORCE_IMPORT` | `0` | | `1` = importieren, auch wenn die PBF unverändert ist |
| `OSM2PGSQL_CACHE` | `2000` | | Cache von osm2pgsql in MB |

### Webserver (`apache`)

| Variable | Standard | Beschreibung |
|---|---|---|
| `ALLOWED_DOMAINS` | `stadtplan-ilmenau.de map4jena.de map4erfurt.de stadtplan-arnstadt.de` | Seiten, auf denen die Karte eingebunden werden darf, inklusive aller Subdomains. Durch Leerzeichen oder Komma getrennt. Leer = keine Einschränkung |
| `ALLOW_EMPTY_REFERER` | `0` | `1` = auch Anfragen ohne `Referer` erlauben (z.B. QGIS, JOSM). Damit lässt sich die Domain-Sperre aber umgehen |
| `TRUSTED_PROXIES` | `10.0.0.0/8 172.16.0.0/12 192.168.0.0/16` | Reverse-Proxys (IPs oder Netze), deren `X-Forwarded-For`-Header vertraut wird |
| `THROTTLE_TILES` | `10000 10` | Drosselung pro Client-IP für ausgelieferte Tiles: Bucket-Größe und Nachfüllrate pro Sekunde |
| `THROTTLE_RENDERS` | `1000 2` | Wie `THROTTLE_TILES`, aber nur für Tiles, die neu gerendert werden müssen |
| `HTTP_PORT` | `80` | Nur Compose: Port, unter dem Apache auf dem Host erreichbar ist |

## Sicherheit

**Einbindung nur auf freigegebenen Seiten:** Apache prüft bei jeder Tile-Anfrage den `Referer`-Header gegen
`ALLOWED_DOMAINS` und antwortet sonst mit **403**. Die Prüfung findet statt, bevor renderd beauftragt wird,
gesperrte Anfragen erzeugen also keine Last. Für freigegebene Seiten wird zusätzlich der CORS-Header
`Access-Control-Allow-Origin` gesetzt, damit die Tiles auch per JavaScript (Canvas, WebGL) geladen werden können.
Der Referer verhindert die Einbindung in fremde Webseiten, nicht aber gezielte Abrufe mit eigenen Programmen,
denn diese können den Header beliebig setzen. Dagegen hilft die Drosselung.

**Drosselung von Massendownloads:** mod_tile führt pro Client-IP einen Token-Bucket. Jede ausgelieferte Tile
verbraucht ein Token, pro Sekunde kommen neue hinzu. Ist der Bucket leer, antwortet Apache mit **503**.
Beim normalen Kartenaufbau werden viele Tiles auf einmal geladen, das deckt der Bucket ab. Scraper werden auf
die Nachfüllrate gebremst.

**Reverse-Proxy:** Die Client-IP wird aus `X-Forwarded-For` übernommen, aber nur, wenn die Verbindung von einem
Proxy aus `TRUSTED_PROXIES` kommt. Andernfalls wird der Header ignoriert, er lässt sich also nicht fälschen.
Bei mehreren Proxys hintereinander (z.B. CDN und Proxy) müssen alle eingetragen sein. Beispiel für nginx:

```nginx
location / {
    proxy_pass http://mapnik-apache:80;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

**Abgeschaltet:** Die mod_tile-URLs `/dirty` (Neu-Rendern anfordern) und `/status` sind deaktiviert, und Apache
gibt keine Versionsinformationen preis.

## Betrieb

### Daten aktualisieren

Mit Docker Compose prüft `import` täglich, ob es eine neue PBF gibt. Ist das der Fall, wird sie
**im Hintergrund** importiert, die Karte bleibt währenddessen voll nutzbar:

1. Die PBF wird nur heruntergeladen, wenn sie auf dem Server neuer ist als die lokale Kopie.
2. osm2pgsql importiert in das Schema `osm_import`, die produktiven Tabellen bleiben unberührt.
3. Nach dem Import werden die neuen Tabellen in **einer Transaktion** gegen die alten getauscht,
   in derselben Transaktion werden die Views für CyclOSM neu angelegt.
4. Alle vorhandenen Tiles werden als veraltet markiert. Besucher bekommen weiterhin sofort die alte Tile,
   im Hintergrund wird sie neu gerendert.

Die Datenbank braucht während eines Imports Platz für zwei vollständige Datensätze.

Einen Import sofort erzwingen:

```bash
FORCE_IMPORT=1 UPDATE_INTERVAL=0 docker compose run --rm import
```

Den Zeitpunkt des letzten Imports zeigt die Tabelle `mapnik_import`:

```bash
docker exec test-postgis psql -U postgres -c "SELECT * FROM mapnik_import"
```

### Region wechseln

`PBF_URL` ändern und neu starten. Der Import erkennt die geänderte URL und importiert die neue Region:

```bash
PBF_URL=https://download.geofabrik.de/europe/germany/sachsen-latest.osm.pbf docker compose up --detach
```

Danach sollte der Tile-Cache geleert werden (siehe unten), sonst bleiben Tiles der alten Region
außerhalb der neuen sichtbar, bis sie neu gerendert werden.

### Tile-Cache leeren

```bash
docker compose stop apache renderd
docker compose run --rm --no-deps --entrypoint sh renderd -c 'rm -rf /var/cache/renderd/tiles/default /var/cache/renderd/tiles/cyclosm'
docker compose start renderd apache
```

### Logs

Alle Container schreiben ihre Logs nach stdout/stderr:

```bash
docker compose logs --follow apache    # Zugriffe (mit echter Client-IP), 403/503
docker compose logs --follow renderd   # Rendering, Datenbankfehler
docker compose logs --follow import    # Downloads und Importe
```

## Volumes

| Volume | Pfad | Genutzt von | Inhalt |
|---|---|---|---|
| `tiles` | `/var/cache/renderd/tiles` | apache (nur lesend), renderd, import | Gerenderte Metatiles |
| `renderd-socket` | `/run/renderd` | apache, renderd | Unix-Socket von renderd (tmpfs) |
| `cyclosm-data` | `/var/lib/cyclosm` | renderd | Landflächen-Shapefiles für CyclOSM, werden bei jedem Start auf Aktualität geprüft |
| `osm-data` | `/data` | import | Heruntergeladene PBF-Dateien |

## Fehlersuche

| Symptom | Ursache und Lösung |
|---|---|
| Alle Tiles liefern **403** | Die einbindende Seite steht nicht in `ALLOWED_DOMAINS`, oder der Browser sendet keinen `Referer` |
| Tiles liefern **503** | Drosselung greift. Prüfen, ob der Proxy in `TRUSTED_PROXIES` steht. Sonst teilen sich alle Besucher die IP des Proxys und damit einen Bucket |
| Fehlende Tiles liefern **404** | renderd läuft noch nicht (wartet auf Import oder Datenbank), siehe `docker compose logs renderd` |
| renderd meldet `relation "water_polygons" does not exist` o.ä. | Die externen Daten konnten nicht geladen werden (`WARNUNG: get-external-data.py fehlgeschlagen`). Meist ist `osmdata.openstreetmap.de` nicht erreichbar. renderd neu starten, sobald der Server wieder erreichbar ist |
| renderd meldet `function carto_... does not exist` | Die Datenbank wurde nicht mit diesem Import-Container befüllt. Einen Import mit `FORCE_IMPORT=1` ausführen, er spielt die Funktionen von openstreetmap-carto mit ein |
| CyclOSM-Tiles liefern **404**, renderd meldet `CyclOSM deaktiviert` | Entweder fehlen die Landflächen (Download von `osmdata.openstreetmap.de` fehlgeschlagen) oder die Datenbank hat die CyclOSM-Views noch nicht. Die Views legt `import` an, bei Datenbanken aus älteren Versionen importiert er deshalb automatisch einmal neu. Danach renderd neu starten |
| Import bricht mit `permission denied to create extension` ab | Der Datenbankbenutzer darf die Extensions `postgis` und `hstore` nicht anlegen. Einmalig als Superuser anlegen |

## CyclOSM

CyclOSM gibt es nicht als Ubuntu-Paket. `Dockerfile.renderd` lädt die Quellen in der Version `CYCLOSM_VERSION`
und übersetzt sie mit [carto](https://github.com/mapbox/carto) in ein Mapnik-Stylesheet. Node.js wird nur
dafür in einer eigenen Build-Stufe gebraucht, das fertige Image enthält es nicht. Höhenlinien, Schummerung und die
anderen in CyclOSM standardmäßig abgeschalteten Layer werden dabei entfernt.

CyclOSM erwartet eigentlich einen Import mit dem Standard-Style von osm2pgsql. Damit eine Datenbank für beide
Stile reicht, ergänzt der Import die fehlenden Spalten als berechnete Spalten aus der hstore-Spalte `tags`
(`cyclosm-columns.sql`) und legt die Views aus `views.sql` von CyclOSM an.

`CYCLOSM_VERSION` steht in `Dockerfile.renderd` und `Dockerfile.import` und muss in beiden gleich sein.
[Renovate](https://docs.renovatebot.com/) erkennt sie über den Kommentar `# renovate: ...` (siehe `renovate.json`)
und aktualisiert beide in einem gemeinsamen Pull Request. Nach einem Versionswechsel einen Import mit
`FORCE_IMPORT=1` ausführen, damit die Views der neuen Version angelegt werden.

## Tirex

Neben renderd gibt es eine ältere Variante mit [Tirex](https://wiki.openstreetmap.org/wiki/Tirex):
`DockerfileTirex` bzw. das Image `cyper85/mapnik:tirex`.
