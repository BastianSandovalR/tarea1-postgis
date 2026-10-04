-- =====================================================================
-- P4. Kilómetros de recorrido por comuna, recortando cada trazado en el
--     límite comunal con ST_Intersection.   Patrón: líneas contra polígonos.
--     Se compara el tiempo con y sin ST_Subdivide.
--
-- Decisiones:
--  * Sólo recorridos principales (es_principal: el shape con más salidas por
--    ruta y sentido). Así una ruta con 4 variantes no suma 4 veces la misma
--    calle; ida y vuelta sí se suman (son servicio en ambos sentidos).
--  * Comunas recortadas a la caja: son km dentro de la zona de estudio.
--  * Con piezas subdivididas se suma por comuna_id: las piezas no se
--    traslapan, así que la suma de los tramos es el largo dentro de la comuna.
-- =====================================================================
\echo '=== P4. Km de recorrido por comuna (ST_Intersection) ==='

-- ---------------------------------------------------------------------
-- A) SIN subdividir: cada línea contra el polígono completo de la comuna.
-- ---------------------------------------------------------------------
\echo ''
\echo '--- A) Plan contra comunas_zona (polígonos completos) ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT c.id, sum(ST_Length(ST_Intersection(r.geom, c.geom))) / 1000 AS km
  FROM recorridos r
  JOIN comunas_zona c ON ST_Intersects(r.geom, c.geom)
 WHERE r.es_principal
 GROUP BY c.id;

-- ---------------------------------------------------------------------
-- B) CON ST_Subdivide: cada línea contra piezas de <= 128 vértices.
-- ---------------------------------------------------------------------
\echo ''
\echo '--- B) Plan contra comunas_zona_sub (ST_Subdivide 128) ---'
DROP TABLE IF EXISTS resultados.q4;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
CREATE TABLE resultados.q4 AS
WITH km AS (
  SELECT s.comuna_id,
         sum(ST_Length(ST_Intersection(r.geom, s.geom))) / 1000 AS km,
         count(DISTINCT r.route_id)                             AS rutas
    FROM recorridos r
    JOIN comunas_zona_sub s ON ST_Intersects(r.geom, s.geom)
   WHERE r.es_principal
   GROUP BY s.comuna_id
)
SELECT c.id, c.nombre AS comuna, c.completa,
       round(c.area_km2::numeric, 2)                  AS area_km2,
       round(coalesce(k.km, 0)::numeric, 1)           AS km_recorrido,
       coalesce(k.rutas, 0)                           AS rutas,
       round((coalesce(k.km, 0) / c.area_km2)::numeric, 1) AS km_por_km2,
       c.geom
  FROM comunas_zona c
  LEFT JOIN km k ON k.comuna_id = c.id;

\echo ''
\echo '--- Resultado (ordenado por km de recorrido) ---'
SELECT comuna, area_km2, km_recorrido, rutas, km_por_km2
  FROM resultados.q4
 ORDER BY km_recorrido DESC;

-- ---------------------------------------------------------------------
-- C) Efecto de ST_Subdivide en el tiempo: 3 corridas de cada versión
--    (se reporta la mejor, para no medir el caché frío) y chequeo de que
--    ambas dan el mismo total.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS resultados.q4_tiempos;
CREATE TABLE resultados.q4_tiempos (version text, corrida int, ms numeric, km_total numeric);

DO $$
DECLARE t0 timestamptz; k numeric; i int;
BEGIN
  FOR i IN 1..3 LOOP
    t0 := clock_timestamp();
    SELECT sum(ST_Length(ST_Intersection(r.geom, c.geom))) / 1000 INTO k
      FROM recorridos r JOIN comunas_zona c ON ST_Intersects(r.geom, c.geom)
     WHERE r.es_principal;
    INSERT INTO resultados.q4_tiempos VALUES
      ('A: comunas completas', i, round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1), round(k, 2));

    t0 := clock_timestamp();
    SELECT sum(ST_Length(ST_Intersection(r.geom, s.geom))) / 1000 INTO k
      FROM recorridos r JOIN comunas_zona_sub s ON ST_Intersects(r.geom, s.geom)
     WHERE r.es_principal;
    INSERT INTO resultados.q4_tiempos VALUES
      ('B: ST_Subdivide(geom, 128)', i, round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1), round(k, 2));
  END LOOP;
END $$;

\echo ''
\echo '--- Tiempo con y sin ST_Subdivide (mejor de 3 corridas) ---'
SELECT version, min(ms) AS mejor_ms, max(km_total) AS km_total,
       (SELECT count(*) FROM comunas_zona)     AS poligonos_comunas,
       (SELECT count(*) FROM comunas_zona_sub) AS piezas_subdivididas
  FROM resultados.q4_tiempos
 GROUP BY version
 ORDER BY version;
