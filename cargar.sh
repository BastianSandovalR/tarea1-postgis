#!/usr/bin/env bash
# =====================================================================
# Tarea 1 — carga completa: OSM + GTFS + DPA -> PostGIS (SRID 5361)
#
#   docker compose up -d
#   ./cargar.sh
#
# Requisitos en el host: sólo Docker (con compose) y bash.
# Los archivos fuente van en ./datos (ver datos/LEEME.md).
#
# Variables opcionales:
#   BBOX="lon_min,lat_min,lon_max,lat_max"   (por defecto la caja santiago-centro)
#   GTFS_ZIP=datos/GTFS_20260829.zip         (por defecto el GTFS_*.zip más nuevo)
#   OSM_FUENTE=datos/chile-latest.osm.pbf    (por defecto el .pbf, o si no el .gpkg)
#
# Es idempotente: se puede correr de nuevo y rehace todo (salvo comunas_cl,
# que se carga una sola vez porque el dump pesa 218 MB).
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")"

# Fecha/origen de las fuentes (versionado): ver fuentes.env
[ -f fuentes.env ] && . ./fuentes.env
BBOX="${BBOX:--70.75,-33.52,-70.52,-33.36}"
IFS=',' read -r LON_MIN LAT_MIN LON_MAX LAT_MAX <<< "$BBOX"
DC="docker compose"

mkdir -p resultados salidas
exec > >(tee resultados/00_log_carga.txt) 2>&1

