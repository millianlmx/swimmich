#!/usr/bin/env python3
"""uidrive — pilotage minimal et robuste d'un simulateur iOS via idb.

Pourquoi idb et pas le MCP `ios_simulator` : mesuré le 2026-10-07 avec Xcode 27,
l'injection de touches du MCP est morte (son binaire `simtouch` code en dur
l'ancien chemin SimulatorKit, déplacé de Contents/Developer/Library/PrivateFrameworks
vers Contents/SharedFrameworks, et l'ABI Indigo a changé : les messages sont
acceptés sans erreur mais n'atteignent pas l'app). idb, lui, négocie le transport
`dtuhid` et fonctionne.

Sous-ensemble d'idb validé (et rien d'autre) :
  - `idb ui tap X Y --api hid`   → instantané (~0,2 s), coordonnées en points
  - `idb ui describe-all`        → arbre d'accessibilité complet (~0,4 s)
  - `idb ui scroll up|down`      → défilement AX, instantané (~0,6 s)
  - `idb ui tap X Y --duration N`→ appui long (même chemin HID)
  - `idb ui text "..."`          → frappe dans le champ focalisé

Les GESTES (`idb ui swipe`, `drag-and-drop`) ne sont PAS utilisés : le client idb
bloque ~90 s en attendant une complétion qui n'arrive jamais sur iOS 26.3 (la
gestuelle est bien délivrée, mais l'attente rend le pilotage impraticable) ; un
geste peut en plus wedger le companion.

Deux pièges d'outillage encodés ici :
  1. Les items de *toolbar* SwiftUI (iOS 26) n'apparaissent PAS dans l'arbre AX
     d'idb (ni dans celui du MCP), alors que XCUITest les voit → ces contrôles se
     tapent par COORDONNÉES (voir `tap_xy`), jamais par identifiant.
  2. Le companion idb meurt si on le lance depuis un shell qui se termine → on le
     lance détaché (start_new_session) et on le relance à la première connexion
     refusée.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import time

IDB = "/opt/homebrew/bin/idb"
COMPANION = "/opt/homebrew/bin/idb_companion"
SOCK_DIR = "/tmp/idb"

# iPhone 17 iOS 26.3 du poste, celui qui porte la session demo.immich.app.
DEFAULT_UDID = "01E517EC-D35A-4B5D-8D21-DF450BE45272"
DEFAULT_BUNDLE = "fr.millianlmx.immich-ios"


class Driver:
    """Pilote un device : taps, scroll, arbre AX, captures, détection de défauts."""

    def __init__(self, udid: str = DEFAULT_UDID, bundle: str = DEFAULT_BUNDLE,
                 out: str = "/tmp/ui-review", verbose: bool = True):
        self.udid = udid
        self.bundle = bundle
        self.out = out
        self.verbose = verbose
        self.index: list[dict] = []
        self._last_hash: str | None = None
        self._step_no = 0
        os.makedirs(out, exist_ok=True)

    # ------------------------------------------------------------------ idb
    @property
    def _sock(self) -> str:
        return f"{SOCK_DIR}/{self.udid}_companion.sock"

    def _spawn_companion(self) -> None:
        os.makedirs(SOCK_DIR, exist_ok=True)
        if os.path.exists(self._sock):
            os.unlink(self._sock)
        log = open(f"{SOCK_DIR}/companion.log", "ab")
        subprocess.Popen(
            [COMPANION, "--udid", self.udid, "--grpc-domain-sock", self._sock,
             "--only", "simulator"],
            stdout=log, stderr=log, start_new_session=True,
        )
        for _ in range(40):
            time.sleep(0.5)
            if os.path.exists(self._sock):
                return
        raise RuntimeError("idb_companion n'a jamais ouvert son socket")

    def idb(self, *args: str, timeout: float = 25, retry: bool = True) -> subprocess.CompletedProcess:
        cmd = [IDB, *args, "--udid", self.udid]
        try:
            done = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            if retry:
                self._spawn_companion()
                return self.idb(*args, timeout=timeout, retry=False)
            raise
        if done.returncode != 0 and retry and "Failed to connect to companion" in (done.stderr or ""):
            self._spawn_companion()
            return self.idb(*args, timeout=timeout, retry=False)
        return done

    def ensure_ready(self) -> None:
        """Boot du device si besoin + companion joignable."""
        state = subprocess.run(["xcrun", "simctl", "list", "devices", "booted"],
                               capture_output=True, text=True).stdout
        if self.udid not in state:
            subprocess.run(["xcrun", "simctl", "boot", self.udid], capture_output=True)
            subprocess.run(["xcrun", "simctl", "bootstatus", self.udid, "-b"], capture_output=True)
        probe = self.idb("ui", "describe-all")
        if probe.returncode != 0:
            self._spawn_companion()
            probe = self.idb("ui", "describe-all", retry=False)
            if probe.returncode != 0:
                raise RuntimeError(f"idb injoignable : {probe.stderr[:200]}")
        installed = subprocess.run(["xcrun", "simctl", "get_app_container", self.udid,
                                    self.bundle, "app"], capture_output=True, text=True)
        if installed.returncode != 0:
            raise RuntimeError(
                f"l'app {self.bundle} n'est pas installée sur {self.udid} — "
                "la construire puis `xcrun simctl install` (voir SKILL.md)")
        # Pré-grant Photothèque : sans lui, ouvrir les réglages de Sauvegarde
        # déclenche la demande système, qui bloque TOUTES les étapes suivantes
        # (mesuré : 20 lignes du hub « Me » restées introuvables derrière la
        # boîte « Autoriser l'accès complet »). Même pré-grant que uitest.sh.
        for service in ("photos", "photos-add"):
            subprocess.run(["xcrun", "simctl", "privacy", self.udid, "grant",
                            service, self.bundle], capture_output=True)

    # ------------------------------------------------------------ app life
    def launch_app(self, settle: float = 4.0) -> None:
        """Relance l'app à froid : c'est le seul « retour maison » fiable.

        `simctl launch` sur une app déjà lancée ne fait que la passer au premier
        plan en gardant son état (mesuré : on restait dans le lecteur) → terminate
        d'abord.
        """
        subprocess.run(["xcrun", "simctl", "terminate", self.udid, self.bundle],
                       capture_output=True)
        time.sleep(0.8)
        subprocess.run(["xcrun", "simctl", "launch", self.udid, self.bundle],
                       capture_output=True)
        time.sleep(settle)

    # ------------------------------------------------------------- queries
    def describe(self) -> list[dict]:
        done = self.idb("ui", "describe-all")
        try:
            return json.loads(done.stdout)
        except Exception:
            return []

    @staticmethod
    def frame(el: dict) -> dict:
        return el.get("frame") or {}

    @classmethod
    def center(cls, el: dict) -> tuple[float, float]:
        f = cls.frame(el)
        return f.get("x", 0) + f.get("width", 0) / 2, f.get("y", 0) + f.get("height", 0) / 2

    def find(self, id: str | None = None, label: str | None = None,
             contains: str | None = None, type: str | None = None,
             tree: list[dict] | None = None) -> dict | None:
        for el in (tree if tree is not None else self.describe()):
            if type and el.get("type") != type:
                continue
            if id and el.get("AXUniqueId") != id:
                continue
            if label and el.get("AXLabel") != label:
                continue
            if contains:
                hay = f"{el.get('AXUniqueId')} {el.get('AXLabel')}"
                if contains.lower() not in hay.lower():
                    continue
            return el
        return None

    # ------------------------------------------------------------ actions
    def tap_xy(self, x: float, y: float, duration_ms: int | None = None) -> None:
        """Tap HID. Un appui long est lancé DÉTACHÉ : idb ne rend pas la main sur
        les gestes sous iOS 26.3 (mesuré : `--duration 900` bloquait > 25 s), mais
        le geste part quand même — on ne l'attend pas."""
        args = ["ui", "tap", str(int(round(x))), str(int(round(y))), "--api", "hid"]
        if duration_ms:
            args += ["--duration", str(duration_ms)]
            subprocess.Popen([IDB, *args, "--udid", self.udid],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
            time.sleep(1.2)
            return
        self.idb(*args)

    def tap_el(self, el: dict, duration_ms: int | None = None) -> None:
        x, y = self.center(el)
        self.tap_xy(x, y, duration_ms)

    def tap_found(self, **kw) -> bool:
        el = self.find(**kw)
        if el is None:
            return False
        self.tap_el(el)
        return True

    def tiles(self, min_y: float = 100) -> list[dict]:
        """Vignettes de la timeline, dédupliquées.

        L'arbre expose CHAQUE vignette deux fois (l'image et son conteneur, même
        `assetTile_<id>`) : taper les deux premières entrées brutes tape deux fois
        la MÊME photo, ce qui la sélectionne puis la désélectionne — mesuré, et
        c'est exactement le faux « tap-sans-effet » de la première version.
        """
        seen: set[str] = set()
        out: list[dict] = []
        for el in self.describe():
            uid = str(el.get("AXUniqueId") or "")
            if uid.startswith("assetTile_") and uid not in seen and self.frame(el).get("y", 0) > min_y:
                seen.add(uid)
                out.append(el)
        return out

    def scroll(self, direction: str = "down", times: int = 1, settle: float = 0.7) -> None:
        for _ in range(times):
            self.idb("ui", "scroll", direction)
            time.sleep(settle)

    def type_text(self, text: str) -> None:
        self.idb("ui", "text", text)

    def tab(self, index: int, settle: float = 1.6) -> None:
        """Onglets du bas : 0 Photos · 1 Souvenirs · 2 Albums · 3 Partagé.

        La barre est une capsule flottante (iOS 26) dont le cadre AX couvre toute
        la largeur : les centres réels, mesurés sur iPhone 17 (402 pt), sont
        40/120/200/280 et la bulle Recherche à 360, y = 832.
        """
        xs = [40, 120, 200, 280]
        self.tap_xy(xs[index], 832)
        time.sleep(settle)

    def search_bubble(self, settle: float = 1.6) -> None:
        self.tap_xy(360, 832)
        time.sleep(settle)

    def back(self, settle: float = 1.2) -> bool:
        """Bouton retour d'un écran poussé (label localisé)."""
        el = self.find(contains="Retour") or self.find(label="Back")
        if el is None or el.get("type") != "Button":
            el = self.find(type="Button", label="Moi")
        if el is None:
            return False
        self.tap_el(el)
        time.sleep(settle)
        return True

    # ------------------------------------------------------------- session
    # Libellés localisés des écrans d'onboarding (source anglaise, 5 langues).
    START_LABELS = ("Get Started", "Commencer", "Loslegen", "Empezar", "Inizia")
    CONTINUE_LABELS = ("Continue", "Continuer", "Weiter", "Continuar", "Continua")
    CHECK_LABELS = ("Check connection", "Vérifier la connexion", "Verbindung prüfen",
                    "Comprobar conexión", "Verifica connessione")
    SIGNIN_LABELS = ("Sign In", "Se connecter", "Connexion", "Anmelden",
                     "Iniciar sesión", "Accedi")

    def type_in_field(self, text: str) -> None:
        """Tape `text` dans le champ focalisé en pressant les touches AFFICHÉES.

        `idb ui text` envoie des keycodes HID mappés QWERTY : sur un simulateur en
        AZERTY, la ponctuation ET trois lettres sortent fausses (mesuré :
        « https://demo.immich.app » → « httpsM==de,o:i,,ich:qpp.app », et
        « demo@immich.app » → « de,o@i,,ich.qpp » — 'm' est la plus vicieuse).
        Les touches du clavier virtuel portent, elles, leur caractère en label :
        on les presse une à une (le clavier e-mail expose '@' et '.').
        """
        for ch in text:
            key = self.find(type="Button", label=ch)
            if key is None:
                for switch in ("nombres", "more", "123"):
                    if self.tap_found(type="Button", label=switch):
                        time.sleep(0.4)
                        key = self.find(type="Button", label=ch)
                        if key is not None:
                            break
            if key is None:
                raise RuntimeError(f"touche {ch!r} introuvable sur le clavier")
            self.tap_el(key)
            time.sleep(0.12)

    def dismiss_password_prompt(self) -> bool:
        """Ferme la boîte système « Enregistrer le mot de passe ? ».

        Piège mesuré : tant que cette boîte iCloud Keychain est affichée, l'arbre
        d'accessibilité de l'app est VIDE (1 seul élément) — impossible de la
        trouver par label. On tape donc la position connue de « Plus tard »
        (iPhone 17, 402 × 874 : 134, 552) quand l'arbre est vide.
        """
        tree = self.describe()
        later = (self.find(type="Button", label="Plus tard", tree=tree)
                 or self.find(type="Button", label="Later", tree=tree))
        if later is not None:
            self.tap_el(later)
            time.sleep(1.2)
            return True
        if len(tree) <= 2:
            self.tap_xy(134, 552)
            time.sleep(1.5)
            return len(self.describe()) > 2
        return False

    def ensure_session(self, server: str, email: str, password: str,
                       settle: float = 4.0) -> str:
        """Garantit une session active, sinon refait le login d'onboarding.

        L'instance de démo révoque ses sessions sans prévenir (mesuré le
        2026-10-07 : le token de l'app est passé à 401 en ~30 min et l'app est
        retombée sur « Bienvenue sur Immich »). Sans cette étape, la tournée
        capture 14 fois l'écran d'accueil et ne prouve rien.
        """
        self.launch_app(settle=settle)
        # Une boîte système peut masquer l'arbre : on la ferme avant de juger.
        if len(self.describe()) <= 2:
            self.dismiss_password_prompt()
        tree = self.describe()
        if self.find(id="selectButton", tree=tree) or self.find(id="timelinePinnedYearHeader", tree=tree):
            return "session-ok"
        if not any(self.find(type="Button", label=label, tree=tree)
                   for label in self.START_LABELS + self.SIGNIN_LABELS):
            return "etat-inconnu"
        # 1. Bienvenue → configuration du serveur
        for label in self.START_LABELS:
            if self.tap_found(type="Button", label=label):
                break
        time.sleep(1.5)
        # 2. Adresse du serveur : le champ est PRÉREMPLI depuis `authServerURL`
        #    (UserDefaults), donc rien à taper dans le cas normal — on ne tape
        #    que s'il est vide.
        field = self.find(type="TextField")
        if field is None:
            return "champ-url-absent"
        current = str(field.get("AXValue") or "")
        if not current.startswith("http"):
            self.tap_el(field)
            time.sleep(0.7)
            self.type_in_field(server)
            time.sleep(0.7)
        # Le bouton primaire change de libellé selon l'état du serveur :
        # « Vérifier la connexion » (au repos) → « Continuer » (serveur joignable).
        for label in self.CHECK_LABELS + self.CONTINUE_LABELS:
            if self.tap_found(type="Button", label=label):
                break
        time.sleep(3.5)
        for label in self.CONTINUE_LABELS:
            if self.tap_found(type="Button", label=label):
                break
        time.sleep(3.0)
        # 3. Identifiants — idb rapporte le champ sécurisé comme un `TextField` :
        #    on prend les deux premiers DANS L'ORDRE (e-mail puis mot de passe).
        fields = [el for el in self.describe() if el.get("type") == "TextField"]
        if len(fields) < 2:
            return "champs-login-absents"
        email_field, password_field = fields[0], fields[1]
        self.tap_el(email_field)
        time.sleep(0.6)
        self.type_in_field(email)
        time.sleep(0.5)
        self.tap_el(password_field)
        time.sleep(0.6)
        self.type_in_field(password)
        time.sleep(0.5)
        for label in self.SIGNIN_LABELS:
            if self.tap_found(type="Button", label=label):
                break
        time.sleep(6.0)
        # iCloud Keychain propose d'enregistrer le mot de passe juste après :
        # elle masque l'arbre, donc on la refuse avant de vérifier.
        self.dismiss_password_prompt()
        time.sleep(1.5)
        tree = self.describe()
        if self.find(id="selectButton", tree=tree) or self.find(id="timelinePinnedYearHeader", tree=tree):
            return "session-reouverte"
        return "login-echec"

    # ------------------------------------------------------------- capture
    def shot(self, name: str) -> str:
        path = os.path.join(self.out, f"{name}.png")
        subprocess.run(["xcrun", "simctl", "io", self.udid, "screenshot", path],
                       capture_output=True)
        return path

    @staticmethod
    def _png_hash(path: str) -> str:
        with open(path, "rb") as fh:
            return hashlib.sha1(fh.read()).hexdigest()

    def dismiss_modals(self, close_context_menu: bool = True) -> list[str]:
        """Détecte une alerte/menu ouvert, renvoie ses textes et le referme.

        Les alertes de l'app sont des `Button "OK"` accompagnés de deux textes
        (titre + message) ; le menu contextuel des vignettes porte un bouton
        « Fermer le menu contextuel ». Laisser une modale ouverte ferait échouer
        toutes les étapes suivantes (elle avale les taps) — on la referme, mais
        on garde son texte : c'est une preuve.
        """
        notes: list[str] = []
        error_words = ("erreur", "error", "échec", "echec", "impossible", "failed")
        permission_labels = ("Autoriser l’accès complet", "Autoriser l'accès complet",
                             "Allow Full Access", "Autoriser", "Allow")
        # Boîte iCloud Keychain après un login : on refuse poliment (on ne veut
        # pas d'un mot de passe stocké par la tournée), mais il faut la fermer.
        later_labels = ("Plus tard", "Later", "Später", "Más tarde", "Più tardi")
        for _ in range(4):
            tree = self.describe()
            later = None
            for label in later_labels:
                later = self.find(type="Button", label=label, tree=tree)
                if later is not None:
                    break
            if later is not None:
                notes.append(f"dialogue-mot-de-passe: {later.get('AXLabel')}")
                self.tap_el(later)
                time.sleep(1.2)
                continue
            # Boîte de permission système : elle avale tout, on l'accorde.
            grant = None
            for label in permission_labels:
                grant = self.find(type="Button", label=label, tree=tree)
                if grant is not None:
                    break
            if grant is not None:
                notes.append(f"permission-demande: {grant.get('AXLabel')}")
                self.tap_el(grant)
                time.sleep(1.2)
                continue
            ok = self.find(type="Button", label="OK", tree=tree)
            texts = [str(el.get("AXLabel")) for el in tree
                     if el.get("type") == "StaticText" and el.get("AXLabel")]
            # On ne tape « OK » que sur une ALERTE D'ERREUR : un « OK » de
            # confirmation (suppression, permission) doit rester intact.
            if ok is not None and any(w in t.lower() for t in texts for w in error_words):
                notes.append("alerte-modale: " + " / ".join(texts[:2]))
                self.tap_el(ok)
                time.sleep(1.0)
                continue
            if close_context_menu:
                closer = self.find(type="Button", label="Fermer le menu contextuel", tree=tree)
                if closer is not None:
                    notes.append("menu-contextuel-ouvert")
                    self.tap_el(closer)
                    time.sleep(1.0)
                    continue
            break
        return notes

    def step(self, name: str, expect_id: str | None = None,
             expect_label: str | None = None, allow_same: bool = False,
             note: str = "") -> dict:
        """Capture + arbre + heuristiques de défaut, une ligne d'index par étape.

        Heuristiques (chacune a attrapé un vrai défaut le 2026-10-07) :
          * `tap-sans-effet`   : PNG identique à l'étape précédente → le tap n'a rien fait.
          * `ecran-vide`       : ≤ 2 éléments AX (ex. lecteur avec chrome masqué).
          * `texte-ecrase`     : texte dont le cadre fait < 20 pt alors que le label
                                 est plus long (le titre du lecteur tombait à 10 pt).
          * `attendu-absent`   : l'élément `expect_*` n'est pas là après l'action.
        """
        self._step_no += 1
        tag = f"{self._step_no:02d}-{name}"
        png = self.shot(tag)
        tree = self.describe()
        with open(os.path.join(self.out, f"{tag}.tree.json"), "w") as fh:
            json.dump(tree, fh, indent=1)

        warnings: list[str] = []
        digest = self._png_hash(png)
        if not allow_same and self._last_hash == digest:
            warnings.append("tap-sans-effet (capture identique à l'étape précédente)")
        self._last_hash = digest
        if len(tree) <= 2:
            warnings.append("ecran-vide (≤2 éléments d'accessibilité)")
        for el in tree:
            label = str(el.get("AXLabel") or "")
            f = self.frame(el)
            width = f.get("width")
            if (el.get("type") in ("StaticText", "Heading") and len(label) >= 4
                    and width is not None and width < 20):
                warnings.append(f"texte-ecrase: {label!r} dans {width:.0f} pt")
        if expect_id and self.find(id=expect_id, tree=tree) is None:
            warnings.append(f"attendu-absent: id={expect_id}")
        if expect_label and self.find(label=expect_label, tree=tree) is None:
            warnings.append(f"attendu-absent: label={expect_label}")
        # Une modale ouverte avale tous les taps suivants : on la signale (son
        # texte est une preuve) et on la referme pour que la tournée continue.
        warnings.extend(self.dismiss_modals())

        row = {"tag": tag, "name": name, "elements": len(tree), "note": note,
               "warnings": warnings}
        self.index.append(row)
        if self.verbose:
            flag = ("  ⚠ " + " ; ".join(warnings)) if warnings else ""
            print(f"[{tag}] {len(tree):3d} éléments{flag}", flush=True)
        return row

    def write_index(self, title: str = "Revue UI — tournée automatique") -> str:
        path = os.path.join(self.out, "index.md")
        lines = [f"# {title}", "",
                 f"Device `{self.udid}` · app `{self.bundle}` · "
                 f"{time.strftime('%Y-%m-%d %H:%M')}", "",
                 "| # | écran | capture | éléments | alertes |",
                 "|---|-------|---------|----------|---------|"]
        for row in self.index:
            warn = " ; ".join(row["warnings"]) or "—"
            lines.append(f"| {row['tag'].split('-')[0]} | {row['name']} | "
                         f"[{row['tag']}.png]({row['tag']}.png) | {row['elements']} | {warn} |")
        flagged = [r for r in self.index if r["warnings"]]
        lines += ["", f"**{len(flagged)} étape(s) signalée(s)** sur {len(self.index)}."]
        with open(path, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        self.write_html(title)
        return path

    def write_html(self, title: str = "Revue UI — tournée automatique") -> str:
        """Planche unique : toutes les captures dans une page, alertes en rouge.

        C'est le fichier à ouvrir pour la relecture visuelle : un seul scroll au
        lieu de N images.
        """
        path = os.path.join(self.out, "index.html")
        parts = [f"""<!doctype html><meta charset="utf-8"><title>{title}</title>
<style>
 body{{font:14px -apple-system,system-ui,sans-serif;background:#101014;color:#e8e8ee;margin:24px}}
 h1{{font-size:20px}} .grid{{display:flex;flex-wrap:wrap;gap:20px}}
 .step{{width:300px}} .step img{{width:300px;border-radius:10px;display:block;background:#000}}
 .name{{font-weight:600;margin:6px 0 2px}} .meta{{color:#9a9aa8;font-size:12px}}
 .warn{{color:#ff8f7a;font-size:12px;margin-top:4px}} .ok{{color:#7ad19a}}
</style>
<h1>{title}</h1>
<p class="meta">Device {self.udid} · app {self.bundle} · {time.strftime('%Y-%m-%d %H:%M')}</p>
<div class="grid">"""]
        for row in self.index:
            warn = ("<div class='warn'>⚠ " + " ; ".join(row["warnings"]) + "</div>"
                    if row["warnings"] else "<div class='ok'>—</div>")
            parts.append(
                f"<div class='step'><a href='{row['tag']}.png'>"
                f"<img src='{row['tag']}.png' loading='lazy'></a>"
                f"<div class='name'>{row['tag']}</div>"
                f"<div class='meta'>{row['elements']} éléments AX"
                f"{' · ' + row['note'] if row['note'] else ''}</div>{warn}</div>")
        parts.append("</div>")
        with open(path, "w") as fh:
            fh.write("\n".join(parts) + "\n")
        return path


def slug(text: str, max_len: int = 40) -> str:
    text = re.sub(r"[^a-zA-Z0-9]+", "-", text).strip("-").lower()
    return text[:max_len] or "ecran"
