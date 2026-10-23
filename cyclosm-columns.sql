-- CyclOSM erwartet einen Import mit dem Standard-Style von osm2pgsql, in dem alle verwendeten Tags
-- eigene Spalten in allen Tabellen haben. Der Import-Style von openstreetmap-carto legt viele davon nur
-- in der hstore-Spalte "tags" ab oder nur für Wege an (z.B. "bicycle"). Fehlende Spalten als berechnete
-- Spalten nachrüsten, die Daten bleiben dabei auch in "tags", openstreetmap-carto funktioniert unverändert.
-- Liste: alle Tag-Spalten aus default.style, die views.sql oder project.mml von CyclOSM verwenden.
-- Läuft mit search_path auf dem Import-Schema, vor indexes.sql (ALTER TABLE schreibt die Tabelle neu).
DO $$
DECLARE
    t text;
    columns text;
BEGIN
    SELECT string_agg(format('ADD COLUMN IF NOT EXISTS %I text GENERATED ALWAYS AS (tags -> %L) STORED', c, c), ', ')
        INTO columns
        FROM unnest(ARRAY[
            'access', 'addr:housename', 'addr:housenumber', 'admin_level', 'aerialway', 'aeroway', 'amenity',
            'barrier', 'bicycle', 'boundary', 'bridge', 'building', 'capital', 'covered', 'denomination', 'ele',
            'generator:source', 'highway', 'historic', 'intermittent', 'junction', 'landuse', 'leisure',
            'man_made', 'military', 'motorcar', 'name', 'natural', 'oneway', 'place', 'population', 'power',
            'public_transport', 'railway', 'ref', 'religion', 'route', 'service', 'shop', 'sport', 'surface',
            'tourism', 'tracktype', 'tunnel', 'water', 'waterway', 'width'
        ]) AS c;
    -- z_order fehlt bei openstreetmap-carto in der Punkt-Tabelle, osm2pgsql berechnet es ohnehin nur für Wege
    columns := columns || ', ADD COLUMN IF NOT EXISTS z_order int4';
    FOREACH t IN ARRAY ARRAY['planet_osm_point', 'planet_osm_line', 'planet_osm_polygon', 'planet_osm_roads'] LOOP
        EXECUTE format('ALTER TABLE %I %s', t, columns);
    END LOOP;
END
$$;
