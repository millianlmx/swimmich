#!/usr/bin/env python3
"""Tournée de revue UI d'ImmichSwiftUI : explore tous les écrans, capture tout.

    python3 .omp/skills/ui-review/scripts/tour.py                 # tout (~4 min)
    python3 .omp/skills/ui-review/scripts/tour.py --mode quick    # l'essentiel (~1 min)
    python3 .omp/skills/ui-review/scripts/tour.py --only viewer   # une section
    python3 .omp/skills/ui-review/scripts/tour.py --out /tmp/revue-2026-11

Produit dans --out (défaut /tmp/ui-review) :
  NN-<nom>.png        une capture par étape (tout est capturé)
  NN-<nom>.tree.json  l'arbre d'accessibilité de l'étape
  index.md            table des captures + alertes automatiques

La tournée suppose l'app installée sur le device AVEC une session valide (le
simulateur du poste porte la session demo.immich.app). Elle ne fait aucun
`erase`/`uninstall` : la session et les réglages survivent. Voir SKILL.md pour
les pièges (toolbar invisible en AX, gestes idb bloquants, vidéos 404 du démo).
"""

from __future__ import annotations

import argparse
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from uidrive import DEFAULT_BUNDLE, DEFAULT_UDID, Driver  # noqa: E402


def section(driver: Driver, name: str, only: set[str]) -> bool:
    return not only or name in only


# --------------------------------------------------------------------- tour
def tour_timeline(d: Driver) -> None:
    d.launch_app()
    d.step("timeline-top", expect_id="timelinePinnedYearHeader", note="accueil timeline")
    d.scroll("down", times=3)
    d.step("timeline-scrolled", note="en-tête épinglé + pastille Sélectionner")
    d.scroll("up", times=3)
    d.step("timeline-back-to-top")


def tour_selection(d: Driver) -> None:
    d.launch_app()
    if not d.tap_found(id="selectButton"):
        d.step("selection-absente", note="selectButton introuvable")
        return
    time.sleep(1.2)
    d.step("selection-mode-vide", note="compteur de sélection attendu ici")
    tiles = d.tiles()
    for el in tiles[:2]:
        d.tap_el(el)
        time.sleep(0.6)
    d.step("selection-2-photos", note="compteur + actions actives")
    d.tap_xy(36, 84)  # ✕ de la barre de sélection (toolbar → hors arbre AX)
    time.sleep(1.2)
    d.step("timeline-apres-selection")


def tour_context_menu(d: Driver) -> None:
    d.launch_app()
    tiles = d.tiles()
    if not tiles:
        return
    d.tap_el(tiles[0], duration_ms=900)
    time.sleep(1.5)
    d.step("vignette-menu-contextuel", note="appui long sur une vignette")
    d.tap_xy(201, 780)  # hors du menu
    time.sleep(1.0)


def tour_viewer(d: Driver) -> None:
    d.launch_app()
    tiles = d.tiles()
    if not tiles:
        d.step("viewer-sans-vignette")
        return
    d.tap_el(tiles[0])
    time.sleep(2.5)
    d.step("viewer-photo", expect_id="viewerBackButton",
           note="capsule lieu/date — vérifier qu'elle n'est pas écrasée")
    d.tap_xy(201, 437)  # tap centre : bascule le chrome
    time.sleep(1.0)
    d.step("viewer-chrome-masque")
    d.tap_xy(201, 437)
    time.sleep(1.0)
    d.tap_found(id="viewerDetailsButton")
    time.sleep(1.6)
    d.step("viewer-panneau-details", note="note, personnes, étiquettes, EXIF")
    el = d.find(label="Fermer les détails") or d.find(contains="détails")
    if el:
        d.tap_el(el)
    time.sleep(1.2)
    d.tap_found(id="viewerShareButton")
    time.sleep(1.6)
    d.step("viewer-feuille-partage")
    el = d.find(id="closeShareSheet")
    if el:
        d.tap_el(el)
    time.sleep(1.2)
    # Le bouton de fermeture de la feuille de partage est un item de toolbar
    # (invisible en AX) : si la feuille est restée ouverte, le « retour » tape
    # dans le vide. On repart donc d'un lancement propre — déterministe.
    d.launch_app()
    d.step("timeline-retour-du-lecteur", expect_id="timelinePinnedYearHeader")


