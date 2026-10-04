# Tarea 1 — PostGIS de punta a punta: Santiago centro

**Procesamiento Masivo de Datos · ELE051-B / EIN102B · USM 2026-2 · Paralelo 701**
Integrantes: Bastian Sandoval

Pregunta que ordena el trabajo: **¿cómo se relaciona la ciudad construida (OSM) con la red de
transporte público (GTFS)?** Tres fuentes (OpenStreetMap, GTFS de la DTPM y la DPA 2023) se cargan a
un esquema propio en PostGIS, todo en **SRID 5361**, y se responden 7 preguntas con planes de
ejecución comentados y mapas.

---

## 1. Reproducir desde cero

Requisitos del host: **Docker Engine con el plugin `compose`** y `bash`. Nada más (ni Python, ni GDAL,
ni psql: todo corre en contenedores). Disco: ~6 GB libres.

```bash
git clone <este repo> && cd tarea1-postgis
# 1) dejar los 3 archivos fuente en ./datos (sección 2)
docker compose up -d      # construye la imagen (PostgreSQL 17 + PostGIS 3 + GDAL + osmium) y levanta la base
./cargar.sh               # ETL completo: tablas, reparaciones, índices y VACUUM ANALYZE
./consultas.sh            # 7 preguntas + planes + GeoPackage + mapas
```

- `cargar.sh` levanta la base por su cuenta si no está arriba, y es **idempotente**: correrlo de nuevo
  rehace todo desde cero (sólo `comunas_cl` no se recarga si ya está, porque el dump pesa 218 MB).
- La base queda en el puerto **5433** del host (`psql -h localhost -p 5433 -U postgres tarea1`,
  clave `postgres`) para no chocar con la del Lab 05. Se cambia con `PG_PORT=5432 docker compose up -d`.
- Caja más chica si la máquina va justa: `BBOX="-70.70,-33.48,-70.58,-33.40" ./cargar.sh` (anotarlo aquí).
- Otro recorrido para P5: `RUTA=210 ./consultas.sh` (por defecto `506`).
- **Fedora / SELinux:** los montajes llevan `:z`, no hay que hacer nada. Si usa `moby-engine`,
  instale también `docker-compose-plugin` y agregue su usuario al grupo `docker`.

Tiempo en la máquina de prueba: carga ≈ 2 min (124 s), consultas + GeoPackage + mapas ≈ 2 min (109 s, incluida la construcción de la imagen de mapas)
(quedan en `resultados/00_log_carga.txt` y en la tabla `etl_log`).

## 2. Datos (no versionados: ver `.gitignore`)

Dejar en `./datos/` **con estos nombres**:

| Archivo | De dónde | Descargado el | Versión / fecha de los datos |
|---|---|---|---|
| `chile-latest.osm.pbf` | https://download.geofabrik.de/south-america/chile-latest.osm.pbf | 03-10-2026 | la escribe `cargar.sh` desde el encabezado del PBF (ver §5) |
| `GTFS_AAAAMMDD.zip` (nombre original) | https://www.dtpm.cl/index.php/noticias/gtfs-vigente | 03-10-2026 | `feed_info.txt` (ver §5) |
| `comunas_cl.sql` | Lab 03, `03/datos/comunas_cl.sql` (DPA 2023, INE) | — | DPA 2023 |

- En vez del `.pbf` se puede dejar `osm_santiago-centro.gpkg`, generado con el script del Lab 05
  (`python3 preparar_datos.py --zona santiago-centro`); `cargar.sh` lo detecta (si están los dos, usa
  el `.pbf`). Con el `.pbf` el recorte lo hace `osmium` dentro del contenedor y la fecha de los datos se
  lee de su encabezado; el GPKG no guarda esa fecha, así que va en **`fuentes.env`** (versionado), de
  donde la toman la §5 y el pie de los mapas.
- **OSM usado en esta entrega:** extracto de Chile de Geofabrik (`chile-latest.osm.pbf`, descargado
  el 03-10-2026 con su nombre fechado `chile-261002.osm.pbf`, 333 MB, ODbL), datos al
  **2026-10-02 20:21 UTC** (`osmosis_replication_timestamp` del encabezado). `cargar.sh` toma
  cualquier `*.osm.pbf` que haya en `datos/` y lo recorta a la caja santiago-centro con `osmium`.
