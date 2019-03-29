FROM ubuntu

USER root

ENV TZ=UTC
ENV POSTGRES_DB=postgres
ENV POSTGRES_USER=postgres
ENV POSTGRES_PASSWORD=""
ENV POSTGRES_HOST=localhost
ENV POSTGRES_PORT=5432

RUN apt update
RUN apt-get -y upgrade

RUN curl -sL https://deb.nodesource.com/setup_10.x | bash -

RUN apt-get -y install autoconf apache2-dev libtool libxml2-dev libbz2-dev libgeos-dev libgeos++-dev libproj-dev gdal-bin libmapnik-dev mapnik-utils python-mapnik git fonts-noto-cjk fonts-noto-hinted fonts-noto-unhinted ttf-unifont nodejs apache2 npm python3-lxml

RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
RUN adduser --disabled-password --gecos "" renderer

# Load Sources
WORKDIR /usr/local/src
RUN git clone https://github.com/openstreetmap/mod_tile/
RUN git clone https://github.com/gravitystorm/openstreetmap-carto.git
COPY editmapnikconfig.py /usr/local/src/openstreetmap-carto/
RUN chown -R root:renderer openstreetmap-carto/
RUN chmod -R g+w openstreetmap-carto/


# Install mod_tile
WORKDIR /usr/local/src/mod_tile
RUN ./autogen.sh
RUN ./configure
RUN make
RUN make install
RUN make install-mod_tile
RUN ldconfig

# Install carto
WORKDIR /usr/local/src/openstreetmap-carto
RUN npm install -g carto


USER renderer
RUN python -c 'import mapnik'

# Configure stylesheet
WORKDIR /usr/local/src/openstreetmap-carto
RUN carto -v
RUN carto project.mml > mapnik.xml
RUN cp mapnik.xml mapnik.bak.xml
RUN python3 editmapnikconfig.py

# Load shapefiles
WORKDIR /usr/local/src/openstreetmap-carto
RUN scripts/get-shapefiles.py

# Configure renderd
USER root
RUN sed -i 's/renderaccount/renderer/g' /usr/local/etc/renderd.conf
RUN sed -i 's/hot/tile/g' /usr/local/etc/renderd.conf
RUN sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS:-4}/g" /usr/local/etc/renderd.conf
RUN sed -i 's#^XML=.*$#XML=/usr/local/src/openstreetmap-carto/mapnik.xml#g' /usr/local/etc/renderd.conf

RUN MAPNIKPLUGIN=`mapnik-config --input-plugins`
RUN sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS:-4}/g" /usr/local/etc/renderd.conf
RUN sed -i 's#^plugins_dir=.*$#plugins_dir='$MAPNIKPLUGIN'#' /usr/local/etc/renderd.conf
RUN sed -i 's#^URI=.*#URI=/tile/#g' /usr/local/etc/renderd.conf
USER renderer

# Configure Apache
USER root
RUN mkdir /var/lib/mod_tile
RUN chown renderer /var/lib/mod_tile
RUN mkdir /var/run/renderd
RUN chown renderer /var/run/renderd
RUN echo "LoadModule tile_module /usr/lib/apache2/modules/mod_tile.so" >> /etc/apache2/conf-available/mod_tile.conf
RUN a2enconf mod_tile
COPY apache.conf /etc/apache2/sites-available/000-default.conf
USER renderer

COPY run.sh /

USER root
RUN chmod a+x /run.sh

USER renderer
ENTRYPOINT ["/run.sh"]
CMD []

EXPOSE 80