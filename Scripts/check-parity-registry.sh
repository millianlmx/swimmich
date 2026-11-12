#!/usr/bin/env bash
# Checks docs/parity-registry-v3.4.0.md (the gap registry against the official
# Immich mobile client v3.4.0) and the documentation fixes that go with it.
#
#   Scripts/check-parity-registry.sh [AC-1|AC-2|AC-3|AC-4|AC-38|all]   (default: all)
#
# One line per defect: `PASS AC-<n>` or `FAIL AC-<n>: <reason>`. Exit 0 when
# everything passes, 1 when a check fails, 2 on an unknown argument.
# Needs only bash, grep, awk, sed and git (no python: the harness host has none).
set -euo pipefail
cd "$(dirname "$0")/.."

REG=docs/parity-registry-v3.4.0.md
REF=docs/mobile-features-vs-flutter.md
BACKLOG=.omp/backlog/ImmichSwiftUI-backlog.md
US=$'\037'
CITE_RE='[A-Za-z0-9_./+-]+\.(swift|py|yml|plist|xcstrings|entitlements|sh|md):[0-9]+([-,][0-9]+)*'

# S-17: closed expectations of the audit. `ID|écart|B-n ...` must stay a gap
# (or be closed by a delivered lot); `ID|exclu` must stay an exclusion.
EXPECT_A=$(cat <<'EOF'
F-02.3|écart|B-16
F-02.4|écart|B-16
F-04.5|écart|B-9
F-05.3|écart|B-25
F-05.5|écart|B-25
F-06.3|écart|B-27
F-06.5|écart|B-27
F-06.8|écart|B-27
F-06.10|écart|B-27
F-06.12|écart|B-27
F-06.16|écart|B-27
F-07.3|écart|B-5
F-08.2|écart|B-12
F-10.6|écart|B-28
F-15.2|écart|B-7
F-20.5|écart|B-13 B-14 B-31
F-20.6|écart|B-3
F-20.11|écart|B-13
F-20.13|écart|B-13 B-14
F-20.14|écart|B-31
F-21.2|écart|B-41
F-21.4|écart|B-29
F-22.3|écart|B-28
F-24.2|écart|B-27
R-LoginRoute|écart|B-13 B-14 B-32
R-TabShellRoute|écart|B-16
R-MainTimelineRoute|écart|B-8
R-LibraryRoute|écart|B-16
R-AlbumsRoute|écart|B-6 B-39
R-SettingsRoute|écart|B-16
R-SettingsSubRoute|écart|B-13 B-30 B-31
R-AppLogRoute|écart|B-15
R-AppLogDetailRoute|écart|B-15
R-HeaderSettingsRoute|écart|B-13
R-ShareIntentRoute|écart|B-13
R-LocalMediaSummaryRoute|écart|B-3
R-RemoteMediaSummaryRoute|écart|B-3
R-RemoteAlbumRoute|écart|B-4 B-5
R-AssetViewerRoute|écart|B-9 B-10 B-18
R-MemoryRoute|écart|B-11 B-34
R-MemoryListRoute|écart|B-11
R-PartnerRoute|écart|B-12
R-PartnerDetailRoute|écart|B-12
R-AlbumOptionsRoute|écart|B-5 B-40
R-BackupAssetDetailRoute|écart|B-37
V-#31082|écart|B-26
V-#30831|écart|B-11
V-#31798|écart|B-11
V-#31954|écart|B-5
V-#31805|écart|B-5
V-#31609|écart|B-10
V-#31606|écart|B-33
V-#31401|écart|B-31
V-#32552|écart|B-8
V-#32592|écart|B-9
V-#30753|écart|B-7
V-#32423|écart|B-10
V-#32288|écart|B-32
V-#32287|écart|B-15
V-#32550|écart|B-15
V-#32460|écart|B-29
V-#32181|écart|B-32
V-#32215|écart|B-35
V-#32652|écart|B-32
V-#32087|écart|B-38
U-2|écart|B-25
U-3|écart|B-26
P-custom_proxy_headers_settings|écart|B-13
P-ssl_client_cert_settings|écart|B-14
P-networking_settings|écart|B-30
P-share_setting|écart|B-31
P-advanced.log_level|écart|B-31
P-advanced.clear_image_cache|écart|B-31
F-06.11|exclu|
F-14.4|exclu|
F-20.9|exclu|
F-22.4|exclu|
F-23.1|exclu|
F-26.4|exclu|
R-RedirectRoute|exclu|
V-#31620|exclu|
V-#32485|exclu|
U-1|exclu|
U-4|exclu|
P-passkey_settings|exclu|
P-advanced.prefer_remote_image|exclu|
EOF
)
EXPECT_B=$(cat <<'EOF'
Connexion|Parcours|B-13 B-14 B-32
Connexion|Gestes et transitions|B-22
Connexion|Haptique|B-32
Connexion|Accessibilité|B-17 B-22 B-32
Timeline|Gestes et transitions|B-22
Timeline|Accessibilité|B-17 B-22
Visionneuse et panneau d'infos|États|B-33
Visionneuse et panneau d'infos|Gestes et transitions|B-22
Visionneuse et panneau d'infos|Haptique|B-33
Visionneuse et panneau d'infos|Accessibilité|B-17 B-22
Diaporama|Parcours|B-33
Diaporama|Accessibilité|B-17
Albums et détail d'album|États|B-20
Albums et détail d'album|Accessibilité|B-17 B-22
Recherche|États|B-20
Recherche|Gestes et transitions|B-22
Recherche|Accessibilité|B-17 B-22
Souvenirs|Parcours|B-34
Souvenirs|États|B-20
Souvenirs|Gestes et transitions|B-22
Souvenirs|Haptique|B-34
Souvenirs|Accessibilité|B-17 B-22
Carte|Parcours|B-29
Carte|États|B-20
Carte|Gestes et transitions|B-22 B-23
Carte|Accessibilité|B-17 B-22 B-23
Personnes|Gestes et transitions|B-22
Personnes|Accessibilité|B-17 B-22
Partage (liens et partenaires)|États|B-20
Partage (liens et partenaires)|Gestes et transitions|B-22 B-36
Partage (liens et partenaires)|Haptique|B-36
Partage (liens et partenaires)|Accessibilité|B-17 B-22
Hub « Me »|Parcours|B-16
Hub « Me »|Accessibilité|B-17
Réglages|Gestes et transitions|B-36
Réglages|Accessibilité|B-17
Sauvegarde|Parcours|B-37
Sauvegarde|États|B-20
Sauvegarde|Gestes et transitions|B-36
Sauvegarde|Haptique|B-36
Sauvegarde|Accessibilité|B-17 B-22
Verrouillage|États|B-20 B-36
Verrouillage|Haptique|B-36
Verrouillage|Accessibilité|B-17
EOF
)

