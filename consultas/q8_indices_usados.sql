-- =====================================================================
-- Índices que se usaron (y los que no) durante las 7 preguntas.
-- consultas.sh hace pg_stat_reset() antes de correr P1..P7, así que
-- idx_scan cuenta SÓLO los usos de las consultas (no los de la carga).
-- "Índices que no se usan son un hallazgo, no un error."
-- =====================================================================
\echo '=== Uso de índices durante P1-P7 (pg_stat_user_indexes) ==='

SELECT s.schemaname || '.' || s.relname          AS tabla,
       s.indexrelname                              AS indice,
       am.amname                                   AS tipo,
       s.idx_scan                                  AS veces_usado,
       s.idx_tup_read                              AS tuplas_leidas,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS tamano,
       CASE WHEN s.idx_scan = 0 THEN '<- NO SE USÓ' ELSE '' END AS nota
  FROM pg_stat_user_indexes s
  JOIN pg_class c ON c.oid = s.indexrelid
  JOIN pg_am am   ON am.oid = c.relam
 WHERE (s.schemaname IN ('public', 'resultados')
        AND s.relname NOT IN ('etl_log', 'metadatos_fuentes', 'spatial_ref_sys', 'parametros')
        AND s.relname NOT ILIKE 'comunas_cl%')          -- tabla fuente del Lab 03, no es nuestra
    OR (s.schemaname = 'crudo' AND s.relname = 'gtfs_stop_times')
 ORDER BY s.idx_scan = 0 DESC, s.relname, s.indexrelname;
