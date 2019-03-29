#!/bin/bash

# as renderer
su - renderer

cd /usr/local/src/openstreetmap-carto
python3 editmapnikconfig.py

# start renderer
renderd -f -c /usr/local/etc/renderd.conf