- **El GTFS cambió.** El enunciado menciona `GTFS_20260829.zip` (vigente al 08-09). Al 30-09-2026 la
  DTPM publica `GTFS_20261003.zip` (`feed_version V168.20261003`, vigencia 03-10 a 31-12-2026).
  Usamos el que estaba vigente al descargar, como pide el enunciado, y lo dejamos anotado.

## 3. Estructura

```
fuentes.env               fecha/origen de OSM cuando la fuente es el GPKG (lo lee cargar.sh)
docker-compose.yml        PostGIS (volumen con nombre pgdata) + servicio "mapas" (perfil aparte)
docker/Dockerfile         postgres:17-bookworm + postgis 3 + gdal-bin + osmium-tool + unzip
docker/osmconf.ini        osmconf de GDAL con amenity/shop/... como columnas en la capa points
cargar.sh                 ETL completo (host) -> llama a scripts/ y sql/ dentro del contenedor
scripts/osm_a_crudo.sh    osmium extract (caja) + ogr2ogr -> crudo.points/lines/multipolygons (5361)
scripts/gtfs_a_crudo.sh   unzip + COPY de cada .txt -> crudo.gtfs_* (columnas leídas del encabezado)
scripts/exportar_gpkg.sh  resultados -> salidas/tarea1_resultados.gpkg
sql/00_esquema.sql        extensiones, esquemas, caja, bitácora etl_log, metadatos_fuentes
sql/10_osm.sql            reparación de geometrías + calles, edificios, paraderos_osm, amenidades
sql/20_gtfs.sql           paraderos_gtfs, recorridos, servicio_paradero(_ruta)
sql/30_dpa.sql            comunas_zona (recortadas a la caja) + comunas_zona_sub (ST_Subdivide)
sql/40_indices.sql        índices GIST y B-tree
sql/50_resumen.sql        conteos -> resultados/00_resumen_carga.md y §5 de este README
consultas/q1..q7_*.sql    las 7 preguntas;  q8_indices_usados.sql: pg_stat_user_indexes
consultas.sh              corre q1..q8, exporta GeoPackage y dibuja mapas
mapas/mapas.py            mapas PNG (geopandas + matplotlib), imagen propia en mapas/Dockerfile
resultados/               salida de cada consulta: SQL + resultado + EXPLAIN ANALYZE (se versiona)
salidas/                  tarea1_resultados.gpkg (QGIS) y mapas/*.png (se versionan)
informe/                  informe (PDF entregado por Aula)
```

## 4. Decisiones del pipeline

**SRID 5361 (SIRGAS-Chile / UTM 19S) en todo.** `ogr2ogr -t_srs EPSG:5361` reproyecta OSM al cargar;
GTFS se construye en 4326 y se transforma; la DPA se transforma al derivar. En 5361 las unidades son
metros: `ST_DWithin(a, b, 500)` son 500 m reales y usa el índice GIST (en 4326 habría que usar
`geography`, sin el mismo índice). La deformación de UTM en Santiago es del orden de 0,04 %.

**La caja** (lon −70,75…−70,52 · lat −33,52…−33,36) vive en la tabla `parametros` y en dos funciones:
`caja_4326()` y `caja()` (5361). Antes de proyectarla se densifica con `ST_Segmentize` para que sus
bordes sigan meridianos y paralelos. OSM se recorta con `osmium extract -b` y luego en SQL; el GTFS
se recorta **en la base** (`ST_Intersects(punto, caja_4326())`).

**Carga OSM.** `osmium` recorta el PBF de Chile a la caja (estrategia `smart`: los polígonos que cruzan
el borde quedan completos) y `ogr2ogr` carga `points`, `lines` y `multipolygons` al esquema `crudo`
con `PG_USE_COPY`. Se usa un `osmconf.ini` propio porque el de GDAL deja `amenity` de los nodos dentro
de `other_tags`. `other_tags` se convierte a `hstore` con una función que no se cae ante filas mal formadas.

**Reparaciones (`ST_MakeValid`).** Se cuentan las geometrías inválidas por motivo
(`ST_IsValidReason`) **antes** de reparar, y se reparan con
`ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))`: un polígono "corbatín" reparado devuelve
polígonos más alguna línea suelta, y sólo se conserva la parte poligonal. Lo que queda vacío se
descarta y también se cuenta. Cuántas fueron: ver `osm_invalidas` / `osm_reparadas` en §5.

