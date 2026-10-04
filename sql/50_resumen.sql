-- =====================================================================
-- 50 · Resumen de la carga en Markdown (lo guarda cargar.sh en
--      resultados/00_resumen_carga.md y se copia al README).
-- =====================================================================
CREATE OR REPLACE FUNCTION conteo(t regclass) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN EXECUTE format('SELECT count(*) FROM %s', t) INTO n; RETURN n; END $$;

\echo '### Fuentes'
\echo ''
\echo '| Fuente | Archivo | Versión | Fecha de los datos |'
\echo '|---|---|---|---|'
SELECT format('| %s | `%s` | %s | %s |', fuente, archivo, version, fecha_datos)
  FROM metadatos_fuentes ORDER BY fuente;

\echo ''
\echo '### Tablas derivadas (SRID 5361)'
\echo ''
\echo '| Tabla | Filas | Geometría | Índices | Tamaño |'
\echo '|---|---:|---|---|---:|'
WITH t(nombre, orden) AS (VALUES
  ('calles',1),('edificios',2),('paraderos_osm',3),('amenidades',4),
  ('paraderos_gtfs',5),('recorridos',6),('servicio_paradero',7),('servicio_paradero_ruta',7),('gtfs_rutas',8),('gtfs_viajes',9),
  ('comunas_zona',10),('comunas_zona_sub',11))
SELECT format('| `%s` | %s | %s | %s | %s |',
       t.nombre,
       to_char(conteo(t.nombre::regclass), 'FM999G999G999'),
       coalesce((SELECT string_agg(format('%s(%s)', type, f_geometry_column), ', ')
                   FROM geometry_columns g WHERE g.f_table_schema = 'public' AND g.f_table_name = t.nombre), '—'),
       coalesce((SELECT string_agg(indexname, ', ' ORDER BY indexname)
                   FROM pg_indexes i WHERE i.schemaname = 'public' AND i.tablename = t.nombre), '—'),
       pg_size_pretty(pg_total_relation_size(t.nombre::regclass)))
  FROM t ORDER BY orden;

\echo ''
\echo '### Bitácora del ETL (etl_log)'
\echo ''
\echo '| Paso | Detalle | Filas |'
\echo '|---|---|---:|'
SELECT format('| %s | %s | %s |', paso, replace(detalle, '|', '/'), coalesce(to_char(filas, 'FM999G999G999'), ''))
  FROM etl_log ORDER BY id;
