-- =====================================================================
-- 10 · OSM: crudo.{points,lines,multipolygons} (5361) -> tablas propias
--   calles, edificios (con punto interior), paraderos_osm, amenidades
-- =====================================================================

-- ---------------------------------------------------------------------
-- 10.1 Normalizar columnas.
-- Con el PBF + docker/osmconf.ini estas columnas ya existen. Si la fuente
-- fue el GPKG del Lab 05 (osmconf por defecto), amenity de los puntos viene
-- dentro de other_tags: se completa desde ahí para que el resto no cambie.
-- ---------------------------------------------------------------------
ALTER TABLE crudo.points        ADD COLUMN IF NOT EXISTS other_tags text;
ALTER TABLE crudo.lines         ADD COLUMN IF NOT EXISTS other_tags text;
ALTER TABLE crudo.multipolygons ADD COLUMN IF NOT EXISTS other_tags text;
ALTER TABLE crudo.points        ADD COLUMN IF NOT EXISTS amenity text;
ALTER TABLE crudo.points        ADD COLUMN IF NOT EXISTS highway text;
ALTER TABLE crudo.points        ADD COLUMN IF NOT EXISTS name text;
ALTER TABLE crudo.points        ADD COLUMN IF NOT EXISTS ref text;
ALTER TABLE crudo.points        ADD COLUMN IF NOT EXISTS osm_id text;
ALTER TABLE crudo.lines         ADD COLUMN IF NOT EXISTS osm_id text;
ALTER TABLE crudo.multipolygons ADD COLUMN IF NOT EXISTS osm_id text;
ALTER TABLE crudo.multipolygons ADD COLUMN IF NOT EXISTS osm_way_id text;
ALTER TABLE crudo.lines         ADD COLUMN IF NOT EXISTS highway text;
ALTER TABLE crudo.lines         ADD COLUMN IF NOT EXISTS name text;
ALTER TABLE crudo.multipolygons ADD COLUMN IF NOT EXISTS amenity text;
ALTER TABLE crudo.multipolygons ADD COLUMN IF NOT EXISTS building text;
ALTER TABLE crudo.multipolygons ADD COLUMN IF NOT EXISTS name text;

UPDATE crudo.points SET amenity = tags(other_tags) -> 'amenity'
 WHERE amenity IS NULL AND other_tags LIKE '%"amenity"=>%';
UPDATE crudo.points SET highway = tags(other_tags) -> 'highway'
 WHERE highway IS NULL AND other_tags LIKE '%"highway"=>%';

ANALYZE crudo.points;
ANALYZE crudo.lines;
ANALYZE crudo.multipolygons;

INSERT INTO etl_log(paso, detalle, filas)
SELECT 'osm_crudo', 'crudo.points', count(*) FROM crudo.points UNION ALL
SELECT 'osm_crudo', 'crudo.lines', count(*) FROM crudo.lines UNION ALL
SELECT 'osm_crudo', 'crudo.multipolygons', count(*) FROM crudo.multipolygons;

-- ---------------------------------------------------------------------
-- 10.2 Geometrías inválidas: contar, clasificar por motivo, reparar.
-- Se hace en 5361 (ogr2ogr ya reproyectó): la validez se evalúa en el
-- mismo sistema en que se van a hacer los cálculos.
-- ---------------------------------------------------------------------
INSERT INTO etl_log(paso, detalle, filas)
SELECT 'osm_invalidas', 'multipolygons: ' || split_part(ST_IsValidReason(geom), '[', 1), count(*)
  FROM crudo.multipolygons
 WHERE geom IS NOT NULL AND NOT ST_IsValid(geom)
 GROUP BY 2;

INSERT INTO etl_log(paso, detalle, filas)
SELECT 'osm_invalidas', 'lines: ' || split_part(ST_IsValidReason(geom), '[', 1), count(*)
  FROM crudo.lines
 WHERE geom IS NOT NULL AND NOT ST_IsValid(geom)
 GROUP BY 2;

-- Reparación: ST_MakeValid puede devolver una GeometryCollection (p.ej. un
-- polígono en "corbatín" deja polígonos + una línea suelta); nos quedamos
-- sólo con la parte poligonal (tipo 3) y la volvemos MultiPolygon.
WITH rep AS (
  UPDATE crudo.multipolygons
     SET geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
   WHERE geom IS NOT NULL AND NOT ST_IsValid(geom)
  RETURNING 1
)
INSERT INTO etl_log(paso, detalle, filas)
SELECT 'osm_reparadas', 'multipolygons reparadas con ST_MakeValid', count(*) FROM rep;

-- Una línea inválida (p.ej. 2 vértices iguales) puede quedar como punto tras
-- repararla: la columna se abre a Geometry y calles toma sólo LineStrings.
ALTER TABLE crudo.lines ALTER COLUMN geom TYPE geometry(Geometry, 5361);
WITH rep AS (
  UPDATE crudo.lines SET geom = ST_MakeValid(geom)
   WHERE geom IS NOT NULL AND NOT ST_IsValid(geom)
  RETURNING 1
)
INSERT INTO etl_log(paso, detalle, filas)
SELECT 'osm_reparadas', 'lines reparadas con ST_MakeValid', count(*) FROM rep;

