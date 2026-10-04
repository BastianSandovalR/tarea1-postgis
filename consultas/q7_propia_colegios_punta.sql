-- =====================================================================
-- P7 (propia). ¿Qué tan bien servidos en la PUNTA DE LA MAÑANA (07:00-09:00,
--     martes) están los establecimientos educacionales?
--
--   OSM : colegios, institutos y universidades (amenity school/college/university)
--   GTFS: paraderos de bus + horarios expandidos desde frequencies.txt
--
-- Medida: buses por hora que pasan a <= 400 m del establecimiento
-- (~5 min a pie) en la punta AM. Para no contar dos veces el mismo bus en
-- dos paraderos vecinos, por cada (ruta, sentido) se toma el paradero
-- cercano con más pasadas, y luego se suma entre rutas/sentidos.
--
-- Por qué no es variante de P2: P2 mide DISTANCIA a un paradero (existe o
-- no, todo el día). Aquí se mide FRECUENCIA en la hora en que los alumnos
-- viajan: un colegio puede tener un paradero a 100 m por el que pasan 2
-- buses por hora. Usa stop_times + frequencies, que ninguna otra pregunta usa.
-- =====================================================================
\echo '=== P7. Oferta de buses en punta AM alrededor de establecimientos educacionales ==='

DROP TABLE IF EXISTS resultados.q7;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
CREATE TABLE resultados.q7 AS
WITH esc AS (
  SELECT a.id, a.amenity, a.nombre, a.origen, a.geom
    FROM amenidades a
   WHERE a.amenity IN ('school', 'college', 'university')
),
cerca AS (                 -- por establecimiento, ruta y sentido: el paradero cercano con más pasadas
  SELECT e.id, spr.route_id, spr.direction_id, max(spr.pasadas_punta_am) AS pasadas
    FROM esc e
    JOIN paraderos_gtfs p          ON p.modo = 'bus' AND ST_DWithin(p.geom, e.geom, 400)
    JOIN servicio_paradero_ruta spr ON spr.stop_id = p.stop_id
   GROUP BY e.id, spr.route_id, spr.direction_id
),
oferta AS (
  SELECT id, sum(pasadas) AS pasadas_2h, count(DISTINCT route_id) AS rutas
    FROM cerca GROUP BY id
)
SELECT e.id, e.amenity, e.nombre, e.origen,
       coalesce(o.rutas, 0)                          AS rutas_400m,
       round(coalesce(o.pasadas_2h, 0) / 2.0, 1)     AS buses_hora_punta,
       round(pc.dist::numeric)                       AS paradero_mas_cercano_m,
       cz.nombre                                     AS comuna,
       e.geom
  FROM esc e
  LEFT JOIN oferta o ON o.id = e.id
  CROSS JOIN LATERAL (SELECT p.geom <-> e.geom AS dist FROM paraderos_gtfs p
                       WHERE p.modo = 'bus' ORDER BY p.geom <-> e.geom LIMIT 1) pc
  LEFT JOIN LATERAL (SELECT s.nombre FROM comunas_zona_sub s
                      WHERE ST_Intersects(s.geom, e.geom) LIMIT 1) cz ON true;

ALTER TABLE resultados.q7 ADD COLUMN categoria text;
UPDATE resultados.q7 SET categoria = CASE
    WHEN buses_hora_punta = 0   THEN '1. sin buses a 400 m'
    WHEN buses_hora_punta < 30  THEN '2. menos de 30 buses/h'
    WHEN buses_hora_punta < 100 THEN '3. 30 a 100 buses/h'
    ELSE                             '4. 100 o más buses/h' END;

\echo ''
\echo '--- Distribución ---'
SELECT categoria, count(*) AS establecimientos,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
  FROM resultados.q7 GROUP BY categoria ORDER BY categoria;

SELECT percentile_cont(ARRAY[0.1, 0.25, 0.5, 0.75, 0.9]) WITHIN GROUP (ORDER BY buses_hora_punta) AS percentiles_10_25_50_75_90
  FROM resultados.q7;

\echo ''
\echo '--- Por comuna ---'
SELECT comuna, count(*) AS establecimientos,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY buses_hora_punta) AS mediana_buses_hora,
       count(*) FILTER (WHERE buses_hora_punta < 30) AS con_menos_de_30_buses_h,
       round(100.0 * count(*) FILTER (WHERE buses_hora_punta < 30) / count(*), 1) AS pct_menos_de_30
  FROM resultados.q7
 WHERE comuna IS NOT NULL
 GROUP BY comuna
 ORDER BY mediana_buses_hora, comuna;

\echo ''
\echo '--- Los 15 establecimientos peor servidos (con nombre) ---'
SELECT left(nombre, 45) AS establecimiento, amenity, comuna, rutas_400m, buses_hora_punta, paradero_mas_cercano_m
  FROM resultados.q7
 WHERE nombre IS NOT NULL
 ORDER BY buses_hora_punta, paradero_mas_cercano_m DESC
 LIMIT 15;