def tour_search(d: Driver) -> None:
    d.launch_app()
    d.search_bubble()
    d.step("recherche-vide", note="état initial + placeholder du champ")
    field = d.find(type="TextField") or d.find(contains="Rechercher des photos")
    if field:
        d.tap_el(field)
        time.sleep(0.8)
        d.type_text("sunset")
        time.sleep(2.5)
        d.step("recherche-resultats", note="peut être « Aucun résultat » : la recherche CLIP du démo est limitée")
    # Quitter le champ focalisé : la barre d'outils reprend sa place de repos,
    # sinon les coordonnées des boutons de barre tombent sur le segmented control
    # (mesuré : le tap « Filtres » a basculé l'écran en mode Explorer).
    cancel = d.find(type="Button", label="Fermer")
    if cancel:
        d.tap_el(cancel)
        time.sleep(1.5)
        d.step("recherche-au-repos")
    d.tap_xy(181, 78)  # bouton Filtres (toolbar → hors arbre AX)
    time.sleep(1.5)
    d.step("recherche-feuille-filtres", expect_id="searchFilterType",
           note="sections Note/Texte OCR/Lieu/Appareil/Type")
    el = d.find(id="searchFilterType")
    if el:
        d.tap_el(el)
        time.sleep(1.2)
        d.step("recherche-filtre-type-ouvert")
        if d.tap_found(label="Vidéos"):
            time.sleep(1.2)
    d.tap_xy(336, 100)  # « Terminé » de la feuille (toolbar → hors arbre AX)
    time.sleep(1.8)
    d.step("recherche-resultats-filtres",
           note="tuiles vidéo : placeholder gris = vidéos « hidden » en 404 côté démo")


def tour_tabs(d: Driver) -> None:
    d.launch_app()
    for index, name in ((1, "souvenirs"), (2, "albums"), (3, "partage")):
        d.tab(index)
        d.step(f"onglet-{name}")
    # premier album : liste puis détail
    d.tab(2)
    row = d.find(contains="photos") or d.find(type="Button", contains="Album")
    if row is not None and d.frame(row).get("y", 0) > 150:
        d.tap_el(row)
        time.sleep(2.2)
        d.step("album-detail")
        d.back()
        time.sleep(1.2)


def reveal(d: Driver, rid: str) -> dict | None:
    """Amène la ligne `rid` dans l'arbre ET sous la barre du haut.

    Cherche d'abord sans défiler (un retour d'écran poussé laisse le Form à sa
    position), puis descend, puis remonte et redescend — sans jamais faire les
    deux boucles complètes à chaque ligne (~400 appels idb sinon).
    """
    for _ in range(8):
        el = d.find(id=rid)
        if el is not None and d.frame(el).get("y", 0) > 120:
            return el
        d.scroll("down", settle=0.35)
    d.scroll("up", times=10, settle=0.3)
    for _ in range(14):
        el = d.find(id=rid)
        if el is not None and d.frame(el).get("y", 0) > 120:
            return el
        d.scroll("down", settle=0.3)
    return None


