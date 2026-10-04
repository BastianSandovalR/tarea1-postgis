-- =====================================================================
-- 00 · Esquema base: extensiones, esquemas, parámetros y bitácora
-- Variables psql (las pasa cargar.sh): lon_min lat_min lon_max lat_max
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS hstore;

CREATE SCHEMA IF NOT EXISTS crudo;       -- staging: lo que sale de ogr2ogr / COPY, sin tocar
CREATE SCHEMA IF NOT EXISTS resultados;  -- salidas de las preguntas (Parte C)

-- Bitácora del ETL: filas cargadas, geometrías reparadas, tiempos.
-- El README y el informe se escriben a partir de esta tabla.
DROP TABLE IF EXISTS etl_log;
CREATE TABLE etl_log (
  id         serial PRIMARY KEY,
  paso       text NOT NULL,
  detalle    text,
  filas      bigint,
  registrado timestamptz DEFAULT clock_timestamp()
);

-- Qué archivo, qué versión y de qué fecha es cada fuente (va en README y en los mapas).
CREATE TABLE IF NOT EXISTS metadatos_fuentes (
  fuente      text PRIMARY KEY,
  archivo     text,
  version     text,
  fecha_datos text,
  detalle     text
);

-- Caja santiago-centro. Se guarda una vez y todo el ETL la lee de aquí.
DROP TABLE IF EXISTS parametros CASCADE;
CREATE TABLE parametros (
  lon_min float8, lat_min float8, lon_max float8, lat_max float8
);
INSERT INTO parametros VALUES (:lon_min, :lat_min, :lon_max, :lat_max);

-- Caja en 4326 (para filtrar lon/lat tal como la define el enunciado).
CREATE OR REPLACE FUNCTION caja_4326() RETURNS geometry
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT ST_MakeEnvelope(lon_min, lat_min, lon_max, lat_max, 4326) FROM parametros
$$;

-- Caja en 5361. Se densifica antes de proyectar: así los bordes siguen los
-- meridianos/paralelos de la caja original y no una recta entre 4 esquinas.
CREATE OR REPLACE FUNCTION caja() RETURNS geometry
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT ST_Transform(ST_Segmentize(caja_4326(), 0.001), 5361)
$$;

-- other_tags de ogr2ogr -> hstore, sin caerse si alguna fila viene mal formada.
-- PARALLEL UNSAFE: el bloque EXCEPTION abre una subtransacción y eso no se puede
-- hacer mientras corre una consulta paralela (ni en el líder: el commit de la
-- subtransacción fallaba con un WARNING y la función devolvía NULL).
CREATE OR REPLACE FUNCTION tags(t text) RETURNS hstore
LANGUAGE plpgsql IMMUTABLE PARALLEL UNSAFE AS $$
BEGIN
  RETURN t::hstore;
EXCEPTION WHEN others THEN
  RETURN NULL;
END $$;
