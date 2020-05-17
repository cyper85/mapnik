#!/bin/bash

# Initialize PostgreSQL and Apache
service apache2 restart
service tirex-backend-manager restart
service tirex-master restart

cd /usr/local/src/openstreetmap-carto
python3 editmapnikconfig.py

exit 0