STATUSES="présent|partiel|absent|hors périmètre"
BAD=0
fail() { echo "FAIL $1: $2"; BAD=$((BAD + 1)); }

# ---- parsing -----------------------------------------------------------------
# TSV of every table row of the registry: <section>US<cell>US<cell>...
# Sections: A.1..A.5, B, C. `\|` inside a cell does not split the row.
TSV=$(mktemp)
trap 'rm -f "$TSV"' EXIT
if [ -f "$REG" ]; then
  awk -v SEP="$US" '
    /^### A\.[1-5]/ { match($0, /A\.[1-5]/); sec = substr($0, RSTART, RLENGTH); next }
    /^## A\./ { sec = ""; next }
    /^## B\./ { sec = "B"; next }
    /^## C\./ { sec = "C"; next }
    /^## [D-Z]\./ { sec = ""; next }
    /^\|/ && sec != "" {
      line = $0
      gsub(/\\\|/, "\001", line)
      sub(/^\|/, "", line); sub(/\|[ \t]*$/, "", line)
      n = split(line, c, "|"); out = sec
      for (i = 1; i <= n; i++) { x = c[i]; gsub(/^[ \t]+|[ \t]+$/, "", x); gsub(/\001/, "|", x); out = out SEP x }
      print out
    }' "$REG" > "$TSV"
