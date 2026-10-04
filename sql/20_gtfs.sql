-- =====================================================================
-- 20 · GTFS: CSV crudos (crudo.gtfs_*) -> tablas con geometría en 5361
--   gtfs_rutas, gtfs_viajes, paraderos_gtfs, recorridos, servicio_paradero
-- =====================================================================

-- ---------------------------------------------------------------------
-- 20.1 Rutas y viajes con tipos.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS gtfs_rutas CASCADE;
CREATE TABLE gtfs_rutas AS
SELECT route_id,
       agency_id,
       route_short_name,
       route_long_name,
       route_type::int AS route_type,
       CASE route_type::int
         WHEN 3 THEN 'bus' WHEN 1 THEN 'metro' WHEN 2 THEN 'tren'
         WHEN 0 THEN 'tren liviano' ELSE 'otro' END AS modo
  FROM crudo.gtfs_routes;
ALTER TABLE gtfs_rutas ADD PRIMARY KEY (route_id);

DROP TABLE IF EXISTS gtfs_viajes CASCADE;
CREATE TABLE gtfs_viajes AS
SELECT trip_id, route_id, service_id,
       nullif(direction_id, '')::int AS direction_id,
       nullif(shape_id, '')          AS shape_id
  FROM crudo.gtfs_trips;
ALTER TABLE gtfs_viajes ADD PRIMARY KEY (trip_id);
-- Estadísticas YA: sin ellas el planner estima 0 filas en tablas recién creadas
-- y elige nested loops que no terminan (nos pasó: 10+ minutos vs 4 s).
ANALYZE gtfs_rutas;
ANALYZE gtfs_viajes;

-- Día hábil de referencia = un MARTES: servicios con tuesday = 1 en calendar.txt
-- (en el feed DTPM: L = lunes a viernes, LJ = lunes a jueves). Si el ZIP no
-- trae calendar.txt se usan todos los servicios. calendar_dates (feriados) no
-- afecta a un martes normal y se ignora a propósito.
DROP TABLE IF EXISTS servicios_habiles;
CREATE TEMP TABLE servicios_habiles AS
SELECT DISTINCT service_id FROM gtfs_viajes
 WHERE to_regclass('crudo.gtfs_calendar') IS NULL;
DO $$
BEGIN
  IF to_regclass('crudo.gtfs_calendar') IS NOT NULL THEN
    INSERT INTO servicios_habiles SELECT service_id FROM crudo.gtfs_calendar WHERE tuesday = '1';
  END IF;
END $$;

INSERT INTO etl_log(paso, detalle, filas)
SELECT 'gtfs_servicio', 'servicios de día hábil (martes): ' || string_agg(service_id, ', ' ORDER BY service_id), count(*)
  FROM servicios_habiles;

-- ---------------------------------------------------------------------
-- 20.2 stop_times tipado (tabla temporal).
-- El feed DTPM define los buses por FRECUENCIA (frequencies.txt): cada trip
-- de bus es una plantilla que parte a las 0:00:00 y el horario real sale de
-- start_time/end_time/headway_secs. Por eso se guarda el desfase (off) de
-- cada parada respecto del inicio del viaje, no sólo la hora absoluta.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS st;
CREATE TEMP TABLE st AS
WITH t AS (
  SELECT trip_id, stop_id, stop_sequence::int AS seq,
         extract(epoch FROM coalesce(nullif(arrival_time, ''), nullif(departure_time, ''))::interval)::int AS t
    FROM crudo.gtfs_stop_times
)
SELECT trip_id, stop_id, seq, t,
       t - min(t) OVER (PARTITION BY trip_id) AS off
  FROM t
 WHERE t IS NOT NULL;
CREATE INDEX ON st (trip_id);
ANALYZE st;

-- Frecuencias (vacía si el feed no trae frequencies.txt).
DROP TABLE IF EXISTS fr;
CREATE TEMP TABLE fr (trip_id text, s int, e int, h int);
DO $$
BEGIN
  IF to_regclass('crudo.gtfs_frequencies') IS NOT NULL THEN
    INSERT INTO fr
    SELECT trip_id,
           extract(epoch FROM start_time::interval)::int,
           extract(epoch FROM end_time::interval)::int,
           headway_secs::int
      FROM crudo.gtfs_frequencies
     WHERE headway_secs::int > 0;
  END IF;
END $$;
CREATE INDEX ON fr (trip_id);
ANALYZE fr;

