#!/bin/bash

# Initialize PostgreSQL and Apache
service tirex-backend-manager start
service tirex-master start

cd /usr/local/src/openstreetmap-carto || exit 1
python3 editmapnikconfig.py

tirex-master --debug