**Punto interior vs polígono.** `edificios` guarda **ambos**: `geom` (MultiPolygon, para áreas) y
`punto = ST_PointOnSurface(geom)`. Contar y asignar (a comuna, a celda, distancia a paradero) se hace
con el punto: cada edificio cae en una sola comuna/celda y la distancia se mide desde el edificio y
no desde su borde (con el polígono, un edificio grande quedaría "cerca" por su esquina). Se usa
`ST_PointOnSurface` y no `ST_Centroid` porque el centroide de un edificio en L o con patio puede
caer fuera de él. Las `amenidades` mapeadas como polígono (casi todos los hospitales) se
incluyen con su punto interior: si sólo se usaran nodos se perderían.

**GTFS.** Los CSV se cargan con `COPY` a tablas `UNLOGGED` en `crudo` (texto; las columnas se leen del
encabezado, así un cambio de orden no rompe la carga). `stop_times.txt` trae ~1,1 M filas y entra en
segundos. Luego:
- `paraderos_gtfs`: paradas con `location_type` vacío o 0 (se descartan estaciones, accesos y nodos
  internos de Metro). Columna `modo` (`bus`/`metro`/`tren`) según qué rutas pasan por ella. Las
  preguntas usan `modo = 'bus'` para comparar lo mismo que `highway=bus_stop`.
- `recorridos`: **una LineString por `shape_id`**, `ST_MakeLine(punto ORDER BY shape_pt_sequence::int)`.
  El `::int` importa: ordenado como texto, `'10' < '9'`. Se asocia a su ruta vía `trips.txt`
  (`route_id`, `route_short_name`); en este feed cada shape pertenece a una sola ruta (verificado
  en `etl_log`). Se guarda la línea completa si toca la caja.
- **Varios shapes por ruta** (ida/vuelta y variantes): se conservan todos. `es_principal` marca, por
  ruta y sentido, el shape con más salidas en día hábil. P4 (km) usa sólo los principales para no sumar
  la misma calle 3 veces por sus variantes (ida y vuelta sí se suman: es servicio en ambos sentidos).
  P6 cuenta `DISTINCT route_id`, así que variantes e ida/vuelta cuentan como un recorrido.
- **Frecuencias.** La DTPM publica los buses por frecuencia: cada viaje de `stop_times` es una plantilla
  que parte a las 0:00:00, y los horarios reales salen de `frequencies.txt` (inicio, fin, headway). Para
  saber cuántos buses pasan por un paradero hay que expandir esas frecuencias; `servicio_paradero_ruta`
  lo hace en forma cerrada (sin generar cada salida) para un martes (`calendar.txt`, `tuesday = 1`) y
  para la punta 07:00–09:00. Se verificó contra un cálculo fuerza bruta en Python para varios paraderos.

**DPA.** El dump del Lab 03 se carga tal cual. `sql/30_dpa.sql` detecta la tabla (nombre con "comuna"),
la columna de nombre, la de código CUT y el SRID (lo detectado queda en `etl_log`). `comunas_zona` son
las comunas que tocan la caja **recortadas a la caja**: así el área y los paraderos/edificios/km se miden
sobre la misma superficie (Las Condes o La Florida no quedan con densidades artificialmente bajas
por tener la mitad fuera). `completa = false` marca las que la caja corta. `comunas_zona_sub` =
`ST_Subdivide(geom, 128)`: piezas de ≤ 128 vértices con bbox chico, que el GIST filtra mucho mejor.

**Índices.** GIST en toda geometría derivada (incluido `edificios.punto`), B-tree en claves y filtros
(`recorridos.route_id`, `amenidades.amenity`, `paraderos_gtfs.modo`, `crudo.gtfs_stop_times.trip_id`…).
Al final `VACUUM (ANALYZE)`. Cuáles se usaron: `resultados/q8_indices_usados.txt` (se hace
`pg_stat_reset()` antes de las consultas, así que cuenta sólo P1–P7).

## 5. Tablas, conteos e índices

Esta sección la reescribe `cargar.sh` en cada corrida (entre los marcadores).

<!-- CONTEOS:INICIO -->
### Fuentes

| Fuente | Archivo | Versión | Fecha de los datos |
|---|---|---|---|
| DPA | `comunas_cl.sql` | División Política Administrativa 2023 (INE), dump del Lab 03 | 2023 |
| GTFS | `GTFS_20261003.zip` | feed_version V168.20261003 | vigencia 20261003 a 20261231 |
| OSM | `chile-261002.osm.pbf` | Geofabrik chile-latest (333M; recorte 17M) | 2026-10-02T20:21:34Z |

