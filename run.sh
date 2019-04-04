#!/bin/bash

# Initialize PostgreSQL and Apache
service apache2 restart

cd /usr/local/src/openstreetmap-carto
python3 editmapnikconfig.py

# Configure renderd threads
sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS:-4}/g" /usr/local/etc/renderd.conf

# Run
sudo -u renderer renderd -f -c /usr/local/etc/renderd.conf

exit 0