-- Salidas reales de cada viaje en su día de servicio:
--   viaje con frecuencia -> ceil((end - start) / headway) por cada tramo
--   viaje sin frecuencia (metro, tren) -> 1
DROP TABLE IF EXISTS salidas_viaje;
CREATE TEMP TABLE salidas_viaje AS
SELECT v.trip_id,
       coalesce((SELECT sum(ceil((f.e - f.s)::numeric / f.h))::int FROM fr f WHERE f.trip_id = v.trip_id), 1) AS salidas
  FROM gtfs_viajes v;
CREATE INDEX ON salidas_viaje (trip_id);
ANALYZE salidas_viaje;

-- ---------------------------------------------------------------------
-- 20.3 paraderos_gtfs: stops.txt -> Point 4326 -> 5361, sólo los de la caja.
-- Se quedan las paradas/andenes (location_type vacío o 0). Se descartan
-- estaciones (1), accesos (2), nodos genéricos (3) y zonas de abordaje (4)
-- de Metro, que no son "paraderos". modo dice qué servicios pasan por él
-- (según stop_times), para comparar bus con bus contra OSM.
-- ---------------------------------------------------------------------
-- Primero qué modos atienden cada parada (tabla temporal con estadísticas).
-- Ojo: escrito como CTE dentro del CREATE, el planner estimaba 1 fila para
-- el filtro ST_Intersects y re-ejecutaba la agregación de 1,1 M de
-- stop_times por cada parada (nested loop): no terminaba. Materializado aquí
-- con ANALYZE, el join es un hash join de segundos.
DROP TABLE IF EXISTS servicio_stop;
CREATE TEMP TABLE servicio_stop AS
SELECT st.stop_id,
       bool_or(r.route_type = 3)        AS bus,
       bool_or(r.route_type = 1)        AS metro,
       bool_or(r.route_type IN (0, 2))  AS tren,
       count(DISTINCT r.route_id)       AS n_rutas
  FROM st
  JOIN gtfs_viajes v USING (trip_id)
  JOIN gtfs_rutas  r USING (route_id)
 GROUP BY st.stop_id;
ALTER TABLE servicio_stop ADD PRIMARY KEY (stop_id);
ANALYZE servicio_stop;

DROP TABLE IF EXISTS paraderos_gtfs CASCADE;
CREATE TABLE paraderos_gtfs AS
WITH s AS (
  SELECT stop_id, nullif(stop_code, '') AS stop_code, stop_name,
         ST_SetSRID(ST_MakePoint(stop_lon::float8, stop_lat::float8), 4326) AS g4326
    FROM crudo.gtfs_stops
   WHERE coalesce(nullif(location_type, ''), '0') = '0'
)
SELECT s.stop_id,
       s.stop_code,
       s.stop_name AS nombre,
       CASE WHEN sv.bus THEN 'bus' WHEN sv.metro THEN 'metro'
            WHEN sv.tren THEN 'tren' ELSE 'sin_servicio' END AS modo,
       coalesce(sv.n_rutas, 0) AS n_rutas,
       ST_Transform(s.g4326, 5361)::geometry(Point, 5361) AS geom
  FROM s
  LEFT JOIN servicio_stop sv USING (stop_id)
 WHERE ST_Intersects(s.g4326, caja_4326());          -- el recorte a la caja se hace aquí, en la base
ALTER TABLE paraderos_gtfs ADD PRIMARY KEY (stop_id);
ANALYZE paraderos_gtfs;

INSERT INTO etl_log(paso, detalle, filas)
SELECT 'gtfs_paraderos', 'stops.txt con location_type 0/vacío (todo el feed)', count(*)
  FROM crudo.gtfs_stops WHERE coalesce(nullif(location_type, ''), '0') = '0'
UNION ALL
SELECT 'gtfs_paraderos', 'paraderos_gtfs en la caja, modo = ' || modo, count(*)
  FROM paraderos_gtfs GROUP BY modo;

