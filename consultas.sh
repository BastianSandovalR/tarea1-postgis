#!/usr/bin/env bash
# =====================================================================
# Tarea 1 — Parte C: corre las 7 preguntas, guarda resultados y planes,
# exporta el GeoPackage y dibuja los mapas.
#
#   ./consultas.sh                (después de ./cargar.sh)
#   RUTA=210 ./consultas.sh       (P5 con otro recorrido; por defecto 506)
#
# Salidas (se versionan, son parte de la entrega):
#   resultados/q*.txt                   consulta + resultado + EXPLAIN ANALYZE
#   salidas/tarea1_resultados.gpkg      capas de resultados para QGIS
#   salidas/mapas/*.png                 mapas del informe
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")"
RUTA="${RUTA:-506}"
DC="docker compose"
mkdir -p resultados salidas/mapas

paso() { printf '\n\033[1m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }

$DC up -d db >/dev/null
until $DC exec -T db psql -X -q -c "SELECT 1" >/dev/null 2>&1; do sleep 2; done
$DC exec -T db psql -X -tA -c "SELECT to_regclass('public.paraderos_gtfs') IS NOT NULL" | grep -q t \
  || { echo "ERROR: no hay datos cargados. Corra primero ./cargar.sh" >&2; exit 1; }

# Estadísticas de uso de índices en cero: q8 muestra sólo lo que usan P1..P7.
$DC exec -T db psql -X -q -c "SELECT pg_stat_reset()" >/dev/null

for f in consultas/q*.sql; do
  nombre=$(basename "$f" .sql)
  paso "$nombre"
  # -e: el archivo de salida muestra cada consulta antes de su resultado.
  $DC exec -T db psql -X -e -v ON_ERROR_STOP=1 -v ruta="$RUTA" \
      -P pager=off -P null='∅' -f "/consultas/$nombre.sql" > "resultados/$nombre.txt" 2>&1 \
    || { tail -20 "resultados/$nombre.txt"; echo "ERROR en $nombre (ver resultados/$nombre.txt)" >&2; exit 1; }
  grep -E "Execution Time|^\(" "resultados/$nombre.txt" | head -6 | sed 's/^/  /'
done

paso "GeoPackage -> salidas/tarea1_resultados.gpkg"
$DC exec -T db bash /scripts/exportar_gpkg.sh

paso "Mapas -> salidas/mapas/"
$DC --profile mapas run --rm --user "$(id -u):$(id -g)" mapas python /app/mapas.py

paso "Listo. Resultados en resultados/, mapas en salidas/mapas/"
