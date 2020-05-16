FROM ubuntu:18.04

USER root

ENV TZ=UTC
ENV POSTGRES_DB=postgres
ENV POSTGRES_USER=postgres
ENV POSTGRES_PASSWORD=""
ENV POSTGRES_HOST=localhost
ENV POSTGRES_PORT=5432

ENV CARTO_VERSION v5.2.0

RUN apt update && apt-get -y upgrade && apt-get -y install curl

RUN curl -sL https://deb.nodesource.com/setup_10.x | bash -

RUN apt-get update && apt-get -y install systemd autoconf apache2-dev libtool \
    libxml2-dev libbz2-dev libgeos-dev libgeos++-dev libproj-dev gdal-bin \
    libmapnik-dev mapnik-utils python-mapnik git fonts-noto-cjk fonts-hanazono \
    fonts-noto-hinted fonts-noto-unhinted ttf-unifont nodejs apache2 \
    libgdal-dev default-libmysqlclient-dev \
    python3-lxml sudo && rm -rf /var/lib/apt/lists/*

RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
RUN adduser --disabled-password --gecos "" renderer

# Load Sources
WORKDIR /usr/local/src
RUN git clone https://github.com/openstreetmap/mod_tile/
RUN git clone --depth 1 --branch $CARTO_VERSION https://github.com/gravitystorm/openstreetmap-carto.git
COPY editmapnikconfig.py /usr/local/src/openstreetmap-carto/
RUN chown -R root:renderer openstreetmap-carto/
RUN chmod -R g+w openstreetmap-carto/


# Install mod_tile
WORKDIR /usr/local/src/mod_tile
RUN ./autogen.sh && ./configure && make && make install && make install-mod_tile && ldconfig

# Install carto
WORKDIR /usr/local/src/openstreetmap-carto
RUN npm install -g carto


USER renderer
RUN python -c 'import mapnik'

# Configure stylesheet
WORKDIR /usr/local/src/openstreetmap-carto
RUN carto -v && carto project.mml > mapnik.xml && cp mapnik.xml mapnik.bak.xml && \
    python3 editmapnikconfig.py

# Load shapefiles
WORKDIR /usr/local/src/openstreetmap-carto
RUN scripts/get-shapefiles.py

# Configure renderd
USER root
RUN MAPNIKPLUGIN=`mapnik-config --input-plugins` && \
    sed -i -e 's#\[default\]$#[default]\nMAXZOOM=20#' \
    -e 's#^plugins_dir=.*$#plugins_dir='$MAPNIKPLUGIN'#' \
    -e 's/renderaccount/renderer/g' -e 's/hot/tile/g' \
    -e 's#^XML=.*$#XML=/usr/local/src/openstreetmap-carto/mapnik.xml#g' \
    -e 's#^URI=.*$#URI=/tile/#' /usr/local/etc/renderd.conf && \
    sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS:-4}/g" /usr/local/etc/renderd.conf

USER renderer

# Configure Apache
USER root
RUN mkdir /var/lib/mod_tile && chown renderer /var/lib/mod_tile && mkdir /var/run/renderd && \
    chown renderer /var/run/renderd && \
    echo "LoadModule tile_module /usr/lib/apache2/modules/mod_tile.so" >> /etc/apache2/conf-available/mod_tile.conf && \
    a2enconf mod_tile

COPY apache.conf /etc/apache2/sites-available/000-default.conf

USER renderer

COPY run.sh /

USER root
RUN chmod a+x /run.sh
RUN systemctl enable apache2

#USER renderer
ENTRYPOINT ["/run.sh"]
CMD []

EXPOSE 80