def tour_me(d: Driver, rows_limit: int) -> None:
    d.launch_app()
    if not d.tap_found(id="profileAvatar"):
        d.step("me-absent", note="profileAvatar introuvable")
        return
    time.sleep(1.6)
    d.step("me-hub")

    # Énumération générique : toutes les lignes *Row du hub, révélées par scroll.
    known: list[str] = []
    for _ in range(8):
        for el in d.describe():
            rid = str(el.get("AXUniqueId") or "")
            if rid.endswith("Row") and rid not in known:
                known.append(rid)
        d.scroll("down")
    if rows_limit:
        known = known[:rows_limit]

    for rid in known:
        found = reveal(d, rid)
        if found is None:
            d.step(f"me-{rid}-introuvable", note="ligne non révélée par le scroll")
            continue
        d.tap_el(found)
        time.sleep(2.0)
        d.step(f"me-{rid}")
        # retour : écran poussé → BackButton ; feuille → Fermer/Terminé ; sinon relance
        if d.back():
            continue
        closed = False
        for label in ("Terminé", "Fermer", "Annuler", "OK"):
            if d.tap_found(label=label):
                closed = True
                break
        time.sleep(1.2)
        if not closed:
            d.launch_app()
            d.tap_found(id="profileAvatar")
            time.sleep(1.6)


def tour_sync_status(d: Driver) -> None:
    d.launch_app()
    if not d.tap_found(id="syncStatusButton"):
        d.step("sync-absent")
        return
    time.sleep(1.8)
    d.step("sync-status", expect_id="syncStatusDone")
    d.tap_found(id="syncStatusDone")
    time.sleep(1.2)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=("quick", "full"), default="full")
    ap.add_argument("--only", default="", help="sections séparées par des virgules")
    ap.add_argument("--out", default="/tmp/ui-review")
    ap.add_argument("--udid", default=DEFAULT_UDID)
    ap.add_argument("--bundle", default=DEFAULT_BUNDLE)
    ap.add_argument("--rows-limit", type=int, default=0,
                    help="limite le nombre de lignes du hub Me (0 = toutes)")
    ap.add_argument("--server", default="https://demo.immich.app")
    ap.add_argument("--email", default="demo@immich.app")
    ap.add_argument("--password", default="demo")
    args = ap.parse_args()

    only = {s.strip() for s in args.only.split(",") if s.strip()}
    quick = args.mode == "quick"
    d = Driver(udid=args.udid, bundle=args.bundle, out=args.out)
    d.ensure_ready()
    print(f"device {d.udid} · sortie {d.out}", flush=True)
    session = d.ensure_session(args.server, args.email, args.password)
    print(f"session : {session}", flush=True)
    if session in ("login-echec", "champs-login-absents", "champ-url-absent"):
        d.step("session-perdue", note=session)
        print("la tournée ne peut pas continuer sans session (voir SKILL.md)")
        d.write_index()
        return 2

    def run(name: str, fn, *fn_args, enabled: bool = True) -> None:
        """Une section qui casse ne doit pas emporter la tournée : on la capture
        comme une étape en échec et on passe à la suivante (mesuré : un appui long
        qui bloque idb avait interrompu tout le run)."""
        if not enabled or not section(d, name, only):
            return
        try:
            fn(*fn_args)
        except Exception as exc:  # noqa: BLE001
            print(f"  ! section {name} interrompue : {type(exc).__name__}: {exc}", flush=True)
            d.step(f"{name}-interrompu", note=f"{type(exc).__name__}: {exc}")

    run("timeline", tour_timeline, d)
    run("selection", tour_selection, d, enabled=not quick)
    run("menu", tour_context_menu, d, enabled=not quick)
    run("viewer", tour_viewer, d, enabled=not quick)
    run("search", tour_search, d, enabled=not quick)
    run("tabs", tour_tabs, d)
    run("me", tour_me, d, args.rows_limit or (6 if quick else 0))
    run("sync", tour_sync_status, d, enabled=not quick)

    path = d.write_index()
    flagged = sum(1 for r in d.index if r["warnings"])
    print(f"\n{len(d.index)} étapes capturées · {flagged} signalée(s)\nindex : {path}")
    for row in d.index:
        if row["warnings"]:
            print(f"  ⚠ {row['tag']} — {' ; '.join(row['warnings'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
