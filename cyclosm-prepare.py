#!/usr/bin/env python3

# Bereitet das project.mml von CyclOSM für renderd auf:
# - abgeschaltete Layer (Schummerung, Höhenlinien, GPX, Legende, ...) entfernen, weil Mapnik deren
#   Datenquellen beim Laden trotzdem öffnet und an den fehlenden Dateien/Tabellen scheitern würde
# - die Shapefile-URLs durch lokale Pfade ersetzen, renderd-entrypoint.sh lädt die Dateien beim Start
# - "layer" ist im Import-Style von openstreetmap-carto eine Zahl, CyclOSM prüft es per Regex als Text
#   (dieselbe Anpassung macht Dockerfile.import an views.sql)
# Aufruf: cyclosm-prepare.py <project.mml> <Ergebnis.mml> <Datenverzeichnis> <Download-Liste>

import json
import re
import sys

import yaml

src, dst, datadir, downloads = sys.argv[1:5]

# Shapefile im jeweiligen ZIP von osmdata.openstreetmap.de
SHAPEFILES = {
    'simplified-land-polygons-complete-3857.zip': 'simplified-land-polygons-complete-3857/simplified_land_polygons.shp',
    'land-polygons-split-3857.zip': 'land-polygons-split-3857/land_polygons.shp',
}

with open(src, encoding='utf-8') as f:
    mml = yaml.safe_load(f)

layers = []
urls = []
for layer in mml['Layer']:
    # YAML 1.1 liest "status: off" als False
    if layer.get('properties', {}).get('status') in (False, 'off'):
        continue
    datasource = layer['Datasource']
    if datasource.get('type') == 'shape' and datasource['file'].startswith('http'):
        url = datasource['file'].replace('http://', 'https://', 1)
        shp = SHAPEFILES[url.rsplit('/', 1)[1]]
        datasource['file'] = f'{datadir}/{shp}'
        if (url, shp) not in urls:
            urls.append((url, shp))
    if 'table' in datasource:
        datasource['table'] = re.sub(r'\blayer\s*~', 'layer::text ~', datasource['table'])
    layers.append(layer)
mml['Layer'] = layers

# JSON ist gültiges YAML, carto liest beides
with open(dst, 'w', encoding='utf-8') as f:
    json.dump(mml, f, ensure_ascii=False, indent=2)

with open(downloads, 'w', encoding='utf-8') as f:
    for url, shp in urls:
        f.write(f'{url} {shp}\n')