### Tablas derivadas (SRID 5361)

| Tabla | Filas | Geometría | Índices | Tamaño |
|---|---:|---|---|---:|
| `calles` | 101,118 | LINESTRING(geom) | calles_geom_gist, calles_pkey | 26 MB |
| `edificios` | 118,821 | MULTIPOLYGON(geom), POINT(punto) | edificios_geom_gist, edificios_pkey, edificios_punto_gist | 42 MB |
| `paraderos_osm` | 6,568 | POINT(geom) | paraderos_osm_geom_gist, paraderos_osm_pkey | 1224 kB |
| `amenidades` | 20,841 | POINT(geom) | amenidades_amenity_idx, amenidades_geom_gist, amenidades_pkey | 3736 kB |
| `paraderos_gtfs` | 6,812 | POINT(geom) | paraderos_gtfs_geom_gist, paraderos_gtfs_modo_idx, paraderos_gtfs_pkey | 1376 kB |
| `recorridos` | 708 | LINESTRING(geom) | recorridos_geom_gist, recorridos_pkey, recorridos_route_idx | 12 MB |
| `servicio_paradero` | 12,465 | — | servicio_paradero_pkey | 976 kB |
| `servicio_paradero_ruta` | 40,686 | — | servicio_paradero_ruta_pkey | 3712 kB |
| `gtfs_rutas` | 428 | — | gtfs_rutas_pkey | 112 kB |
| `gtfs_viajes` | 26,159 | — | gtfs_viajes_pkey, gtfs_viajes_route_idx, gtfs_viajes_shape_idx | 3048 kB |
| `comunas_zona` | 30 | MULTIPOLYGON(geom) | comunas_zona_geom_gist, comunas_zona_pkey | 288 kB |
| `comunas_zona_sub` | 67 | POLYGON(geom) | comunas_zona_sub_geom_gist, comunas_zona_sub_pkey | 176 kB |

### Bitácora del ETL (etl_log)

| Paso | Detalle | Filas |
|---|---|---:|
| osm_crudo | crudo.points | 256,357 |
| osm_crudo | crudo.lines | 170,238 |
| osm_crudo | crudo.multipolygons | 146,755 |
| osm_invalidas | multipolygons: Ring Self-intersection | 1 |
| osm_invalidas | multipolygons: Self-intersection | 14 |
| osm_reparadas | multipolygons reparadas con ST_MakeValid | 15 |
| osm_reparadas | lines reparadas con ST_MakeValid | 0 |
| osm_descartadas | multipolygons vacías tras ST_MakeValid | 0 |
| osm_tabla | calles | 101,118 |
| osm_tabla | edificios | 118,821 |
| osm_tabla | paraderos_osm | 6,568 |
| osm_tabla | amenidades | 20,841 |
| tiempo | OSM (segundos) | 93 |
| gtfs_copy | stops.txt -> crudo.gtfs_stops | 18,455 |
| gtfs_copy | routes.txt -> crudo.gtfs_routes | 428 |
| gtfs_copy | trips.txt -> crudo.gtfs_trips | 26,159 |
| gtfs_copy | shapes.txt -> crudo.gtfs_shapes | 456,573 |
| gtfs_copy | stop_times.txt -> crudo.gtfs_stop_times | 1,098,529 |
| gtfs_copy | calendar.txt -> crudo.gtfs_calendar | 6 |
| gtfs_copy | calendar_dates.txt -> crudo.gtfs_calendar_dates | 12 |
| gtfs_copy | frequencies.txt -> crudo.gtfs_frequencies | 14,542 |
| gtfs_copy | feed_info.txt -> crudo.gtfs_feed_info | 1 |
| gtfs_copy | agency.txt -> crudo.gtfs_agency | 4 |
| gtfs_servicio | servicios de día hábil (martes): L, LJ | 2 |
| gtfs_paraderos | stops.txt con location_type 0/vacío (todo el feed) | 12,466 |
| gtfs_paraderos | paraderos_gtfs en la caja, modo = tren | 8 |
| gtfs_paraderos | paraderos_gtfs en la caja, modo = bus | 6,569 |
| gtfs_paraderos | paraderos_gtfs en la caja, modo = sin_servicio | 1 |
| gtfs_paraderos | paraderos_gtfs en la caja, modo = metro | 234 |
| gtfs_shapes | shape_id con shape_pt_sequence repetida | 0 |
| gtfs_shapes | shape_id asociados a más de una ruta | 0 |
| gtfs_recorridos | shape_id distintos en shapes.txt | 981 |
| gtfs_recorridos | recorridos que tocan la caja | 708 |
| gtfs_recorridos | recorridos principales (1 por ruta y sentido) | 604 |
| gtfs_recorridos | rutas distintas en la caja | 347 |
| gtfs_recorridos | recorridos no válidos (ST_IsValid = false) | 0 |
| gtfs_recorridos | recorridos que se auto-intersectan (ST_IsSimple = false; normal en circuitos) | 257 |
| gtfs_servicio | paraderos con servicio en día hábil | 12,465 |
| gtfs_servicio | pasadas totales en punta AM (07-09, todos los modos) | 473,502 |
| tiempo | GTFS (segundos) | 20 |
| dpa_detectado | tabla public.comunas_cl, geom geom, SRID 5361, nombre comuna, código cut_com |  |
| dpa_invalidas | comunas inválidas en la fuente | 0 |
| dpa_tabla | comunas_zona (comunas que tocan la caja) | 30 |
| dpa_tabla | comunas_zona completas dentro de la caja | 13 |
| dpa_tabla | comunas_zona_sub (piezas ST_Subdivide 128) | 67 |
| dpa_vertices | vértices promedio por comuna | 191 |
| dpa_vertices | vértices promedio por pieza subdividida | 88 |
| tiempo | DPA (segundos) | 4 |
| tiempo | Índices y ANALYZE (segundos) | 6 |
| tiempo | TOTAL cargar.sh (segundos) | 124 |
<!-- CONTEOS:FIN -->

