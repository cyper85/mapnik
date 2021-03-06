# Mapnik-Tile-Server

See also [Docker-Hub: cyper85/mapnik](https://hub.docker.com/r/cyper85/mapnik)

## Installation
You need a [PostGIS-Container](https://github.com/postgis/docker-postgis) and an [osm2pgsql-Container](https://github.com/cyper85/osm2pgsql).

```bash
# Create a Network to use the Postgis-Server in an other container
docker network create postgis-net

# Install a postgis-instance
docker run --detach --name test-postgis --network postgis-net postgis/postgis

# Install a osm2pgsql-instance
docker run --env POSTGRES_HOST=test-postgis --name test-osm2pgsql --network postgis-net cyper85/osm2pgsql

# Install a mapnik-instance
docker run --detach --env POSTGRES_HOST=test-postgis --detach --name test-mapnik --network postgis-net --port 80:80 cyper85/mapnik
```

Or you build your own image from source:

```bash
# Download sources
git clone https://github.com/cyper85/mapnik.git
cd mapnik/

# Build it
docker build --tag mapnik .

# Install an instance
docker run --name test-mapnik --network postgis-net mapnik
```

## Additional parameter

env | default value | description 
------------ | ------------- | -------------
POSTGRES_DB | postgres | Database-Name
POSTGRES_USER | postgres | Database-User
POSTGRES_PASSWORD |  | Database-Password
POSTGRES_HOST | localhost | Database-Hostname
POSTGRES_PORT | 5432 | Database-Port

You can use a volume for the Tile-Cache-Directory: */var/lib/mod_tile*

### Renderer
**renderd**:
```cyper85/mapnik:renderd```

**tyrex**
```cyper85/mapnik:tyrex```