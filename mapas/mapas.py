"""
Mapas del informe (Tarea 1). Lee las tablas de resultados/ en PostGIS y
dibuja PNG en /salidas/mapas. Lo corre consultas.sh:

    docker compose --profile mapas run --rm mapas python /app/mapas.py

Convenciones de todos los mapas:
  * título + subtítulo con la pregunta, escala de color con su unidad,
    barra de escala en metros y la fuente/fecha de los datos al pie
    (sacada de la tabla metadatos_fuentes, así nunca queda desactualizada);
  * magnitudes con UNA sola gama de color (claro = poco, oscuro = mucho);
    diferencias con dos gamas y gris al centro.
"""
import os
import warnings

import geopandas as gpd
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.colors import BoundaryNorm, TwoSlopeNorm
from matplotlib.lines import Line2D
from matplotlib_scalebar.scalebar import ScaleBar
from sqlalchemy import create_engine, text

warnings.filterwarnings("ignore", category=UserWarning)

OUT = "/salidas/mapas"
os.makedirs(OUT, exist_ok=True)

ENGINE = create_engine(
    "postgresql+psycopg2://{u}:{p}@{h}:{port}/{d}".format(
        u=os.environ.get("PGUSER", "postgres"),
        p=os.environ.get("PGPASSWORD", "postgres"),
        h=os.environ.get("PGHOST", "db"),
        port=os.environ.get("PGPORT", "5432"),
        d=os.environ.get("PGDATABASE", "tarea1"),
    )
)

INK = "#1f2328"
MUTED = "#6e7781"
EDGE = "#8c959f"
plt.rcParams.update({
    "font.family": "DejaVu Sans",
    "font.size": 9,
    "text.color": INK,
    "axes.titleweight": "bold",
})


def gdf(sql):
    return gpd.read_postgis(text(sql), ENGINE, geom_col="geom")


def fuentes():
    with ENGINE.connect() as c:
        filas = {r.fuente: r for r in c.execute(text("SELECT * FROM metadatos_fuentes"))}
    partes = []
    if "OSM" in filas:
        partes.append(f"OSM © colaboradores de OpenStreetMap, ODbL ({filas['OSM'].archivo}, datos al {filas['OSM'].fecha_datos[:10]})")
    if "GTFS" in filas:
        partes.append(f"GTFS DTPM {filas['GTFS'].archivo} ({filas['GTFS'].version}, {filas['GTFS'].fecha_datos})")
    partes.append("DPA 2023 INE")
    return "Fuentes: " + " · ".join(partes) + ".  SRID 5361."


PIE = fuentes()
COMUNAS = gdf("SELECT nombre, geom FROM comunas_zona")
CAJA = gdf("SELECT caja() AS geom")


def lienzo(titulo, subtitulo, figsize=(9, 7.2)):
    fig, ax = plt.subplots(figsize=figsize)
    preparar(ax)
    # Título y subtítulo anclados al mapa en puntos (no en fracciones de la
    # figura): no se montan aunque el mapa sea bajo y ancho.
    ax.annotate(titulo, xy=(0, 1), xycoords="axes fraction", xytext=(0, 30), textcoords="offset points",
                ha="left", va="bottom", fontsize=13, fontweight="bold")
    ax.annotate(subtitulo, xy=(0, 1), xycoords="axes fraction", xytext=(0, 12), textcoords="offset points",
                ha="left", va="bottom", fontsize=9.5, color=MUTED)
    return fig, ax


def preparar(ax):
    ax.set_axis_off()
    ax.set_aspect("equal")
    minx, miny, maxx, maxy = CAJA.total_bounds
    ax.set_xlim(minx - 300, maxx + 300)
    ax.set_ylim(miny - 300, maxy + 300)


