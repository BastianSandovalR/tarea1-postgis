-- =====================================================================
-- P1. Paraderos por comuna: cuántos paraderos GTFS hay por comuna y su
--     densidad (paraderos / km² de comuna).   Patrón: punto-en-polígono.
--
-- Decisiones:
--  * Sólo paraderos de BUS (modo = 'bus'); los andenes de Metro no son paraderos.
--  * Las comunas están recortadas a la caja; el área es la de la parte dentro
--    de la caja (área y paraderos miden lo mismo). "completa" = false marca
--    las comunas que la caja corta (Las Condes, La Florida, etc.).
--  * Join contra comunas_zona_sub (ST_Subdivide) y count(DISTINCT) por si un
--    paradero cae justo en el borde entre dos piezas de la misma comuna.
-- =====================================================================
\echo '=== P1. Paraderos GTFS de bus por comuna y densidad ==='

DROP TABLE IF EXISTS resultados.q1;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
CREATE TABLE resultados.q1 AS
SELECT c.id,
       c.cut,
       c.nombre                                             AS comuna,
       c.completa,
       round(c.area_km2::numeric, 2)                        AS area_km2,
       count(DISTINCT x.stop_id)                            AS paraderos,
       round((count(DISTINCT x.stop_id) / c.area_km2)::numeric, 1) AS paraderos_km2,
       c.geom
  FROM comunas_zona c
  LEFT JOIN (
        SELECT s.comuna_id, p.stop_id
          FROM comunas_zona_sub s
          JOIN paraderos_gtfs p
            ON ST_Intersects(s.geom, p.geom)
         WHERE p.modo = 'bus'
       ) x ON x.comuna_id = c.id
 GROUP BY c.id;

\echo ''
\echo '--- Resultado (ordenado por densidad) ---'
SELECT comuna, CASE WHEN completa THEN 'sí' ELSE 'no (cortada por la caja)' END AS completa,
       area_km2, paraderos, paraderos_km2
  FROM resultados.q1
 ORDER BY paraderos_km2 DESC;

SELECT sum(paraderos) AS total_paraderos_bus_en_comunas,
       round(sum(paraderos) / sum(area_km2), 1) AS densidad_zona
  FROM resultados.q1;

-- ---------------------------------------------------------------------
-- ¿Y sin el índice GIST? Se apagan los index/bitmap scans sólo para esta
-- consulta: el join tiene que comparar cada pieza contra cada paradero.
-- ---------------------------------------------------------------------
\echo ''
\echo '--- Mismo join SIN índices (enable_indexscan/bitmapscan = off) ---'
BEGIN;
SET LOCAL enable_indexscan = off;
SET LOCAL enable_bitmapscan = off;
EXPLAIN (ANALYZE, COSTS OFF)
SELECT s.comuna_id, count(DISTINCT p.stop_id)
  FROM comunas_zona_sub s
  JOIN paraderos_gtfs p ON ST_Intersects(s.geom, p.geom)
 WHERE p.modo = 'bus'
 GROUP BY s.comuna_id;
COMMIT;
