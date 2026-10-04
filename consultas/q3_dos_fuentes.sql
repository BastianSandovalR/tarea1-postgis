-- =====================================================================
-- P3. Dos fuentes, un objeto: ¿cuántos paraderos GTFS no tienen ningún
--     bus_stop de OSM a menos de 50 m, y viceversa?
--     Patrón: anti-join en los dos sentidos (NOT EXISTS + ST_DWithin 50 m).
--
-- Decisiones:
--  * GTFS sólo modo bus (un andén de Metro nunca tendrá un bus_stop al lado).
--  * 50 m como pide el enunciado: absorbe el error de dibujo en OSM y que el
--    GTFS a veces ubica el paradero al centro de la calzada.
-- =====================================================================
\echo '=== P3. Anti-join en los dos sentidos (radio 50 m) ==='

DROP TABLE IF EXISTS resultados.q3_gtfs_sin_osm;
DROP TABLE IF EXISTS resultados.q3_osm_sin_gtfs;
DROP TABLE IF EXISTS resultados.q3;

-- GTFS -> OSM
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
CREATE TABLE resultados.q3_gtfs_sin_osm AS
SELECT g.stop_id, g.nombre, g.geom
  FROM paraderos_gtfs g
 WHERE g.modo = 'bus'
   AND NOT EXISTS (SELECT 1 FROM paraderos_osm o WHERE ST_DWithin(o.geom, g.geom, 50));

-- OSM -> GTFS
CREATE TABLE resultados.q3_osm_sin_gtfs AS
SELECT o.id, o.osm_id, o.nombre, o.geom
  FROM paraderos_osm o
 WHERE NOT EXISTS (SELECT 1 FROM paraderos_gtfs g
                    WHERE g.modo = 'bus' AND ST_DWithin(g.geom, o.geom, 50));

CREATE TABLE resultados.q3 AS
SELECT 'GTFS (bus) sin bus_stop OSM a < 50 m'::text AS sentido,
       (SELECT count(*) FROM paraderos_gtfs WHERE modo = 'bus') AS total,
       (SELECT count(*) FROM resultados.q3_gtfs_sin_osm)       AS sin_pareja
UNION ALL
SELECT 'bus_stop OSM sin paradero GTFS a < 50 m',
       (SELECT count(*) FROM paraderos_osm),
       (SELECT count(*) FROM resultados.q3_osm_sin_gtfs);

\echo ''
\echo '--- Resultado ---'
SELECT sentido, total, sin_pareja, round(100.0 * sin_pareja / nullif(total, 0), 1) AS pct_sin_pareja
  FROM resultados.q3;

\echo ''
\echo '--- Por comuna (dónde se concentran los faltantes) ---'
SELECT c.nombre AS comuna,
       (SELECT count(*) FROM resultados.q3_gtfs_sin_osm x WHERE ST_Intersects(c.geom, x.geom)) AS gtfs_sin_osm,
       (SELECT count(*) FROM resultados.q3_osm_sin_gtfs x WHERE ST_Intersects(c.geom, x.geom)) AS osm_sin_gtfs
  FROM comunas_zona c
 ORDER BY 2 DESC, 1;

\echo ''
\echo '--- Sensibilidad al radio: con 25, 50 y 100 m ---'
SELECT r AS radio_m,
       (SELECT count(*) FROM paraderos_gtfs g WHERE g.modo = 'bus'
           AND NOT EXISTS (SELECT 1 FROM paraderos_osm o WHERE ST_DWithin(o.geom, g.geom, r))) AS gtfs_sin_osm,
       (SELECT count(*) FROM paraderos_osm o
           WHERE NOT EXISTS (SELECT 1 FROM paraderos_gtfs g WHERE g.modo = 'bus' AND ST_DWithin(g.geom, o.geom, r))) AS osm_sin_gtfs
  FROM unnest(ARRAY[25, 50, 100]) AS r;
