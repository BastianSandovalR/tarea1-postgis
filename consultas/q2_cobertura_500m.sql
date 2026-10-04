-- =====================================================================
-- P2. Cobertura: % de edificios (OSM) de cada comuna a MÁS de 500 m de
--     cualquier paradero. Primero con paraderos GTFS, luego con
--     paraderos_osm, y se comparan.     Patrón: anti-join con ST_DWithin.
--
-- Decisiones:
--  * Cada edificio se representa por su PUNTO INTERIOR (ST_PointOnSurface):
--    la distancia se mide desde dentro del edificio y cada uno cuenta en una
--    sola comuna. Medir desde el polígono (distancia al borde) favorecería a
--    los edificios grandes.
--  * GTFS: sólo paraderos de bus, para comparar lo mismo contra highway=bus_stop.
--  * ST_DWithin(a, b, 500) en 5361 = 500 metros reales y usa el GIST.
-- =====================================================================
\echo '=== P2. % de edificios a más de 500 m de un paradero (GTFS vs OSM) ==='

DROP TABLE IF EXISTS resultados.q2;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
CREATE TABLE resultados.q2 AS
WITH ed AS (                      -- edificio -> comuna (punto en polígono, 1 pieza por edificio)
  SELECT e.id, e.punto, s.comuna_id
    FROM edificios e
    CROSS JOIN LATERAL (
          SELECT sub.comuna_id FROM comunas_zona_sub sub
           WHERE ST_Intersects(sub.geom, e.punto) LIMIT 1) s
),
lejos_gtfs AS (                   -- anti-join 1: ningún paradero GTFS a <= 500 m
  SELECT ed.comuna_id, count(*) AS n
    FROM ed
   WHERE NOT EXISTS (SELECT 1 FROM paraderos_gtfs p
                      WHERE p.modo = 'bus' AND ST_DWithin(p.geom, ed.punto, 500))
   GROUP BY ed.comuna_id
),
lejos_osm AS (                    -- anti-join 2: ningún bus_stop OSM a <= 500 m
  SELECT ed.comuna_id, count(*) AS n
    FROM ed
   WHERE NOT EXISTS (SELECT 1 FROM paraderos_osm p
                      WHERE ST_DWithin(p.geom, ed.punto, 500))
   GROUP BY ed.comuna_id
),
total AS (
  SELECT comuna_id, count(*) AS n FROM ed GROUP BY comuna_id
)
SELECT c.id, c.nombre AS comuna,
       t.n                                              AS edificios,
       coalesce(g.n, 0)                                 AS lejos_gtfs,
       coalesce(o.n, 0)                                 AS lejos_osm,
       round(100.0 * coalesce(g.n, 0) / t.n, 1)         AS pct_lejos_gtfs,
       round(100.0 * coalesce(o.n, 0) / t.n, 1)         AS pct_lejos_osm,
       round(100.0 * (coalesce(o.n, 0) - coalesce(g.n, 0)) / t.n, 1) AS dif_pp_osm_menos_gtfs,
       c.geom
  FROM comunas_zona c
  JOIN total t           ON t.comuna_id = c.id
  LEFT JOIN lejos_gtfs g ON g.comuna_id = c.id
  LEFT JOIN lejos_osm  o ON o.comuna_id = c.id;

\echo ''
\echo '--- Resultado por comuna (ordenado por % lejos según GTFS) ---'
SELECT comuna, edificios, pct_lejos_gtfs, pct_lejos_osm, dif_pp_osm_menos_gtfs
  FROM resultados.q2
 ORDER BY pct_lejos_gtfs DESC, comuna;

\echo ''
\echo '--- Total de la zona ---'
SELECT sum(edificios) AS edificios,
       round(100.0 * sum(lejos_gtfs) / sum(edificios), 2) AS pct_lejos_gtfs,
       round(100.0 * sum(lejos_osm)  / sum(edificios), 2) AS pct_lejos_osm
  FROM resultados.q2;

\echo ''
\echo '--- ¿Cambia la conclusión? Ranking de las 5 comunas peor cubiertas según cada fuente ---'
SELECT r_gtfs.pos, r_gtfs.comuna AS peor_segun_gtfs, r_gtfs.pct_lejos_gtfs,
       r_osm.comuna AS peor_segun_osm, r_osm.pct_lejos_osm
  FROM (SELECT row_number() OVER (ORDER BY pct_lejos_gtfs DESC, comuna) AS pos, comuna, pct_lejos_gtfs FROM resultados.q2) r_gtfs
  JOIN (SELECT row_number() OVER (ORDER BY pct_lejos_osm  DESC, comuna) AS pos, comuna, pct_lejos_osm  FROM resultados.q2) r_osm
 USING (pos)
 WHERE pos <= 5
 ORDER BY pos;

\echo ''
\echo '--- Sin índice sólo se muestra el plan estimado (con EXPLAIN ANALYZE tardaría demasiado) ---'
BEGIN;
SET LOCAL enable_indexscan = off;
SET LOCAL enable_bitmapscan = off;
EXPLAIN
SELECT count(*) FROM edificios e
 WHERE NOT EXISTS (SELECT 1 FROM paraderos_gtfs p
                    WHERE p.modo = 'bus' AND ST_DWithin(p.geom, e.punto, 500));
COMMIT;
