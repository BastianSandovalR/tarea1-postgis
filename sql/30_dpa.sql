-- =====================================================================
-- 30 · DPA 2023: comunas_cl (Lab 03) -> comunas_zona y comunas_zona_sub
--
-- comunas_cl.sql se carga tal cual viene del Lab 03 (lo hace cargar.sh).
-- Como el nombre exacto de la tabla y de sus columnas depende de cómo se
-- generó ese dump, aquí se DETECTAN: la tabla con geometría cuyo nombre
-- contiene "comuna", la columna de nombre y la de código. Lo detectado
-- queda en etl_log.
-- =====================================================================
DROP TABLE IF EXISTS comunas_zona CASCADE;
DROP TABLE IF EXISTS comunas_zona_sub CASCADE;

DO $$
DECLARE
  v_esq   text; v_tab text; v_geom text; v_srid int;
  v_nom   text; v_cod text; v_x float8;
BEGIN
  -- 1) tabla fuente
  SELECT f_table_schema, f_table_name, f_geometry_column, srid
    INTO v_esq, v_tab, v_geom, v_srid
    FROM geometry_columns
   WHERE f_table_name ILIKE '%comuna%'
     AND f_table_name NOT IN ('comunas_zona', 'comunas_zona_sub')
     AND f_table_schema NOT IN ('resultados')
   ORDER BY (f_table_name = 'comunas_cl') DESC, f_table_name
   LIMIT 1;
  IF v_tab IS NULL THEN
    RAISE EXCEPTION 'No encontré la tabla de comunas. ¿Se cargó datos/comunas_cl.sql?';
  END IF;

  -- 2) columna con el nombre de la comuna
  SELECT column_name INTO v_nom
    FROM information_schema.columns
   WHERE table_schema = v_esq AND table_name = v_tab
     AND lower(column_name) IN ('comuna', 'nom_comuna', 'nom_com', 'nombre_comuna', 'nombre', 'name')
   ORDER BY array_position(ARRAY['comuna','nom_comuna','nom_com','nombre_comuna','nombre','name'], lower(column_name))
   LIMIT 1;

  -- 3) columna con el código (CUT)
  SELECT column_name INTO v_cod
    FROM information_schema.columns
   WHERE table_schema = v_esq AND table_name = v_tab
     AND lower(column_name) IN ('cut_com', 'cut', 'cod_comuna', 'codigo_comuna', 'cod_com', 'cut_comuna')
   ORDER BY array_position(ARRAY['cut_com','cut','cod_comuna','codigo_comuna','cod_com','cut_comuna'], lower(column_name))
   LIMIT 1;

  IF v_nom IS NULL THEN
    RAISE EXCEPTION 'La tabla %.% no tiene una columna de nombre reconocible', v_esq, v_tab;
  END IF;

  -- 4) SRID: si la columna no lo declara (0), se mira la geometría; y si
  --    tampoco, se infiere por la magnitud de las coordenadas.
  IF v_srid IS NULL OR v_srid = 0 THEN
    EXECUTE format('SELECT ST_SRID(%I) FROM %I.%I WHERE %I IS NOT NULL LIMIT 1', v_geom, v_esq, v_tab, v_geom) INTO v_srid;
  END IF;
  IF v_srid IS NULL OR v_srid = 0 THEN
    EXECUTE format('SELECT ST_XMin(%I) FROM %I.%I WHERE %I IS NOT NULL LIMIT 1', v_geom, v_esq, v_tab, v_geom) INTO v_x;
    v_srid := CASE WHEN abs(v_x) <= 180 THEN 4326 ELSE 5361 END;
    INSERT INTO etl_log(paso, detalle) VALUES ('dpa_detectado', 'SRID no declarado; se asume ' || v_srid);
  END IF;

  INSERT INTO etl_log(paso, detalle) VALUES
    ('dpa_detectado', format('tabla %I.%I, geom %I, SRID %s, nombre %I, código %s',
                             v_esq, v_tab, v_geom, v_srid, v_nom, coalesce(quote_ident(v_cod), '(sin código)')));

  -- 5) Validez de la fuente (se cuenta antes de reparar).
  EXECUTE format($q$
    INSERT INTO etl_log(paso, detalle, filas)
    SELECT 'dpa_invalidas', 'comunas inválidas en la fuente', count(*)
      FROM %I.%I WHERE NOT ST_IsValid(%I)$q$, v_esq, v_tab, v_geom);

  -- 6) comunas_zona: comunas que tocan la caja, en 5361, RECORTADAS a la caja.
  --    area_km2 = área dentro de la caja (para densidades coherentes con los
  --    paraderos, que también están recortados); area_total_km2 = comuna completa.
  EXECUTE format($q$
    CREATE TABLE comunas_zona AS
    WITH c AS (
      SELECT %s::text AS cut,
             %I::text AS nombre,
             ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Transform(ST_SetSRID(%I, %s), 5361)), 3)) AS g
        FROM %I.%I
    )
    SELECT cut, nombre,
           ST_Area(g) / 1e6                                   AS area_total_km2,
           ST_CoveredBy(g, caja())                            AS completa,
           ST_Multi(ST_CollectionExtract(ST_Intersection(g, caja()), 3))::geometry(MultiPolygon, 5361) AS geom
      FROM c
     WHERE ST_Intersects(g, caja())
       AND ST_Area(ST_Intersection(g, caja())) > 10000     -- descarta roces de borde (< 1 ha)
  $q$, coalesce(quote_ident(v_cod), 'NULL'), v_nom, v_geom, v_srid, v_esq, v_tab);
END $$;

ALTER TABLE comunas_zona ADD COLUMN id serial PRIMARY KEY;
ALTER TABLE comunas_zona ADD COLUMN area_km2 float8;
UPDATE comunas_zona SET area_km2 = ST_Area(geom) / 1e6;

-- ST_Subdivide: parte cada comuna en piezas de <= 128 vértices. Cada pieza
-- tiene un bbox chico, así el índice GIST descarta mucho más y cada
-- ST_Intersects / ST_Intersection trabaja con polígonos pequeños (ver P4).
CREATE TABLE comunas_zona_sub AS
SELECT id AS comuna_id, cut, nombre,
       ST_Subdivide(geom, 128)::geometry(Polygon, 5361) AS geom
  FROM comunas_zona;
ALTER TABLE comunas_zona_sub ADD COLUMN sub_id serial PRIMARY KEY;

INSERT INTO etl_log(paso, detalle, filas)
SELECT 'dpa_tabla', 'comunas_zona (comunas que tocan la caja)', count(*) FROM comunas_zona UNION ALL
SELECT 'dpa_tabla', 'comunas_zona completas dentro de la caja', count(*) FROM comunas_zona WHERE completa UNION ALL
SELECT 'dpa_tabla', 'comunas_zona_sub (piezas ST_Subdivide 128)', count(*) FROM comunas_zona_sub UNION ALL
SELECT 'dpa_vertices', 'vértices promedio por comuna', avg(ST_NPoints(geom))::bigint FROM comunas_zona UNION ALL
SELECT 'dpa_vertices', 'vértices promedio por pieza subdividida', avg(ST_NPoints(geom))::bigint FROM comunas_zona_sub;