fi

# rows <section> <id-regex> : the retained rows (first cell matches the ID pattern)
rows() { awk -F"$US" -v s="$1" -v re="$2" '$1 == s && $2 ~ re' "$TSV"; }

need_registry() { [ -f "$REG" ] || { fail "$1" "$REG introuvable"; return 1; }; }

# check_cites <AC> <ID> <cell> : sets VALID to the number of valid file:line cites
check_cites() {
  local ac="$1" id="$2" cell="$3" tok f nums n len ok
  VALID=0
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    f="${tok%%:*}"; nums="${tok#*:}"
    if [ ! -f "$f" ]; then fail "$ac" "$id fichier introuvable $f"; continue; fi
    len=$(awk 'END { print NR }' "$f"); ok=1
    for n in $(printf '%s' "$nums" | tr -- '-,' '  '); do
      if [ "$n" -gt "$len" ]; then fail "$ac" "$id $f:$n au-delà de la fin ($len lignes)"; ok=0; fi
    done
    [ "$ok" = 1 ] && VALID=$((VALID + 1))
  done < <(printf '%s\n' "$cell" | grep -oE "$CITE_RE" || true)
}

# check_searches <AC> <ID> <cell> : replays every "Recherche locale" (must give 0); sets SEARCHES
check_searches() {
  local ac="$1" id="$2" cell="$3" s motif paths p cnt miss
  SEARCHES=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    SEARCHES=$((SEARCHES + 1))
    motif="${s#*\`}"; motif="${motif%%\`*}"
    paths="${s#*\` sur }"; paths="${paths%% →*}"
    miss=0
    for p in $paths; do [ -e "$p" ] || { fail "$ac" "$id recherche locale $motif : chemin introuvable $p"; miss=1; }; done
    [ "$miss" = 0 ] || continue
    # shellcheck disable=SC2086
    cnt=$( { grep -rEn -e "$motif" -- $paths 2>/dev/null || true; } | wc -l | tr -d ' ')
    [ "$cnt" = 0 ] || fail "$ac" "$id recherche locale $motif → $cnt"
  done < <(printf '%s\n' "$cell" | grep -oE 'Recherche locale : `[^`]+` sur [^→]+→ 0' || true)
}

has_bn() { printf '%s' "$1" | grep -qE 'B-[0-9]+'; }
bn_in() { printf '%s' "$1" | grep -qE "(^|[^0-9])$2([^0-9]|\$)"; }   # B-n token in a cell

# Lots delivered according to C: " B-3 B-4 ... ".
delivered_bns() {
  awk -F"$US" '$1 == "C" && $2 ~ /^L-[0-9]+$/ && $5 == "livré" { print $4 }' "$TSV" | grep -oE 'B-[0-9]+' | sed 's/^/ /' | tr -d '\n' || true
}

# expectation_ok <list-of-B> <status-kind> <last-cell> ; kind = row status or verdict class
# prints nothing; returns 0 when every expected B-n is in the cell, or closed by a delivered lot.
closed_by_lots() { local b; for b in $1; do case "$DELIVERED " in *" $b "*) ;; *) return 1 ;; esac; done; return 0; }

