#!/usr/bin/env python3

from lxml import etree
import os

# Datenbank-Konfiguration laden
dbhost = 'postgre'
if 'POSTGRES_HOST' in os.environ:
    dbhost = os.environ['POSTGRES_HOST']
dbport = '5432'
if 'POSTGRES_PORT' in os.environ:
    dbport = os.environ['POSTGRES_PORT']
dbuser = 'postgre'
if 'POSTGRES_USER' in os.environ:
    dbuser = os.environ['POSTGRES_USER']
dbpass = ''
if 'POSTGRES_PASSWORD' in os.environ:
    dbpass = os.environ['POSTGRES_PASSWORD']
dbname = 'gis'
if 'POSTGRES_DB' in os.environ:
    dbname = os.environ['POSTGRES_DB']

# Mapnik-Config einlesen
parser = etree.XMLParser(strip_cdata=False)
root = etree.parse('mapnik.xml', parser)

# Datenbank-Config überall eintragen
for datasource in root.findall('.//Datasource'):
    flagHost = flagPort = flagUser = flagPassword = flagDB = False
    for parameter in datasource.findall('.//Parameter'):
        if parameter.attrib['name'] :
            if parameter.attrib['name'] == 'host':
                parameter.text = etree.CDATA(dbhost)
                flagHost = True
            if parameter.attrib['name'] == 'port':
                parameter.text = etree.CDATA(dbport)
                flagPort = True
            if parameter.attrib['name'] == 'user':
                parameter.text = etree.CDATA(dbuser)
                flagUser = True
            if parameter.attrib['name'] == 'password':
                parameter.text = etree.CDATA(dbpass)
                flagPassword = True
            if parameter.attrib['name'] == 'dbname':
                parameter.text = etree.CDATA(dbname)
                flagDB = True
    if not flagDB:
        continue
    if not flagHost:
        parameter = etree.SubElement(datasource, 'Parameter')
        parameter.set('name', 'host')
        parameter.text = etree.CDATA(dbhost)
    if not flagPort:
        parameter = etree.SubElement(datasource, 'Parameter')
        parameter.set('name', 'port')
        parameter.text = etree.CDATA(dbport)
    if not flagUser:
        parameter = etree.SubElement(datasource, 'Parameter')
        parameter.set('name', 'user')
        parameter.text = etree.CDATA(dbuser)
    if not flagPassword:
        parameter = etree.SubElement(datasource, 'Parameter')
        parameter.set('name', 'password')
        parameter.text = etree.CDATA(dbpass)

root.write('mapnik.xml')
# Zurückschreiben

#for fruit in tree.xpath('//fruit'):
#    fruit.text = 'rotten %s' % (fruit.text,)

#
#print tree.tostring(tree, pretty_print=True)