T0=$(date +%s)
paso() { printf '\n\033[1m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
psql_db() { $DC exec -T db psql -X -q -v ON_ERROR_STOP=1 "$@"; }
fallar() { echo "ERROR: $*" >&2; exit 1; }
cronometro() {  # registra en etl_log cuánto tardó un paso
  psql_db -c "INSERT INTO etl_log(paso, detalle, filas) VALUES ('tiempo', '$1 (segundos)', $2)"
}

# ---------------------------------------------------------------------
paso "0/6 Archivos fuente en ./datos"
# ---------------------------------------------------------------------
if [ -z "${OSM_FUENTE:-}" ]; then
  if   [ -f datos/chile-latest.osm.pbf ];     then OSM_FUENTE=datos/chile-latest.osm.pbf
  elif ls datos/*.osm.pbf >/dev/null 2>&1;     then OSM_FUENTE=$(ls datos/*.osm.pbf | head -1)   # p. ej. santiago-centro.osm.pbf
  elif [ -f datos/osm_santiago-centro.gpkg ]; then OSM_FUENTE=datos/osm_santiago-centro.gpkg
  elif ls datos/osm_*.gpkg >/dev/null 2>&1;    then OSM_FUENTE=$(ls datos/osm_*.gpkg | head -1)
  else fallar "falta OSM: deje datos/chile-latest.osm.pbf (o osm_santiago-centro.gpkg del Lab 05)"
  fi
fi
if [ -z "${GTFS_ZIP:-}" ]; then
  GTFS_ZIP=$(ls datos/GTFS*.zip datos/gtfs*.zip 2>/dev/null | sort | tail -1 || true)
  [ -n "$GTFS_ZIP" ] || fallar "falta el GTFS: deje el ZIP de la DTPM en datos/ (GTFS_AAAAMMDD.zip)"
fi
[ -f datos/comunas_cl.sql ] || fallar "falta datos/comunas_cl.sql (Lab 03: 03/datos/comunas_cl.sql)"

echo "  OSM     : $OSM_FUENTE"
echo "  GTFS    : $GTFS_ZIP"
echo "  DPA     : datos/comunas_cl.sql"
echo "  Caja    : $BBOX"
[ -n "${OSM_FECHA:-}" ] && echo "  OSM al  : $OSM_FECHA (fuentes.env)"

# ---------------------------------------------------------------------
paso "1/6 PostGIS arriba"
# ---------------------------------------------------------------------
$DC up -d db
for i in $(seq 1 60); do
  if $DC exec -T db pg_isready -q -U postgres -d tarea1 2>/dev/null; then break; fi
  [ "$i" = 60 ] && fallar "PostGIS no respondió en 2 minutos (docker compose logs db)"
  sleep 2
done
# pg_isready responde también durante el arranque inicial; esperar a que la base exista.
until psql_db -c "SELECT 1" >/dev/null 2>&1; do sleep 2; done
echo "  ok"

psql_db -v lon_min="$LON_MIN" -v lat_min="$LAT_MIN" -v lon_max="$LON_MAX" -v lat_max="$LAT_MAX" \
        -f /sql/00_esquema.sql

# ---------------------------------------------------------------------
paso "2/6 OSM -> crudo -> calles, edificios, paraderos_osm, amenidades"
# ---------------------------------------------------------------------
t=$(date +%s)
$DC exec -T -e OSM_FECHA="${OSM_FECHA:-}" -e OSM_ORIGEN="${OSM_ORIGEN:-}" \
    db bash /scripts/osm_a_crudo.sh "/$OSM_FUENTE" "$BBOX"
psql_db -f /sql/10_osm.sql
cronometro "OSM" $(( $(date +%s) - t ))

# ---------------------------------------------------------------------
paso "3/6 GTFS -> crudo (COPY) -> paraderos_gtfs, recorridos, servicio_paradero"
# ---------------------------------------------------------------------
t=$(date +%s)
$DC exec -T db bash /scripts/gtfs_a_crudo.sh "/$GTFS_ZIP"
psql_db -f /sql/20_gtfs.sql
cronometro "GTFS" $(( $(date +%s) - t ))

# ---------------------------------------------------------------------
paso "4/6 DPA -> comunas_zona (+ ST_Subdivide)"
# ---------------------------------------------------------------------
t=$(date +%s)
YA=$(psql_db -tA -c "SELECT count(*) FROM geometry_columns
                     WHERE f_table_name ILIKE '%comuna%'
                       AND f_table_name NOT IN ('comunas_zona','comunas_zona_sub')")
if [ "$YA" = "0" ]; then
  echo "  -> cargando comunas_cl.sql (218 MB, tarda un rato)..."
  # El dump puede traer CREATE EXTENSION / SET que fallan sin importancia:
  # no se corta en el primer error; se cuentan y se verifica después.
  $DC exec -T db psql -X -q -v ON_ERROR_STOP=0 -f /datos/comunas_cl.sql \
      > /dev/null 2> resultados/00_log_comunas_cl.txt || true
  echo "  -> mensajes de error del dump: $(grep -c 'ERROR' resultados/00_log_comunas_cl.txt || true) (ver resultados/00_log_comunas_cl.txt)"
else
  echo "  -> la tabla de comunas ya estaba cargada; no se recarga el dump"
fi
psql_db -c "INSERT INTO metadatos_fuentes VALUES ('DPA', 'comunas_cl.sql', 'División Política Administrativa 2023 (INE), dump del Lab 03', '2023', 'psql -f')
            ON CONFLICT (fuente) DO NOTHING"
psql_db -f /sql/30_dpa.sql
cronometro "DPA" $(( $(date +%s) - t ))

# ---------------------------------------------------------------------
paso "5/6 Índices + VACUUM ANALYZE"
# ---------------------------------------------------------------------
t=$(date +%s)
psql_db -f /sql/40_indices.sql
psql_db -c "VACUUM (ANALYZE)"
cronometro "Índices y ANALYZE" $(( $(date +%s) - t ))
cronometro "TOTAL cargar.sh" $(( $(date +%s) - T0 ))

# ---------------------------------------------------------------------
paso "6/6 Resumen -> resultados/00_resumen_carga.md"
# ---------------------------------------------------------------------
$DC exec -T db psql -X -q -tA -v ON_ERROR_STOP=1 -f /sql/50_resumen.sql > resultados/00_resumen_carga.md
cat resultados/00_resumen_carga.md

# Copiar el resumen a la sección 5 del README (entre los marcadores).
if grep -q '<!-- CONTEOS:INICIO -->' README.md; then
  awk -v f=resultados/00_resumen_carga.md '
    /<!-- CONTEOS:INICIO -->/ { print; while ((getline l < f) > 0) print l; skip=1; next }
    /<!-- CONTEOS:FIN -->/    { skip=0 }
    !skip' README.md > README.md.tmp && mv README.md.tmp README.md
  echo "  -> README.md §5 actualizado"
fi

paso "Listo en $(( $(date +%s) - T0 )) s. Siguiente: ./consultas.sh"