# ---- AC-1 : volet fonctions ----------------------------------------------------
ac1() {
  local ac=AC-1 n elems have id st proof amont last sec re line
  need_registry $ac || return 0
  # 1. a row per element of each section of the reference
  for n in $(seq 1 26); do
    elems=$(awk -v n="$n" '
      $0 ~ "^## " n "\\. " { inside = 1; prev = 0; next }
      /^## / { inside = 0 }
      inside && /^\|/ {
        if (!prev) { prev = 1; next }
        if ($0 ~ /^\|[-| :]+\|$/) next
        c++; next
      }
      inside { prev = 0; if ($0 ~ /^- /) c++ }
      END { print c + 0 }' "$REF")
    have=$(awk -F"$US" -v p="$(printf 'F-%02d.' "$n")" '$1 == "A.1" && index($2, p) == 1 { c++ } END { print c + 0 }' "$TSV")
    { [ "$have" -ge "$elems" ] && [ "$have" -ge 1 ]; } || fail $ac "§$n : $have ligne(s) F-$(printf '%02d' "$n").* pour $elems élément(s)"
  done
  # 2. PR and route lists
  for n in 31082 30831 31798 31620 31954 31805 31609 31941 31942 31943 31944 31948 28080 31606 31557 31401 29193 31146 31709 31587 31621 31552 29443 30490 32223 32171 32206 32200 32259 32485 32552 32592 30753 32423 32288 32287 32550 32611 31800 32460 31772 32307 31832 32181 32452 32159 32087 32215 32821 32652 31093 32522 32928 30262 32356 32100 32662 33099 32659 32213 32623; do
    [ -n "$(rows A.3 "^V-#$n\$")" ] || fail $ac "V-#$n absente"
  done
  for n in ActivitiesRoute AlbumOptionsRoute AlbumsRoute AppLogDetailRoute AppLogRoute ArchiveRoute AssetSelectionTimelineRoute AssetTroubleshootRoute AssetViewerRoute BackupAlbumSelectionRoute BackupAssetDetailRoute BackupOptionsRoute BackupRoute ChangePasswordRoute CleanupPreviewRoute CreateAlbumRoute DownloadInfoRoute EditImageRoute FavoriteRoute FolderRoute HeaderSettingsRoute LibraryRoute LocalAlbumsRoute LocalMediaSummaryRoute LocalTimelineRoute LockedFolderRoute LoginRoute MainTimelineRoute MapLocationPickerRoute MapRoute MemoryListRoute MemoryRoute PartnerDetailRoute PartnerRoute PeopleCollectionRoute PersonRoute PinAuthRoute PlaceDetailRoute PlaceRoute ProfilePictureCropRoute RecentlyAddedRoute RecentlyTakenRoute RemoteAlbumRoute RemoteMediaSummaryRoute SearchRoute SettingsRoute SettingsSubRoute ShareIntentRoute SharedLinkEditRoute SharedLinkRoute SlideshowRoute SplashScreenRoute SyncStatusRoute TabShellRoute TrashRoute UploadDetailRoute UserSelectionRoute VideoRoute WhatsNewRoute RedirectRoute; do
    [ -n "$(rows A.2 "^R-$n\$")" ] || fail $ac "R-$n absente"
  done
  # 3. form of every row of A.1..A.5
  for sec in A.1 A.2 A.3 A.4 A.5; do
    case $sec in
      A.1) re='^F-[0-9][0-9]\.[0-9]+$' ;; A.2) re='^R-[A-Za-z]+$' ;; A.3) re='^V-#[0-9]+$' ;;
      A.4) re='^U-[0-9]+$' ;; A.5) re='^P-[A-Za-z0-9_.]+$' ;;
    esac
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | awk -F"$US" '{ print $2 }'); st=$(printf '%s' "$line" | awk -F"$US" '{ print $4 }')
      amont=$(printf '%s' "$line" | awk -F"$US" '{ print $5 }'); proof=$(printf '%s' "$line" | awk -F"$US" '{ print $6 }')
      last=$(printf '%s' "$line" | awk -F"$US" '{ print $7 }')
      case "$st" in
        présent|partiel|absent|"hors périmètre") ;;
        *) fail $ac "$id statut « $st » hors vocabulaire ($STATUSES)"; continue ;;
      esac
      [ -n "$amont" ] || fail $ac "$id preuve amont vide"
      case "$st" in
        présent|partiel)
          check_cites $ac "$id" "$proof"
          [ "$VALID" -ge 1 ] || fail $ac "$id $st sans preuve locale chemin:ligne valide"
          ;;
        absent)
          if [ -z "$proof" ] || [ "$proof" = "—" ]; then fail $ac "$id absent sans preuve locale"; continue; fi
          check_cites $ac "$id" "$proof"; check_searches $ac "$id" "$proof"
          [ $((VALID + SEARCHES)) -ge 1 ] || fail $ac "$id absent : preuve locale ni chemin:ligne ni Recherche locale"
          ;;
      esac
      case "$st" in
        présent) [ "$last" = "—" ] || fail $ac "$id présent : lot/justification « $last » au lieu de —" ;;
        partiel|absent) has_bn "$last" || fail $ac "$id $st sans B-<n> dans « $last »" ;;
        "hors périmètre") case "$last" in "Exclu : "*) ;; *) fail $ac "$id hors périmètre sans « Exclu : »" ;; esac ;;
      esac
    done < <(rows $sec "$re")
  done
  # 4. closed expectations (S-17), volet fonctions
  expectations $ac A "$EXPECT_A"
}

