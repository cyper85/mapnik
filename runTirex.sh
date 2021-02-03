#!/bin/bash

# Initialize PostgreSQL and Apache
sudo -u tirex service tirex-backend-manager start
sudo -u tirex service tirex-master start
service apache2 start


cd /usr/local/src/openstreetmap-carto || exit 1
python3 editmapnikconfig.py

sudo -u tirex tirex-master --debug
