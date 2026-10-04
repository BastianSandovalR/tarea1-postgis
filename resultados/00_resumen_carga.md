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