# expectations <AC> <A|B> <list> : S-17. Row key: ID (A) or "écran|aspect" (B).
expectations() {
  local ac="$1" kind="$2" list="$3" id kind2 bns line st last found ok b vd label
  DELIVERED=$(delivered_bns)
  while IFS='|' read -r id kind2 bns; do
    [ -n "$id" ] || continue
    if [ "$kind" = A ]; then
      line=$(awk -F"$US" -v id="$id" '$1 ~ /^A\./ && $2 == id { print; exit }' "$TSV")
      label="$id"
    else
      line=$(awk -F"$US" -v e="$id" -v a="$kind2" '$1 == "B" && $2 == e && $3 == a { print; exit }' "$TSV")
      label="$id × $kind2"; kind2=écart; bns="$bns"
    fi
    if [ -z "$line" ]; then fail "$ac" "$label absente"; continue; fi
    if [ "$kind" = A ]; then
      st=$(printf '%s' "$line" | awk -F"$US" '{ print $4 }'); last=$(printf '%s' "$line" | awk -F"$US" '{ print $7 }')
    else
      st=$(printf '%s' "$line" | awk -F"$US" '{ print $4 }'); last=$(printf '%s' "$line" | awk -F"$US" '{ print $7 }')
      case "$st" in conforme) st=présent ;; "écart : "*) st=partiel ;; esac
    fi
    if [ "$kind2" = exclu ]; then
      { [ "$st" = "hors périmètre" ] && case "$last" in "Exclu : "*) true ;; *) false ;; esac; } \
        || fail "$ac" "$label attendu hors périmètre « Exclu : », trouvé $st $last"
      continue
    fi
    ok=1
    case "$st" in
      partiel|absent) for b in $bns; do bn_in "$last" "$b" || ok=0; done ;;
      présent) closed_by_lots "$bns" || ok=0 ;;
      *) ok=0 ;;
    esac
    [ "$ok" = 1 ] || fail "$ac" "$label attendu écart $bns, trouvé $st $last"
  done <<< "$list"
}

# ---- AC-2 ----------------------------------------------------------------------
ac2() {
  local ac=AC-2 n line st amont last
  need_registry $ac || return 0
  for n in 1 2 3 4; do
    line=$(rows A.4 "^U-$n\$")
    if [ -z "$line" ]; then fail $ac "U-$n absente"; continue; fi
    st=$(printf '%s' "$line" | awk -F"$US" '{ print $4 }'); amont=$(printf '%s' "$line" | awk -F"$US" '{ print $5 }')
    last=$(printf '%s' "$line" | awk -F"$US" '{ print $7 }')
    case "$st" in
      absent) has_bn "$last" || fail $ac "U-$n absent sans B-<n>" ;;
      "hors périmètre") case "$amont" in *"Recherche négative :"*) ;; *) fail $ac "U-$n hors périmètre sans « Recherche négative : » en preuve amont" ;; esac ;;
      *) fail $ac "U-$n statut $st : attendu absent ou hors périmètre" ;;
    esac
  done
}