-- ---------------------------------------------------------------------
-- 20.4 recorridos: UNA LineString por shape_id.
-- shape_pt_sequence viene como texto: se ordena como ENTERO (como texto,
-- '10' < '9' y la línea saldría con saltos).
-- Asociación shape -> ruta vía trips.txt. En el feed DTPM cada shape
-- pertenece a una sola ruta; si alguno tuviera varias se deja la ruta
-- con más salidas (DISTINCT ON) y se registra en etl_log.
-- ---------------------------------------------------------------------
INSERT INTO etl_log(paso, detalle, filas)
SELECT 'gtfs_shapes', 'shape_id con shape_pt_sequence repetida', count(*)
  FROM (SELECT shape_id FROM crudo.gtfs_shapes
         GROUP BY shape_id, shape_pt_sequence HAVING count(*) > 1) x;

INSERT INTO etl_log(paso, detalle, filas)
SELECT 'gtfs_shapes', 'shape_id asociados a más de una ruta', count(*)
  FROM (SELECT shape_id FROM gtfs_viajes WHERE shape_id IS NOT NULL
         GROUP BY shape_id HAVING count(DISTINCT route_id) > 1) x;

-- Líneas y asociación en tablas temporales con ANALYZE (mismo motivo que
-- servicio_stop: evitar que el planner re-ejecute agregaciones en un nested loop).
DROP TABLE IF EXISTS lineas;
CREATE TEMP TABLE lineas AS
SELECT shape_id,
       count(*) AS n_puntos,
       ST_MakeLine(
         ST_SetSRID(ST_MakePoint(shape_pt_lon::float8, shape_pt_lat::float8), 4326)
         ORDER BY shape_pt_sequence::int
       ) AS g4326
  FROM crudo.gtfs_shapes
 GROUP BY shape_id
HAVING count(*) >= 2;                       -- una línea necesita al menos 2 vértices
ANALYZE lineas;

DROP TABLE IF EXISTS asociacion;
CREATE TEMP TABLE asociacion AS
WITH x AS (
  SELECT v.shape_id, v.route_id,
         min(v.direction_id) AS direction_id,
         coalesce(sum(sv.salidas) FILTER (WHERE v.service_id IN (SELECT service_id FROM servicios_habiles)), 0) AS salidas_habil,
         sum(sv.salidas) AS salidas_total
    FROM gtfs_viajes v
    JOIN salidas_viaje sv USING (trip_id)
   WHERE v.shape_id IS NOT NULL
   GROUP BY v.shape_id, v.route_id
)
SELECT DISTINCT ON (shape_id) shape_id, route_id, direction_id, salidas_habil
  FROM x
 ORDER BY shape_id, salidas_habil DESC, salidas_total DESC;
ALTER TABLE asociacion ADD PRIMARY KEY (shape_id);
ANALYZE asociacion;

DROP TABLE IF EXISTS recorridos CASCADE;
CREATE TABLE recorridos AS
SELECT l.shape_id,
       a.route_id,
       r.route_short_name,
       r.modo,
       a.direction_id,
       l.n_puntos,
       a.salidas_habil::int                             AS salidas_habil,
       false                                            AS es_principal,
       ST_Transform(l.g4326, 5361)::geometry(LineString, 5361) AS geom
  FROM lineas l
  JOIN asociacion a USING (shape_id)
  JOIN gtfs_rutas r USING (route_id)
 WHERE ST_Intersects(l.g4326, caja_4326());          -- se guarda la línea completa si toca la caja
ALTER TABLE recorridos ADD PRIMARY KEY (shape_id);
ALTER TABLE recorridos ADD COLUMN largo_km float8;
UPDATE recorridos SET largo_km = ST_Length(geom) / 1000;
ANALYZE recorridos;

-- Varios shapes por ruta (ida/vuelta y variantes):
--   * se conservan TODOS (una fila por shape, como pide el enunciado);
--   * es_principal = el shape con más salidas en día hábil para cada
--     (ruta, sentido). Los km por comuna (P4) usan sólo los principales
--     para no sumar dos veces el mismo trazado por sus variantes; ida y
--     vuelta sí se suman porque son servicio distinto.
--   * "recorridos distintos" (P6) se cuenta con DISTINCT route_id.
UPDATE recorridos r SET es_principal = true
  FROM (SELECT DISTINCT ON (route_id, direction_id) shape_id
          FROM recorridos
         ORDER BY route_id, direction_id, salidas_habil DESC, n_puntos DESC, shape_id) p
 WHERE r.shape_id = p.shape_id;

