#!/usr/bin/env bash
# Corre DENTRO del contenedor db (lo llama consultas.sh).
# Exporta las capas de resultados a un GeoPackage para QGIS / el informe.
set -euo pipefail
OUT=/salidas/tarea1_resultados.gpkg
PG="PG:dbname=${PGDATABASE:-tarea1} user=${PGUSER:-postgres}"
rm -f "$OUT"

capa() {  # capa <nombre en el gpkg> <consulta SQL>
  local modo=()
  [ -f "$OUT" ] && modo=(-update)
  ogr2ogr -f GPKG "$OUT" "$PG" "${modo[@]}" -nln "$1" -sql "$2" -a_srs EPSG:5361
  echo "  -> $1"
}
capa comunas_paraderos     "SELECT comuna, completa, area_km2, paraderos, paraderos_km2, geom FROM resultados.q1"
capa comunas_cobertura     "SELECT comuna, edificios, pct_lejos_gtfs, pct_lejos_osm, dif_pp_osm_menos_gtfs, geom FROM resultados.q2"
capa gtfs_sin_osm_50m      "SELECT stop_id, nombre, geom FROM resultados.q3_gtfs_sin_osm"
capa osm_sin_gtfs_50m      "SELECT id, osm_id, nombre, geom FROM resultados.q3_osm_sin_gtfs"
capa comunas_km_recorrido  "SELECT comuna, km_recorrido, rutas, km_por_km2, geom FROM resultados.q4"
capa ruta_paraderos_salud  "SELECT sentido, orden, stop_id, paradero, amenity, lugar_salud, distancia_m, geom FROM resultados.q5"
capa ruta_lineas_salud     "SELECT stop_id, distancia_m, geom_linea AS geom FROM resultados.q5"
capa grilla_hex_500m       "SELECT i, j, edificios, recorridos, recorridos_bus, indice, geom FROM resultados.grilla_hex"
capa grilla_top10          "SELECT rank, comuna, edificios, recorridos, indice, geom FROM resultados.q6_top10"
capa establecimientos_punta "SELECT id, amenity, nombre, comuna, rutas_400m, buses_hora_punta, paradero_mas_cercano_m, categoria, geom FROM resultados.q7"
capa recorridos_principales "SELECT shape_id, route_id, route_short_name, modo, direction_id, salidas_habil, geom FROM recorridos WHERE es_principal"
# El archivo lo crea root dentro del contenedor: se deja legible/borrable desde el host.
chmod 666 "$OUT"