# ---- AC-3 ----------------------------------------------------------------------
ac3() {
  local ac=AC-3 hits line before after
  hits=$(grep -rn 'PHASE_QR\|PHASE_OAUTH\|PHASE_CERT' Sources 2>/dev/null || true)
  [ -z "$hits" ] || fail $ac "marqueur \$PHASE_ restant dans Sources : $(printf '%s' "$hits" | head -n 1)"
  if [ -f "$BACKLOG" ]; then
    line=$(grep -E '^\| G21 ' "$BACKLOG" || true)
    [ -n "$line" ] || fail $ac "ligne G21 introuvable dans $BACKLOG"
    case "$line" in *"❌ absent"*) fail $ac "G21 du backlog dit encore « ❌ absent »" ;; esac
    grep -q "état local optimiste" "$BACKLOG" && fail $ac "backlog : « état local optimiste » reste"
    grep -q "l'état iOS est optimiste" "$BACKLOG" && fail $ac "backlog : « l'état iOS est optimiste » reste"
  else fail $ac "$BACKLOG introuvable"; fi
  if [ -f "$REF" ]; then
    grep -q 'hors `duplicate_guard.dart`' "$REF" && fail $ac "$REF : « hors \`duplicate_guard.dart\` » reste"
    line=$(grep 'Tag renaming' "$REF" || true)
    case "$line" in *"web uniquement"*) ;; *) fail $ac "$REF : ligne Tag renaming sans « web uniquement »" ;; esac
    line=$(grep -E '^\| gap #12 ' "$REF" || true)
    case "$line" in
      *getAPIKeys*)
        before="${line%%getAPIKeys*}"; after="getAPIKeys${line#*getAPIKeys}"
        case "$before" in *"UI Admin"*) ;; *) fail $ac "gap #12 : « UI Admin » absent du segment avant getAPIKeys" ;; esac
        case "$after" in *UserApiKeysView*) ;; *) fail $ac "gap #12 : UserApiKeysView absent du segment clés API" ;; esac
        case "$after" in *"UI Admin"*) fail $ac "gap #12 : « UI Admin » dans le segment clés API" ;; esac ;;
      *) fail $ac "gap #12 sans segment clés API" ;;
    esac
    grep -E '^## 23\.' "$REF" | grep -q 'fantôme' || fail $ac "$REF : titre §23 sans « fantôme »"
  else fail $ac "$REF introuvable"; fi
  grep -q 'parity-registry-v3.4.0.md' docs/README.md 2>/dev/null || fail $ac "docs/README.md ne contient pas parity-registry-v3.4.0.md"
}