## 6. Preguntas (Parte C)

| # | Archivo | Patrón | Plan | Mapa |
|---|---|---|---|---|
| P1 | `consultas/q1_paraderos_por_comuna.sql` | punto en polígono contra `comunas_zona_sub` | sí (+ sin índice) | `p1_densidad_paraderos.png` |
| P2 | `consultas/q2_cobertura_500m.sql` | 2 anti-joins `NOT EXISTS` + `ST_DWithin(…, 500)` | sí (+ estimado sin índice) | `p2_cobertura_gtfs_vs_osm.png` |
| P3 | `consultas/q3_dos_fuentes.sql` | anti-join en ambos sentidos, 50 m (+ sensibilidad 25/100 m) | sí | `p3_paraderos_sin_pareja.png` |
| P4 | `consultas/q4_km_por_comuna.sql` | `ST_Intersection` líneas × polígonos, con y sin `ST_Subdivide` | sí, ambos + tiempos | — |
| P5 | `consultas/q5_vecino_mas_cercano.sql` | `CROSS JOIN LATERAL` + `<->` + `LIMIT 1` | sí (+ sin índice) | `p5_ruta_salud_mas_cercana.png` |
| P6 | `consultas/q6_grilla_hexagonal.sql` | `ST_HexagonGrid(500)` + vista materializada | sí | **`p6_grilla_hexagonal_principal.png`** |
| P7 | `consultas/q7_propia_colegios_punta.sql` | colegios OSM × buses/hora GTFS en punta AM | sí | `p7_colegios_buses_punta.png` |

Resultados, consultas y planes: `resultados/q*.txt`. Capas para QGIS: `salidas/tarea1_resultados.gpkg`.

**P7 (propia): ¿qué tan bien servidos en la punta de la mañana están los establecimientos
educacionales?** Para cada colegio, instituto o universidad de OSM se cuentan los buses por hora que
pasan a ≤ 400 m entre 07:00 y 09:00 de un martes, con horarios reconstruidos desde `frequencies.txt`.
Para no contar dos veces el mismo bus en dos paraderos vecinos, por cada ruta y sentido se toma el
paradero cercano con más pasadas. No es variante de P2: P2 mide si hay un paradero cerca, todo el día;
P7 mide la frecuencia en la hora en que viajan los alumnos, y es la única que usa `stop_times` + `frequencies`.

## 7. Qué no funcionó (y cómo se resolvió)

