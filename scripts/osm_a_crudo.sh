#!/usr/bin/env bash
# Corre DENTRO del contenedor db (lo llama cargar.sh).
# OSM -> esquema crudo (capas points, lines, multipolygons), ya en SRID 5361.
#
# Uso: osm_a_crudo.sh <archivo .osm.pbf o .gpkg dentro de /datos> <lon_min,lat_min,lon_max,lat_max>
set -euo pipefail

FUENTE="$1"
BBOX="$2"
IFS=',' read -r LON_MIN LAT_MIN LON_MAX LAT_MAX <<< "$BBOX"
PG="PG:dbname=${PGDATABASE:-tarea1} user=${PGUSER:-postgres}"

# Opciones comunes de ogr2ogr:
#   -t_srs EPSG:5361      todo queda en SIRGAS-Chile / UTM 19S desde la carga
#   SPATIAL_INDEX=NONE    los índices se crean después, sobre las tablas derivadas
#   PG_USE_COPY=YES       ogr2ogr usa COPY en vez de INSERT
#   -gt 65536             transacciones grandes (mucho más rápido)
OGR_OPTS=(-f PostgreSQL "$PG" -t_srs EPSG:5361
          -lco SCHEMA=crudo -lco OVERWRITE=YES -lco GEOMETRY_NAME=geom -lco FID=ogc_fid
          -lco SPATIAL_INDEX=NONE -lco PRECISION=NO
          --config PG_USE_COPY YES -gt 65536)

# Rehacer desde cero (el script es idempotente).
psql -X -q -c "DROP TABLE IF EXISTS crudo.points, crudo.lines, crudo.multipolygons,
               crudo.multilinestrings, crudo.other_relations CASCADE"

case "$FUENTE" in
  *.pbf)
    echo "  -> recorte con osmium a la caja $BBOX"
    # Fecha de los datos: Geofabrik la escribe en el encabezado del PBF.
    FECHA=$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$FUENTE" 2>/dev/null || true)
    [ -z "$FECHA" ] && FECHA=$(osmium fileinfo -g header.option.timestamp "$FUENTE" 2>/dev/null || true)
    [ -z "$FECHA" ] && FECHA="(sin fecha en el encabezado; ver fecha de descarga en README)"
    TAM=$(du -h "$FUENTE" | cut -f1)

    # --strategy smart (por defecto): los polígonos que cruzan el borde quedan completos.
    osmium extract -b "$BBOX" --overwrite -o /tmp/osm_recorte.osm.pbf "$FUENTE"
    TAM_RECORTE=$(du -h /tmp/osm_recorte.osm.pbf | cut -f1)

    echo "  -> ogr2ogr (points, lines, multipolygons) -> crudo.*"
    # Un solo llamado con las tres capas: el driver OSM hace lectura intercalada.
    ogr2ogr "${OGR_OPTS[@]}" \
        -oo CONFIG_FILE=/etc/tarea1/osmconf.ini \
        --config OSM_MAX_TMPFILE_SIZE 1024 \
        /tmp/osm_recorte.osm.pbf points lines multipolygons
    rm -f /tmp/osm_recorte.osm.pbf

    psql -X -q -v ON_ERROR_STOP=1 <<SQL
INSERT INTO metadatos_fuentes VALUES
  ('OSM', '$(basename "$FUENTE")', '${OSM_ORIGEN:-Geofabrik chile-latest} ($TAM; recorte $TAM_RECORTE)', '$FECHA',
   'osmium extract -b $BBOX + ogr2ogr (osmconf.ini propio)')
ON CONFLICT (fuente) DO UPDATE SET archivo=EXCLUDED.archivo, version=EXCLUDED.version,
   fecha_datos=EXCLUDED.fecha_datos, detalle=EXCLUDED.detalle;
SQL
    ;;

  *.gpkg)
    echo "  -> GeoPackage del Lab 05 -> crudo.* (filtro espacial a la caja)"
    # Al evaluar -spat, GEOS rechaza los polígonos OSM rotos (anillos de 2
    # puntos) y ogr2ogr los descarta con un ERROR por objeto. Se cuentan y se
    # registran en etl_log en vez de llenar el log.
    ogr2ogr "${OGR_OPTS[@]}" \
        -spat "$LON_MIN" "$LAT_MIN" "$LON_MAX" "$LAT_MAX" -spat_srs EPSG:4326 \
        "$FUENTE" 2> /tmp/ogr2ogr_err.txt \
      || { cat /tmp/ogr2ogr_err.txt >&2; exit 1; }
    ROTOS=$(grep -c "Invalid number of points in LinearRing" /tmp/ogr2ogr_err.txt || true)
    grep -v "Invalid number of points in LinearRing" /tmp/ogr2ogr_err.txt >&2 || true
    echo "  -> $ROTOS polígonos con anillos de 2 puntos descartados por ogr2ogr (OSM roto)"
    psql -X -q -c "INSERT INTO etl_log(paso, detalle, filas) VALUES ('osm_descartadas', 'ogr2ogr: polígonos con anillos de < 3 puntos (GEOS no los puede evaluar)', $ROTOS)"
    # El GPKG no guarda la fecha de los datos OSM: se toma de fuentes.env
    # (OSM_FECHA / OSM_ORIGEN, versionado en el repo); si no está, la del archivo.
    FECHA="${OSM_FECHA:-archivo modificado el $(date -r "$FUENTE" +%Y-%m-%d)}"
    ORIGEN="${OSM_ORIGEN:-GeoPackage generado con preparar_datos.py (Lab 05)}"
    psql -X -q -v ON_ERROR_STOP=1 <<SQL
INSERT INTO metadatos_fuentes VALUES
  ('OSM', '$(basename "$FUENTE")', '$ORIGEN', '$FECHA', 'ogr2ogr desde GPKG')
ON CONFLICT (fuente) DO UPDATE SET archivo=EXCLUDED.archivo, version=EXCLUDED.version,
   fecha_datos=EXCLUDED.fecha_datos, detalle=EXCLUDED.detalle;
SQL
    ;;

  *)
    echo "ERROR: formato OSM no reconocido: $FUENTE" >&2
    exit 1
    ;;
esac

# Las tres capas tienen que existir para seguir.
for capa in points lines multipolygons; do
  psql -X -tA -c "SELECT to_regclass('crudo.$capa') IS NOT NULL" | grep -q t \
    || { echo "ERROR: falta la capa crudo.$capa" >&2; exit 1; }
done