# ---- AC-4 ----------------------------------------------------------------------
ac4() {
  local ac=AC-4 n b id st sha acs besoins cnt line sec re last l a lots crit
  need_registry $ac || return 0
  # lots L-01..L-33 (L-34+ accepted)
  for n in $(seq 1 33); do
    [ -n "$(rows C "^L-$(printf '%02d' "$n")\$")" ] || fail $ac "L-$(printf '%02d' "$n") absent de C"
  done
  # every B-3..B-38 and every B-n defined in D is in exactly one lot row
  lots=$( { seq 3 38; awk '/^## D\./ { d = 1; next } /^## / { d = 0 } d && /^- B-[0-9]+ :/ { sub(/^- B-/, ""); sub(/ .*/, ""); print }' "$REG" 2>/dev/null; } | sort -un)
  for n in $lots; do
    cnt=$(rows C '^L-[0-9]+$' | awk -F"$US" -v b="B-$n" '{ if ($4 ~ "(^|[^0-9])" b "([^0-9]|$)") c++ } END { print c + 0 }')
    [ "$cnt" = 1 ] || fail $ac "B-$n dans $cnt ligne(s) de C (attendu 1)"
  done
  # statuses, SHA, delivered AC
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | awk -F"$US" '{ print $2 }'); st=$(printf '%s' "$line" | awk -F"$US" '{ print $5 }')
    sha=$(printf '%s' "$line" | awk -F"$US" '{ print $6 }'); acs=$(printf '%s' "$line" | awk -F"$US" '{ print $7 }')
    case "$st" in
      planifié|"en cours") { [ "$sha" = "—" ] && [ "$acs" = "—" ]; } || fail $ac "$id $st : SHA et AC doivent valoir —" ;;
      livré)
        printf '%s' "$sha" | grep -qE '^[0-9a-f]{7,40}$' || fail $ac "$id livré : SHA « $sha » invalide"
        git cat-file -e "$sha^{commit}" 2>/dev/null || fail $ac "$id livré : commit $sha introuvable"
        printf '%s' "$acs" | grep -qE 'AC-[0-9]+' || fail $ac "$id livré sans AC prouvés" ;;
      *) fail $ac "$id statut « $st » hors vocabulaire (planifié|en cours|livré)" ;;
    esac
  done < <(rows C '^L-[0-9]+$')
  # B-n cited by a gap row of A or B must be in C
  while IFS= read -r line; do
    sec=$(printf '%s' "$line" | awk -F"$US" '{ print $1 }'); id=$(printf '%s' "$line" | awk -F"$US" '{ print $2 }')
    if [ "$sec" = B ]; then
      id="$id × $(printf '%s' "$line" | awk -F"$US" '{ print $3 }')"
      st=$(printf '%s' "$line" | awk -F"$US" '{ print $4 }'); case "$st" in "écart : "*) st=gap ;; *) continue ;; esac
    else
      st=$(printf '%s' "$line" | awk -F"$US" '{ print $4 }'); case "$st" in partiel|absent) st=gap ;; "hors périmètre") st=out ;; *) continue ;; esac
    fi
    last=$(printf '%s' "$line" | awk -F"$US" '{ print $7 }')
    if [ "$st" = out ] || ! has_bn "$last"; then
      case "$last" in "Exclu : "*) ;; *) fail $ac "$id sans lot ni « Exclu : » : « $last »" ;; esac
    fi
    for b in $(printf '%s' "$last" | grep -oE 'B-[0-9]+' || true); do
      [ -n "$(rows C '^L-[0-9]+$' | awk -F"$US" -v b="$b" '$4 ~ "(^|[^0-9])" b "([^0-9]|$)"')" ] || fail $ac "$id cite $b absent de C"
    done
  done < <( { awk -F"$US" '$1 ~ /^A\./' "$TSV"; awk -F"$US" '$1 == "B"' "$TSV"; } )
  # criteria per lot
  crit=$(awk '/^## C\./ { c = 1; next } /^## / { c = 0 } c && /^- L-[0-9]+ :/' "$REG" 2>/dev/null || true)
  for n in $(seq 5 37) $(seq 39 66); do
    cnt=$(printf '%s\n' "$crit" | grep -cE "(^|[^0-9])AC-$n([^0-9]|\$)" || true)
    [ "$cnt" = 1 ] || fail $ac "AC-$n $([ "$cnt" = 0 ] && echo absent || echo 'en double')"
  done
  # criteria numbered from AC-67 (added by later lots): each one cited exactly once
  for n in $(printf '%s\n' "$crit" | grep -oE 'AC-[0-9]+' | sed 's/^AC-//' | awk '$1 >= 67' | sort -un); do
    cnt=$(printf '%s\n' "$crit" | grep -cE "(^|[^0-9])AC-$n([^0-9]|\$)" || true)
    [ "$cnt" = 1 ] || fail $ac "AC-$n en double"
  done
  for n in 1 2 3 4 38; do
    printf '%s\n' "$crit" | grep -qE "(^|[^0-9])AC-$n([^0-9]|\$)" && fail $ac "AC-$n appartient à ce run"
  done
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    l=$(printf '%s' "$line" | sed -E 's/^- (L-[0-9]+) :.*/\1/')
    st=$(rows C "^$l\$" | awk -F"$US" '{ print $5 }'); acs=$(rows C "^$l\$" | awk -F"$US" '{ print $7 }')
    if [ -z "$st" ]; then fail $ac "$l inconnu"; continue; fi
    if [ "$st" = livré ]; then
      for a in $(printf '%s' "$line" | grep -oE 'AC-[0-9]+'); do
        bn_in "$acs" "$a" || fail $ac "$l livré sans $a"
      done
    fi
  done <<< "$crit"
}