- **Nested loop que no terminaba.** Creando `paraderos_gtfs` con la agregación de `stop_times` como CTE,
  el planner estimaba 1 fila para `ST_Intersects(punto_calculado, caja)` y re-ejecutaba la
  agregación de 1,1 M de filas por cada paradero: más de 10 minutos sin terminar. Materializar la
  agregación en una tabla temporal con `ANALYZE` lo dejó en ~4 s. Lo mismo se hizo con los shapes, y
  se agregó `ANALYZE` justo después de crear cada tabla (sin estadísticas el planner supone tablas vacías).
- **Imagen `postgis/postgis:16-3.4`.** Está basada en Debian bullseye y `apt-get install gdal-bin`
  fallaba (paquetes de seguridad retirados). Se pasó a `postgres:17-bookworm` + PostGIS desde el
  repositorio PGDG, que ya trae la imagen oficial.
- **Polígonos OSM rotos.** Con el `.pbf` de Geofabrik (el camino usado en esta entrega) aparecieron
  15 multipolígonos inválidos (14 `Self-intersection`, 1 `Ring Self-intersection`), todos reparados con
  `ST_MakeValid`; ninguno quedó vacío. Si la fuente es el GPKG, al recortar con `-spat` GEOS además no
  puede evaluar polígonos con anillos de 2 puntos y `ogr2ogr` los descarta (un `ERROR` por objeto).
  Las dos cosas se cuentan en `etl_log`.
- **`amenity` en los nodos.** Con el `osmconf.ini` por defecto de GDAL no es columna de `points` (queda
  en `other_tags`), y las farmacias salían vacías. Se usa un `osmconf.ini` propio y, si la fuente es el
  GPKG del Lab 05, se completa desde `other_tags`.
- **`stop_times` no son horarios reales para los buses** (plantillas desde 0:00:00; ver §4). Contar
  filas de `stop_times` como "viajes" habría subestimado la oferta de buses en órdenes de magnitud.
- **El GIST de `recorridos` filtra poco.** Una línea de 20 km tiene un bbox enorme, así que en P6 el
  índice devuelve muchos candidatos que después descarta `ST_Intersects` ("Rows Removed by Filter" en
  el plan). Se podría subdividir las líneas (`ST_Subdivide` sobre recorridos) como se hizo con comunas.
- **`ST_Subdivide` no aceleró P4.** Con las comunas ya recortadas a la caja, cada una tiene en promedio
  191 vértices y las 30 comunas quedan en sólo 67 piezas (88 vértices por pieza). `ST_Intersection`
  contra comunas completas tardó 439 ms y contra las piezas 558 ms (mejor de 3; mismo total, 8.444,28 km):
  hay más pares línea–pieza (4.070 contra 2.589) y cada uno paga su propia intersección. Subdividir
  conviene con polígonos de miles de vértices (las comunas sin recortar); aquí no. Las piezas sí
  sirven para el punto-en-polígono de P1, P2 y P7.
- **Función `tags()` y consultas paralelas.** `tags(text)` atrapa errores con un bloque `EXCEPTION`
  (una subtransacción). Declarada `PARALLEL SAFE`, al crear `paraderos_osm` el planner eligió un plan
  paralelo y cada llamada dejaba un `WARNING: AbortSubTransaction while in COMMIT state` y devolvía
  NULL. Con `PARALLEL RESTRICTED` seguía pasando (la función corre en el proceso líder, pero dentro de
  la consulta paralela); quedó `PARALLEL UNSAFE` y el log sale limpio.
- **Índices que no se usaron** (`pg_stat_user_indexes` después de P1–P7, `resultados/q8_indices_usados.txt`):
  `edificios_geom_gist` y `calles_geom_gist` (las preguntas usan el punto interior de los edificios y
  ninguna usa calles), `recorridos_route_idx`, `grilla_hex_gist` y `grilla_hex_ij` (la grilla se lee
  completa), y las claves primarias de `amenidades`, `calles`, `edificios`, `gtfs_viajes`,
  `servicio_paradero` y `comunas_zona_sub`. Los más usados: `paraderos_gtfs_geom_gist` (148.862 veces),
  `paraderos_osm_geom_gist` (145.097) y `comunas_zona_sub_geom_gist` (120.673).

## 8. Licencias de los datos

OpenStreetMap © colaboradores de OpenStreetMap, ODbL. GTFS: Directorio de Transporte Público
Metropolitano (DTPM). DPA 2023: Instituto Nacional de Estadísticas (INE).