-- Lo que quedó vacío tras reparar (p.ej. un "polígono" de área cero) se descarta.
WITH del AS (
  DELETE FROM crudo.multipolygons WHERE geom IS NULL OR ST_IsEmpty(geom) RETURNING 1
)
INSERT INTO etl_log(paso, detalle, filas)
SELECT 'osm_descartadas', 'multipolygons vacías tras ST_MakeValid', count(*) FROM del;

-- ---------------------------------------------------------------------
-- 10.3 calles: todas las vías con highway (incluye peatonales y ciclovías).
-- es_vehicular marca las que puede usar un bus; se deja la columna para
-- filtrar en las consultas en vez de perder información en el ETL.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS calles CASCADE;
CREATE TABLE calles AS
SELECT ogc_fid::bigint                                AS id,
       osm_id,
       name                                           AS nombre,
       highway                                        AS tipo,
       highway IN ('motorway','motorway_link','trunk','trunk_link','primary','primary_link',
                   'secondary','secondary_link','tertiary','tertiary_link','unclassified',
                   'residential','living_street','service','busway','road') AS es_vehicular,
       ST_Length(g)                                   AS largo_m,
       g::geometry(LineString, 5361)                  AS geom
  FROM crudo.lines l
 CROSS JOIN LATERAL (SELECT (ST_Dump(l.geom)).geom AS g) d   -- por si ST_MakeValid dejó multilíneas
 WHERE l.highway IS NOT NULL
   AND ST_GeometryType(d.g) = 'ST_LineString'
   AND ST_Intersects(d.g, caja());
ALTER TABLE calles ADD COLUMN gid bigserial PRIMARY KEY;

-- ---------------------------------------------------------------------
-- 10.4 edificios: polígono + punto interior.
-- ST_PointOnSurface garantiza un punto DENTRO del polígono (el centroide
-- puede caer fuera en edificios en L o con patio). Se usa el punto para
-- contar/asignar (cada edificio cae en una sola celda/comuna) y el polígono
-- para áreas. Entra a la caja si su punto interior está en la caja.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS edificios CASCADE;
CREATE TABLE edificios AS
SELECT ogc_fid::bigint                            AS id,
       coalesce(osm_id, osm_way_id)               AS osm_id,
       name                                       AS nombre,
       building                                   AS tipo,
       ST_Area(geom)                              AS area_m2,
       geom::geometry(MultiPolygon, 5361)         AS geom,
       ST_PointOnSurface(geom)::geometry(Point, 5361) AS punto
  FROM crudo.multipolygons
 WHERE building IS NOT NULL AND building <> 'no'
   AND ST_Intersects(ST_PointOnSurface(geom), caja());
ALTER TABLE edificios ADD PRIMARY KEY (id);

-- ---------------------------------------------------------------------
-- 10.5 paraderos_osm: nodos highway=bus_stop (lo que dibujó la comunidad).
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS paraderos_osm CASCADE;
CREATE TABLE paraderos_osm AS
SELECT ogc_fid::bigint                    AS id,
       osm_id,
       name                               AS nombre,
       coalesce(ref, tags(other_tags) -> 'ref') AS ref,
       geom::geometry(Point, 5361)        AS geom
  FROM crudo.points
 WHERE highway = 'bus_stop'
   AND ST_Intersects(geom, caja());
ALTER TABLE paraderos_osm ADD PRIMARY KEY (id);

-- ---------------------------------------------------------------------
-- 10.6 amenidades: nodos + polígonos con amenity.
-- Los hospitales y clínicas casi siempre están mapeados como polígono; si
-- sólo se usaran nodos se perderían. Los polígonos se representan con su
-- punto interior (origen = 'poligono') para que todas sean Point.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS amenidades CASCADE;
CREATE TABLE amenidades AS
SELECT 'nodo'::text AS origen, osm_id, amenity, name AS nombre,
       geom::geometry(Point, 5361) AS geom
  FROM crudo.points
 WHERE amenity IS NOT NULL AND ST_Intersects(geom, caja())
UNION ALL
SELECT 'poligono', coalesce(osm_id, osm_way_id), amenity, name,
       ST_PointOnSurface(geom)::geometry(Point, 5361)
  FROM crudo.multipolygons
 WHERE amenity IS NOT NULL AND ST_Intersects(ST_PointOnSurface(geom), caja());
ALTER TABLE amenidades ADD COLUMN id bigserial PRIMARY KEY;

INSERT INTO etl_log(paso, detalle, filas)
SELECT 'osm_tabla', 'calles', count(*) FROM calles UNION ALL
SELECT 'osm_tabla', 'edificios', count(*) FROM edificios UNION ALL
SELECT 'osm_tabla', 'paraderos_osm', count(*) FROM paraderos_osm UNION ALL
SELECT 'osm_tabla', 'amenidades', count(*) FROM amenidades;
