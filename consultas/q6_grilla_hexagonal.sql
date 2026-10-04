-- =====================================================================
-- P6. Grilla hexagonal de 500 m: número de edificios y número de
--     recorridos DISTINTOS que cruzan cada celda. Las 10 celdas con más
--     edificios y menos recorridos.
--     Patrón: ST_HexagonGrid + vista materializada.  (MAPA PRINCIPAL)
--
-- Decisiones:
--  * ST_HexagonGrid(500, caja()): 500 m es el LADO del hexágono (el
--    parámetro size de PostGIS); cada celda mide ~0,65 km².
--  * Edificios por su punto interior: cada edificio cae en UNA celda.
--  * "Recorridos distintos" = count(DISTINCT route_id): las variantes e
--    ida/vuelta de una misma ruta cuentan como 1. Se cuentan todos los
--    shapes (no sólo los principales) porque una variante también da servicio.
--  * Criterio de las 10 celdas: índice = edificios / (recorridos + 1), de
--    mayor a menor, entre celdas con al menos 50 edificios (para no premiar
--    celdas casi vacías del borde). El +1 evita dividir por cero y hace que
--    una celda sin recorridos quede primera sólo si además tiene edificios.
-- =====================================================================
\echo '=== P6. Grilla hexagonal 500 m: edificios vs recorridos ==='

DROP MATERIALIZED VIEW IF EXISTS resultados.grilla_hex CASCADE;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
CREATE MATERIALIZED VIEW resultados.grilla_hex AS
WITH c AS MATERIALIZED (SELECT caja() AS g),   -- la caja se calcula una vez, no por celda
hex AS (
  SELECT h.i, h.j, h.geom
    FROM c, ST_HexagonGrid(500, c.g) AS h
   WHERE ST_Intersects(h.geom, c.g)
)
SELECT hex.i, hex.j,
       e.edificios,
       r.recorridos,
       r.recorridos_bus,
       round(e.edificios::numeric / (r.recorridos + 1), 1) AS indice,
       hex.geom::geometry(Polygon, 5361) AS geom
  FROM hex
  CROSS JOIN LATERAL (SELECT count(*) AS edificios
                        FROM edificios ed
                       WHERE ST_Intersects(ed.punto, hex.geom)) e
  CROSS JOIN LATERAL (SELECT count(DISTINCT rc.route_id) AS recorridos,
                             count(DISTINCT rc.route_id) FILTER (WHERE rc.modo = 'bus') AS recorridos_bus
                        FROM recorridos rc
                       WHERE ST_Intersects(rc.geom, hex.geom)) r;

CREATE UNIQUE INDEX grilla_hex_ij   ON resultados.grilla_hex (i, j);
CREATE INDEX        grilla_hex_gist ON resultados.grilla_hex USING gist (geom);
ANALYZE resultados.grilla_hex;

\echo ''
\echo '--- Resumen de la grilla ---'
SELECT count(*)                                        AS celdas,
       count(*) FILTER (WHERE edificios > 0)           AS celdas_con_edificios,
       count(*) FILTER (WHERE recorridos = 0)          AS celdas_sin_recorridos,
       count(*) FILTER (WHERE edificios >= 50 AND recorridos = 0) AS celdas_50mas_edificios_sin_recorridos,
       round(avg(edificios), 1)                        AS edificios_promedio,
       round(avg(recorridos), 1)                       AS recorridos_promedio,
       round(corr(edificios, recorridos)::numeric, 3)  AS correlacion_edificios_recorridos
  FROM resultados.grilla_hex;

DROP TABLE IF EXISTS resultados.q6_top10;
CREATE TABLE resultados.q6_top10 AS
SELECT row_number() OVER (ORDER BY indice DESC, edificios DESC) AS rank,
       g.i, g.j, g.edificios, g.recorridos, g.recorridos_bus, g.indice,
       (SELECT c.nombre FROM comunas_zona c
         ORDER BY ST_Area(ST_Intersection(c.geom, g.geom)) DESC LIMIT 1) AS comuna,
       g.geom
  FROM resultados.grilla_hex g
 WHERE g.edificios >= 50
 ORDER BY indice DESC, edificios DESC
 LIMIT 10;

\echo ''
\echo '--- Las 10 celdas con más edificios y menos recorridos ---'
SELECT rank, comuna, i, j, edificios, recorridos, recorridos_bus, indice,
       round(ST_X(ST_Transform(ST_Centroid(geom), 4326))::numeric, 5) AS lon,
       round(ST_Y(ST_Transform(ST_Centroid(geom), 4326))::numeric, 5) AS lat
  FROM resultados.q6_top10 ORDER BY rank;
