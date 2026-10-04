# PostgreSQL 17 + PostGIS 3 + las herramientas del pipeline en un solo contenedor:
#   - postgresql-17-postgis-3 : PostGIS (desde el repo PGDG que ya trae la imagen oficial)
#   - gdal-bin                : ogr2ogr (OSM PBF/GPKG -> PostGIS y PostGIS -> GeoPackage)
#   - osmium-tool             : recorte del PBF de Chile a la caja santiago-centro
#   - unzip                   : descomprimir el ZIP del GTFS
# Así la máquina que corrige sólo necesita Docker: no se instala nada en el host.
FROM postgres:17-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        postgresql-17-postgis-3 postgresql-17-postgis-3-scripts \
        gdal-bin osmium-tool unzip \
 && rm -rf /var/lib/apt/lists/*

# Configuración de ogr2ogr para el driver OSM (agrega amenity, shop, etc. a la capa points)
COPY osmconf.ini /etc/tarea1/osmconf.ini