INSERT INTO etl_log(paso, detalle, filas)
SELECT 'gtfs_recorridos', 'shape_id distintos en shapes.txt', count(DISTINCT shape_id) FROM crudo.gtfs_shapes UNION ALL
SELECT 'gtfs_recorridos', 'recorridos que tocan la caja', count(*) FROM recorridos UNION ALL
SELECT 'gtfs_recorridos', 'recorridos principales (1 por ruta y sentido)', count(*) FROM recorridos WHERE es_principal UNION ALL
SELECT 'gtfs_recorridos', 'rutas distintas en la caja', count(DISTINCT route_id) FROM recorridos UNION ALL
SELECT 'gtfs_recorridos', 'recorridos no válidos (ST_IsValid = false)', count(*) FROM recorridos WHERE NOT ST_IsValid(geom) UNION ALL
SELECT 'gtfs_recorridos', 'recorridos que se auto-intersectan (ST_IsSimple = false; normal en circuitos)', count(*) FROM recorridos WHERE NOT ST_IsSimple(geom);

-- ---------------------------------------------------------------------
-- 20.5 servicio_paradero: cuántos buses pasan por cada paradero en un día
-- hábil y en la punta mañana (07:00-09:00), expandiendo frequencies.txt.
--   Para un tramo (s, e, h) las salidas son s + k·h, k = 0..n-1, n = ceil((e-s)/h).
--   El bus k pasa por la parada en s + k·h + off. Las pasadas en [A, B) son
--   los k entre ceil((A-s-off)/h) y ceil((B-s-off)/h)-1, acotados a [0, n-1].
-- (Se usa en la pregunta propia, P7.)
-- ---------------------------------------------------------------------
-- Detalle por paradero, ruta y sentido (P7 lo necesita para no contar dos
-- veces el mismo bus en dos paraderos vecinos).
DROP TABLE IF EXISTS servicio_paradero_ruta CASCADE;
CREATE TABLE servicio_paradero_ruta AS
WITH vh AS (
  SELECT v.trip_id, v.route_id, v.direction_id, r.route_type
    FROM gtfs_viajes v JOIN gtfs_rutas r USING (route_id)
   WHERE v.service_id IN (SELECT service_id FROM servicios_habiles)
), pasadas AS (
  SELECT st.stop_id, vh.route_id, vh.direction_id, vh.route_type,
         ceil((f.e - f.s)::numeric / f.h)::int AS n_dia,
         greatest(0,
             least(ceil((f.e - f.s)::numeric / f.h)::int - 1,
                   ceil((32400 - f.s - st.off)::numeric / f.h)::int - 1)      -- 32400 s = 09:00
           - greatest(0, ceil((25200 - f.s - st.off)::numeric / f.h)::int)    -- 25200 s = 07:00
           + 1) AS n_punta
    FROM st JOIN vh USING (trip_id) JOIN fr f USING (trip_id)
  UNION ALL
  SELECT st.stop_id, vh.route_id, vh.direction_id, vh.route_type,
         1,
         (st.t >= 25200 AND st.t < 32400)::int
    FROM st JOIN vh USING (trip_id)
   WHERE NOT EXISTS (SELECT 1 FROM fr WHERE fr.trip_id = st.trip_id)
)
SELECT stop_id, route_id, direction_id, route_type,
       sum(n_dia)::int   AS pasadas_dia,
       sum(n_punta)::int AS pasadas_punta_am
  FROM pasadas
 GROUP BY stop_id, route_id, direction_id, route_type;
ALTER TABLE servicio_paradero_ruta ADD PRIMARY KEY (stop_id, route_id, direction_id);

DROP TABLE IF EXISTS servicio_paradero CASCADE;
CREATE TABLE servicio_paradero AS
SELECT stop_id,
       sum(pasadas_dia)::int                                        AS pasadas_dia,
       sum(pasadas_punta_am)::int                                   AS pasadas_punta_am,
       coalesce(sum(pasadas_punta_am) FILTER (WHERE route_type = 3), 0)::int AS pasadas_bus_punta_am,
       count(DISTINCT route_id)::int                                AS n_rutas
  FROM servicio_paradero_ruta
 GROUP BY stop_id;
ALTER TABLE servicio_paradero ADD PRIMARY KEY (stop_id);

INSERT INTO etl_log(paso, detalle, filas)
SELECT 'gtfs_servicio', 'paraderos con servicio en día hábil', count(*) FROM servicio_paradero UNION ALL
SELECT 'gtfs_servicio', 'pasadas totales en punta AM (07-09, todos los modos)', sum(pasadas_punta_am) FROM servicio_paradero;
