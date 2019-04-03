#!/bin/bash

service apache2 restart

cd /usr/local/src/openstreetmap-carto
python3 editmapnikconfig.py

# start renderer
renderd -f -c /usr/local/etc/renderd.conf