def contexto(ax, etiquetas=True, sobre=True):
    """Límites comunales encima (o debajo) de los datos, y nombres."""
    COMUNAS.boundary.plot(ax=ax, color="white" if sobre else EDGE, linewidth=1.2 if sobre else 0.6,
                          zorder=4 if sobre else 1)
    COMUNAS.boundary.plot(ax=ax, color=EDGE, linewidth=0.5, zorder=5 if sobre else 1)
    CAJA.boundary.plot(ax=ax, color=MUTED, linewidth=0.8, linestyle="--", zorder=6)
    if etiquetas:
        for _, r in COMUNAS.iterrows():
            p = r.geom.representative_point()
            ax.annotate(r.nombre, (p.x, p.y), ha="center", va="center", fontsize=6.3, color=INK,
                        zorder=7, bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none", alpha=0.6))
    ax.add_artist(ScaleBar(1, units="m", location="lower left", box_alpha=0.7, font_properties={"size": 8}))
    ax.annotate("N", xy=(0.97, 0.10), xytext=(0.97, 0.03), xycoords="axes fraction",
                ha="center", fontsize=9, fontweight="bold",
                arrowprops=dict(arrowstyle="-|>", color=INK, lw=1.2))


def cerrar(fig, nombre, nota=None):
    pie = PIE if nota is None else nota + "\n" + PIE
    fig.text(0.03, 0.015, pie, ha="left", va="bottom", fontsize=6.8, color=MUTED, wrap=True)
    ruta = os.path.join(OUT, nombre)
    fig.savefig(ruta, dpi=200, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print("  ->", ruta)


def barra(fig, ax, mappable, etiqueta):
    cb = fig.colorbar(mappable, ax=ax, shrink=0.6, pad=0.01, aspect=25)
    cb.set_label(etiqueta, color=INK)
    cb.outline.set_visible(False)
    return cb


# ---------------------------------------------------------------------
# P1 · densidad de paraderos por comuna
# ---------------------------------------------------------------------
def mapa_p1():
    d = gdf("SELECT comuna, paraderos, paraderos_km2, geom FROM resultados.q1")
    fig, ax = lienzo("P1 · Densidad de paraderos de bus por comuna",
                     "Paraderos GTFS (modo bus) por km² de comuna dentro de la caja santiago-centro")
    d.plot(ax=ax, column="paraderos_km2", cmap="Blues", edgecolor="none", zorder=2)
    contexto(ax, etiquetas=False)
    for _, r in d.iterrows():
        p = r.geom.representative_point()
        ax.annotate(f"{r.comuna}\n{r.paraderos_km2:.0f}/km²", (p.x, p.y), ha="center", va="center",
                    fontsize=6, color=INK, zorder=7,
                    bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none", alpha=0.65))
    barra(fig, ax, ax.collections[0], "paraderos / km²")
    cerrar(fig, "p1_densidad_paraderos.png",
           "Comunas cortadas por la caja: el área y los paraderos se cuentan sólo dentro de la caja.")


# ---------------------------------------------------------------------
# P2 · cobertura 500 m, GTFS vs OSM (misma escala en ambos paneles)
# ---------------------------------------------------------------------
def mapa_p2():
    d = gdf("SELECT comuna, pct_lejos_gtfs, pct_lejos_osm, dif_pp_osm_menos_gtfs, geom FROM resultados.q2")
    vmax = max(d.pct_lejos_gtfs.max(), d.pct_lejos_osm.max(), 1)
    fig, axs = plt.subplots(1, 3, figsize=(15, 5.6), layout="constrained")
    fig.get_layout_engine().set(rect=(0, 0.05, 1, 0.88))
    fig.suptitle("P2 · Edificios a más de 500 m de un paradero, según la fuente", x=0.02, y=1.0,
                 ha="left", fontsize=13, fontweight="bold")
    fig.text(0.02, 0.945, "% de edificios OSM (punto interior) de cada comuna sin paradero a ≤ 500 m",
             ha="left", fontsize=9.5, color=MUTED)
    for ax, col, tit in [(axs[0], "pct_lejos_gtfs", "Con paraderos GTFS (bus)"),
                         (axs[1], "pct_lejos_osm", "Con bus_stop de OSM")]:
        preparar(ax)
        d.plot(ax=ax, column=col, cmap="Oranges", vmin=0, vmax=vmax, edgecolor="none", zorder=2)
        contexto(ax, etiquetas=False)
        ax.set_title(tit, loc="left", fontsize=10)
    cb = fig.colorbar(axs[1].collections[0], ax=[axs[0], axs[1]], shrink=0.7, aspect=30, location="bottom")
    cb.set_label("% de edificios a > 500 m (misma escala en ambos mapas)")
    cb.outline.set_visible(False)
    ax = axs[2]
    preparar(ax)
    lim = max(abs(d.dif_pp_osm_menos_gtfs.min()), abs(d.dif_pp_osm_menos_gtfs.max()), 1)
    d.plot(ax=ax, column="dif_pp_osm_menos_gtfs", cmap="RdBu_r",
           norm=TwoSlopeNorm(vcenter=0, vmin=-lim, vmax=lim), edgecolor="none", zorder=2)
    contexto(ax, etiquetas=False)
    ax.set_title("Diferencia OSM − GTFS", loc="left", fontsize=10)
    cb = fig.colorbar(ax.collections[0], ax=ax, shrink=0.7, aspect=30, location="bottom")
    cb.set_label("puntos porcentuales (rojo: OSM ve peor cobertura; azul: mejor)")
    cb.outline.set_visible(False)
    cerrar(fig, "p2_cobertura_gtfs_vs_osm.png")


# ---------------------------------------------------------------------
# P3 · paraderos sin pareja en la otra fuente
# ---------------------------------------------------------------------
def mapa_p3():
    g = gdf("SELECT geom FROM resultados.q3_gtfs_sin_osm")
    o = gdf("SELECT geom FROM resultados.q3_osm_sin_gtfs")
    todos = gdf("SELECT geom FROM paraderos_gtfs WHERE modo = 'bus'")
    fig, ax = lienzo("P3 · Paraderos sin pareja en la otra fuente (radio 50 m)",
                     f"{len(g):,} paraderos GTFS sin bus_stop OSM · {len(o):,} bus_stop OSM sin paradero GTFS".replace(",", "."))
    contexto(ax, etiquetas=True, sobre=False)
    todos.plot(ax=ax, color="#d0d7de", markersize=1.5, zorder=2)
    g.plot(ax=ax, color="#0969da", marker="o", markersize=5, zorder=3)
    o.plot(ax=ax, color="#cf222e", marker="^", markersize=7, zorder=3)
    ax.legend(handles=[
        Line2D([], [], ls="", marker="o", color="#d0d7de", label="paradero GTFS con pareja"),
        Line2D([], [], ls="", marker="o", color="#0969da", label="GTFS sin bus_stop OSM a < 50 m"),
        Line2D([], [], ls="", marker="^", color="#cf222e", label="bus_stop OSM sin paradero GTFS a < 50 m"),
    ], loc="upper left", bbox_to_anchor=(1.0, 1.0), frameon=False, fontsize=8)
    cerrar(fig, "p3_paraderos_sin_pareja.png")


# ---------------------------------------------------------------------
# P5 · ruta elegida y salud más cercana
# ---------------------------------------------------------------------
def mapa_p5():
    p = gdf("SELECT stop_id, distancia_m, geom FROM resultados.q5")
    if p.empty:
        print("  (P5 sin filas: se omite el mapa)")
        return
    l = gdf("SELECT geom_linea AS geom FROM resultados.q5")
    s = gdf("SELECT DISTINCT ON (geom_salud) amenity, geom_salud AS geom FROM resultados.q5")
    with ENGINE.connect() as c:
        ruta = c.execute(text("""SELECT r.route_short_name FROM resultados.q5 q
                                 JOIN crudo.gtfs_stop_times st ON st.stop_id = q.stop_id
                                 JOIN gtfs_viajes v ON v.trip_id = st.trip_id
                                 JOIN gtfs_rutas r ON r.route_id = v.route_id
                                 GROUP BY 1 ORDER BY count(*) DESC LIMIT 1""")).scalar()
    rec = gdf(f"SELECT geom FROM recorridos WHERE route_short_name = '{ruta}' AND es_principal")
    minx, miny, maxx, maxy = p.total_bounds
    pad = 1200
    ancho, alto = (maxx - minx) + 2 * pad, (maxy - miny) + 2 * pad
    fig, ax = lienzo(f"P5 · Salud más cercana a cada paradero del recorrido {ruta}",
                     "Farmacia, hospital, clínica o consulta (OSM) más cercana a cada paradero; KNN con <->",
                     figsize=(11, max(4.2, 11 * alto / ancho + 1.6)))
    contexto(ax, etiquetas=True, sobre=False)
    rec.plot(ax=ax, color="#8c959f", linewidth=1.5, zorder=2)
    l.plot(ax=ax, color="#8250df", linewidth=0.6, zorder=3)
    s.plot(ax=ax, color="#8250df", marker="+", markersize=30, zorder=4)
    p.plot(ax=ax, column="distancia_m", cmap="Purples", markersize=16, edgecolor=INK, linewidth=0.3,
           zorder=5, vmin=0)
    ax.set_xlim(minx - pad, maxx + pad)
    ax.set_ylim(miny - pad, maxy + pad)
    cb = fig.colorbar(ax.collections[-1], ax=ax, location="bottom", shrink=0.5, aspect=35, pad=0.02)
    cb.set_label("distancia del paradero al lugar de salud más cercano (m)")
    cb.outline.set_visible(False)
    ax.legend(handles=[
        Line2D([], [], color="#8c959f", lw=1.5, label=f"recorrido {ruta} (shape principal)"),
        Line2D([], [], color="#8250df", lw=0.8, marker="+", markersize=8, label="lugar de salud más cercano"),
    ], loc="upper right", frameon=True, framealpha=0.9, fontsize=8)
    cerrar(fig, "p5_ruta_salud_mas_cercana.png")


# ---------------------------------------------------------------------
# P6 · grilla hexagonal (MAPA PRINCIPAL) + paneles de apoyo
# ---------------------------------------------------------------------
def mapa_p6():
    h = gdf("SELECT edificios, recorridos, indice, geom FROM resultados.grilla_hex")
    t = gdf("SELECT rank, comuna, edificios, recorridos, geom FROM resultados.q6_top10")

    fig, ax = lienzo("P6 · Dónde hay muchos edificios y pocos recorridos",
                     "Grilla hexagonal (lado 500 m). Color: edificios / (recorridos distintos + 1). "
                     "Contorno: las 10 celdas con índice más alto (≥ 50 edificios)")
    # Clases por cuantiles: un par de celdas extremas no deben dejar todo el mapa del mismo color.
    cortes = sorted(set(np.round(np.quantile(h.indice, [0, .2, .4, .6, .8, .9, .97, 1]), 1)))
    norm = BoundaryNorm(cortes, plt.get_cmap("YlOrRd").N)
    h.plot(ax=ax, column="indice", cmap="YlOrRd", norm=norm, edgecolor="white", linewidth=0.2, zorder=2)
    cb = barra(fig, ax, ax.collections[0], "edificios por recorrido  [edificios / (recorridos + 1)]")
    cb.set_ticks(cortes)
    cb.ax.text(0.5, -0.04, "clases por cuantiles", transform=cb.ax.transAxes, ha="center", va="top",
               fontsize=7, color=MUTED)
    contexto(ax, etiquetas=True, sobre=True)
    t.boundary.plot(ax=ax, color="#0550ae", linewidth=2.2, zorder=8)
    for _, r in t.iterrows():
        c = r.geom.centroid
        ax.annotate(str(r["rank"]), (c.x, c.y), ha="center", va="center", fontsize=8, fontweight="bold",
                    color="white", zorder=9,
                    bbox=dict(boxstyle="circle,pad=0.2", fc="#0550ae", ec="none"))
    cerrar(fig, "p6_grilla_hexagonal_principal.png",
           "Recorridos distintos = count(DISTINCT route_id) de todos los shapes GTFS que cruzan la celda.")

    fig, axs = plt.subplots(1, 2, figsize=(14, 6.3), layout="constrained")
    fig.get_layout_engine().set(rect=(0, 0.05, 1, 0.9))
    fig.suptitle("P6 · Grilla hexagonal de 500 m: las dos variables por separado", x=0.02, y=1.0,
                 ha="left", fontsize=13, fontweight="bold")
    for ax, col, cmap, lab in [(axs[0], "edificios", "Greys", "edificios OSM por celda"),
                               (axs[1], "recorridos", "Blues", "recorridos GTFS distintos por celda")]:
        preparar(ax)
        h.plot(ax=ax, column=col, cmap=cmap, edgecolor="white", linewidth=0.2, zorder=2)
        contexto(ax, etiquetas=False)
        t.boundary.plot(ax=ax, color="#cf222e", linewidth=1.4, zorder=8)
        barra(fig, ax, ax.collections[0], lab)
    cerrar(fig, "p6_grilla_edificios_y_recorridos.png", "Contorno rojo: top 10 de la pregunta 6.")


# ---------------------------------------------------------------------
# P7 · establecimientos educacionales y buses en punta AM
# ---------------------------------------------------------------------
def mapa_p7():
    d = gdf("SELECT categoria, buses_hora_punta, geom FROM resultados.q7")
    orden = sorted(d.categoria.unique())
    # categorías ordinales -> pasos de UNA gama (rojo oscuro = peor servido)
    colores = ["#67000d", "#ef3b2c", "#fcbba1", "#d9d9d9"]
    fig, ax = lienzo("P7 · Buses en la punta de la mañana cerca de colegios y universidades",
                     "Buses por hora (07:00–09:00, martes) que pasan a ≤ 400 m de cada establecimiento OSM")
    contexto(ax, etiquetas=True, sobre=False)
    hs = []
    for cat, col in zip(orden, colores):
        sub = d[d.categoria == cat]
        sub.plot(ax=ax, color=col, markersize=10 if cat.startswith(("1", "2")) else 6,
                 edgecolor=INK if cat.startswith(("1", "2")) else "none", linewidth=0.3,
                 zorder=3 if cat.startswith(("1", "2")) else 2)
        hs.append(Line2D([], [], ls="", marker="o", color=col, markeredgecolor=INK, markeredgewidth=0.3,
                         label=f"{cat[3:]} ({len(sub)})"))
    ax.legend(handles=hs, loc="upper left", bbox_to_anchor=(1.0, 1.0), fontsize=8, frameon=False,
              title="buses por hora a ≤ 400 m\n(n.º de establecimientos)", title_fontsize=8, alignment="left")
    cerrar(fig, "p7_colegios_buses_punta.png",
           "Horarios reconstruidos desde frequencies.txt (los buses DTPM se publican por frecuencia).")


if __name__ == "__main__":
    for f in (mapa_p1, mapa_p2, mapa_p3, mapa_p5, mapa_p6, mapa_p7):
        f()