# ---- AC-38 ---------------------------------------------------------------------
SCREENS=("Connexion" "Timeline" "Visionneuse et panneau d'infos" "Diaporama" "Albums et détail d'album" "Recherche" "Souvenirs" "Carte" "Personnes" "Partage (liens et partenaires)" "Hub « Me »" "Réglages" "Sauvegarde" "Verrouillage")
ASPECTS=("Parcours" "États" "Gestes et transitions" "Haptique" "Matériau" "Accessibilité")
ac38() {
  local ac=AC-38 scr asp cnt total line verdict proof ref
  need_registry $ac || return 0
  total=$(awk -F"$US" '$1 == "B" && $2 != "Écran" && $2 !~ /^-+$/' "$TSV" | wc -l | tr -d ' ')
  [ "$total" = 84 ] || fail $ac "B compte $total ligne(s) au lieu de 84"
  for scr in "${SCREENS[@]}"; do
    for asp in "${ASPECTS[@]}"; do
      cnt=$(awk -F"$US" -v e="$scr" -v a="$asp" '$1 == "B" && $2 == e && $3 == a { c++ } END { print c + 0 }' "$TSV")
      [ "$cnt" = 1 ] || fail $ac "$scr × $asp : $cnt ligne(s) (attendu 1)"
    done
  done
  while IFS= read -r line; do
    scr=$(printf '%s' "$line" | awk -F"$US" '{ print $2 }'); asp=$(printf '%s' "$line" | awk -F"$US" '{ print $3 }')
    verdict=$(printf '%s' "$line" | awk -F"$US" '{ print $4 }'); proof=$(printf '%s' "$line" | awk -F"$US" '{ print $5 }')
    ref=$(printf '%s' "$line" | awk -F"$US" '{ print $6 }')
    case "$verdict" in conforme|"écart : "*) ;; *) fail $ac "$scr × $asp verdict « $verdict » invalide" ;; esac
    check_cites $ac "$scr × $asp" "$proof"
    [ "$VALID" -ge 1 ] || fail $ac "$scr × $asp sans preuve locale chemin:ligne valide"
    [ -n "$ref" ] || fail $ac "$scr × $asp référence vide"
  done < <(awk -F"$US" '$1 == "B" && $2 != "Écran" && $2 !~ /^-+$/' "$TSV")
  expectations $ac B "$EXPECT_B"
}

# ---- main ----------------------------------------------------------------------
run() {  # run <AC-n> <function>
  local before=$BAD
  "$2"
  [ "$BAD" = "$before" ] && echo "PASS $1"
  return 0
}

target="${1:-all}"
case "$target" in
  AC-1) run AC-1 ac1 ;;
  AC-2) run AC-2 ac2 ;;
  AC-3) run AC-3 ac3 ;;
  AC-4) run AC-4 ac4 ;;
  AC-38) run AC-38 ac38 ;;
  all) run AC-1 ac1; run AC-2 ac2; run AC-3 ac3; run AC-4 ac4; run AC-38 ac38 ;;
  *) echo "usage: $0 [AC-1|AC-2|AC-3|AC-4|AC-38|all]" >&2; exit 2 ;;
esac
[ "$BAD" = 0 ]
