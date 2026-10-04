#!/usr/bin/env bash
# Corre DENTRO del contenedor db (lo llama cargar.sh).
# GTFS (ZIP de CSV) -> tablas crudo.gtfs_* con COPY (nunca INSERT fila a fila).
#
# Las columnas se leen del encabezado de cada archivo, así el orden o las columnas
# extra que publique la DTPM no rompen la carga. Todo se carga como texto; los tipos
# se fijan en sql/20_gtfs.sql.
#
# Uso: gtfs_a_crudo.sh /datos/GTFS_AAAAMMDD.zip
set -euo pipefail

ZIP="$1"
DIR=/tmp/gtfs
rm -rf "$DIR" && mkdir -p "$DIR"
unzip -o -q "$ZIP" -d "$DIR"

# Si el ZIP trae una carpeta interna, subir los .txt al nivel raíz.
find "$DIR" -mindepth 2 -name '*.txt' -exec mv -t "$DIR" {} + 2>/dev/null || true

OBLIGATORIOS="stops routes trips shapes stop_times"
OPCIONALES="calendar calendar_dates frequencies feed_info agency"

cargar() {
  local nombre="$1" archivo="$DIR/$1.txt"
  # Encabezado: sin BOM, sin \r, sin comillas, en minúsculas y con nombres SQL seguros.
  local cols
  cols=$(head -1 "$archivo" | sed 's/^\xEF\xBB\xBF//' | tr -d '\r"' | tr 'A-Z' 'a-z' \
         | tr ',' '\n' | sed 's/[^a-z0-9_]/_/g' | awk '{printf "%s\"%s\" text", (NR>1?", ":""), $0}')
  # UNLOGGED: es staging reconstruible; no necesita WAL (carga más rápida).
  psql -X -q -v ON_ERROR_STOP=1 <<SQL
DROP TABLE IF EXISTS crudo.gtfs_${nombre};
CREATE UNLOGGED TABLE crudo.gtfs_${nombre} (${cols});
COPY crudo.gtfs_${nombre} FROM '${archivo}' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
ANALYZE crudo.gtfs_${nombre};
INSERT INTO etl_log(paso, detalle, filas)
SELECT 'gtfs_copy', '${nombre}.txt -> crudo.gtfs_${nombre}', count(*) FROM crudo.gtfs_${nombre};
SQL
  printf "  -> %-16s %10s filas\n" "$nombre.txt" \
    "$(psql -X -tA -c "SELECT count(*) FROM crudo.gtfs_${nombre}")"
}

for f in $OBLIGATORIOS; do
  [ -f "$DIR/$f.txt" ] || { echo "ERROR: el ZIP no trae $f.txt" >&2; exit 1; }
  cargar "$f"
done
for f in $OPCIONALES; do
  if [ -f "$DIR/$f.txt" ]; then cargar "$f"
  else
    psql -X -q -c "DROP TABLE IF EXISTS crudo.gtfs_${f}"
    echo "  -> $f.txt no viene en el ZIP (opcional)"
  fi
done

# Versión del feed para el README / los mapas.
VERSION="(sin feed_info.txt)"
VIGENCIA=""
if [ -f "$DIR/feed_info.txt" ]; then
  VERSION=$(psql -X -tA -c "SELECT feed_version FROM crudo.gtfs_feed_info LIMIT 1" 2>/dev/null || echo "?")
  VIGENCIA=$(psql -X -tA -c "SELECT feed_start_date || ' a ' || feed_end_date FROM crudo.gtfs_feed_info LIMIT 1" 2>/dev/null || echo "")
fi
psql -X -q -v ON_ERROR_STOP=1 <<SQL
INSERT INTO metadatos_fuentes VALUES
  ('GTFS', '$(basename "$ZIP")', 'feed_version $VERSION', 'vigencia $VIGENCIA',
   'DTPM, https://www.dtpm.cl/index.php/noticias/gtfs-vigente; carga con COPY')
ON CONFLICT (fuente) DO UPDATE SET archivo=EXCLUDED.archivo, version=EXCLUDED.version,
   fecha_datos=EXCLUDED.fecha_datos, detalle=EXCLUDED.detalle;
SQL
rm -rf "$DIR"
