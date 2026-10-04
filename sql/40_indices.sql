-- =====================================================================
-- 40 · Índices. (El ANALYZE lo hace cargar.sh con VACUUM ANALYZE al final,
--      fuera de transacción, para que además quede el visibility map listo.)
--
-- Regla: toda tabla derivada con geometría lleva su GIST. Además algunos
-- B-tree para los filtros por atributo. Cuáles se usan de verdad se mide
-- en consultas.sh con pg_stat_user_indexes (resultados/q8_indices.txt).
-- =====================================================================

-- OSM
CREATE INDEX IF NOT EXISTS calles_geom_gist          ON calles           USING gist (geom);
CREATE INDEX IF NOT EXISTS edificios_geom_gist       ON edificios        USING gist (geom);
CREATE INDEX IF NOT EXISTS edificios_punto_gist      ON edificios        USING gist (punto);
CREATE INDEX IF NOT EXISTS paraderos_osm_geom_gist   ON paraderos_osm    USING gist (geom);
CREATE INDEX IF NOT EXISTS amenidades_geom_gist      ON amenidades       USING gist (geom);
CREATE INDEX IF NOT EXISTS amenidades_amenity_idx    ON amenidades       (amenity);

-- GTFS
CREATE INDEX IF NOT EXISTS paraderos_gtfs_geom_gist  ON paraderos_gtfs   USING gist (geom);
CREATE INDEX IF NOT EXISTS paraderos_gtfs_modo_idx   ON paraderos_gtfs   (modo);
CREATE INDEX IF NOT EXISTS recorridos_geom_gist      ON recorridos       USING gist (geom);
CREATE INDEX IF NOT EXISTS recorridos_route_idx      ON recorridos       (route_id);
CREATE INDEX IF NOT EXISTS gtfs_viajes_route_idx     ON gtfs_viajes      (route_id);
CREATE INDEX IF NOT EXISTS gtfs_viajes_shape_idx     ON gtfs_viajes      (shape_id);
CREATE INDEX IF NOT EXISTS stop_times_trip_idx       ON crudo.gtfs_stop_times (trip_id);

-- DPA
CREATE INDEX IF NOT EXISTS comunas_zona_geom_gist     ON comunas_zona     USING gist (geom);
CREATE INDEX IF NOT EXISTS comunas_zona_sub_geom_gist ON comunas_zona_sub USING gist (geom);
