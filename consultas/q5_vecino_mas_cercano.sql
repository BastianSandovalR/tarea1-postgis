-- =====================================================================
-- P5. Vecino más cercano: para cada paradero de UN recorrido, la farmacia
--     o centro de salud (amenity en pharmacy, hospital, clinic, doctors)
--     más cercano y a qué distancia.
--     Patrón: CROSS JOIN LATERAL + ORDER BY <-> + LIMIT 1 (KNN con GIST).
--
-- Recorrido elegido: 506 (Maipú - Peñalolén). Cruza la zona de poniente a
-- oriente por la Alameda / Providencia, pasando por el centro y por zonas
-- menos densas, así que mezcla paraderos con mucha y poca oferta de salud.
-- Se puede cambiar: RUTA=210 ./consultas.sh
--
-- Paraderos del recorrido: los del viaje representativo de cada sentido
-- (el que usa el shape principal), en su orden (stop_sequence), dentro de
-- la caja. Las amenidades incluyen polígonos (hospitales) como punto interior.
-- =====================================================================
\if :{?ruta}
\else
  \set ruta 506
\endif
\echo '=== P5. Salud más cercana a cada paradero del recorrido' :ruta '==='

DROP TABLE IF EXISTS resultados.q5;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
CREATE TABLE resultados.q5 AS
WITH viaje AS (            -- un viaje por sentido, del shape principal
  SELECT DISTINCT ON (v.direction_id) v.trip_id, v.direction_id
    FROM gtfs_viajes v
    JOIN gtfs_rutas  ru ON ru.route_id = v.route_id
    JOIN recorridos  r  ON r.shape_id  = v.shape_id AND r.es_principal
   WHERE ru.route_short_name = :'ruta'
   ORDER BY v.direction_id, v.trip_id
),
paradas AS (
  SELECT vi.direction_id AS sentido, st.stop_sequence::int AS orden,
         p.stop_id, p.nombre, p.geom
    FROM viaje vi
    JOIN crudo.gtfs_stop_times st ON st.trip_id = vi.trip_id
    JOIN paraderos_gtfs p         ON p.stop_id  = st.stop_id
)
SELECT pa.sentido, pa.orden, pa.stop_id, pa.nombre AS paradero,
       s.amenity, s.nombre AS lugar_salud, round(s.dist::numeric) AS distancia_m,
       pa.geom,
       s.geom AS geom_salud,
       ST_MakeLine(pa.geom, s.geom)::geometry(LineString, 5361) AS geom_linea
  FROM paradas pa
  CROSS JOIN LATERAL (
        SELECT a.amenity, a.nombre, a.geom,
               a.geom <-> pa.geom AS dist          -- en 5361 es distancia en metros
          FROM amenidades a
         WHERE a.amenity IN ('pharmacy', 'hospital', 'clinic', 'doctors')
         ORDER BY a.geom <-> pa.geom
         LIMIT 1
       ) s;

\echo ''
\echo '--- Resultado (paraderos en orden de recorrido) ---'
SELECT sentido, orden, stop_id, left(paradero, 45) AS paradero, amenity,
       left(coalesce(lugar_salud, '(sin nombre)'), 35) AS lugar_salud, distancia_m
  FROM resultados.q5
 ORDER BY sentido, orden;

\echo ''
\echo '--- Resumen ---'
SELECT count(*)                                              AS paraderos,
       round(avg(distancia_m))                               AS distancia_media_m,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY distancia_m) AS mediana_m,
       max(distancia_m)                                      AS maxima_m,
       count(*) FILTER (WHERE distancia_m > 500)             AS paraderos_a_mas_de_500m
  FROM resultados.q5;

SELECT amenity, count(*) AS veces_el_mas_cercano
  FROM resultados.q5 GROUP BY amenity ORDER BY 2 DESC;

-- ---------------------------------------------------------------------
-- Sin índice: el ORDER BY <-> ... LIMIT 1 se vuelve "leer todas las
-- amenidades de salud y ordenarlas" para CADA paradero.
-- ---------------------------------------------------------------------
\echo ''
\echo '--- Mismo KNN SIN índices ---'
BEGIN;
SET LOCAL enable_indexscan = off;
SET LOCAL enable_bitmapscan = off;
EXPLAIN (ANALYZE, COSTS OFF)
SELECT pa.stop_id, s.dist
  FROM (SELECT stop_id, geom FROM resultados.q5) pa
  CROSS JOIN LATERAL (
        SELECT a.geom <-> pa.geom AS dist FROM amenidades a
         WHERE a.amenity IN ('pharmacy', 'hospital', 'clinic', 'doctors')
         ORDER BY a.geom <-> pa.geom LIMIT 1) s;
COMMIT;
