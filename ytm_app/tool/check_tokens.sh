#!/usr/bin/env bash
#
# The spec's "Done means" gate 2, plus the repo's own check_tokens.ps1 rules:
#
#   A grep for hex colors, Icons., BackdropFilter and numeric font sizes outside
#   lib/theme/ and GlassSurface returns nothing.
#
# Usage:  bash tool/check_tokens.sh   (exits non-zero when a violation is found)

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

GLASS="lib/ui/glass_surface.dart"

mapfile -t ALL < <(find lib -name '*.dart' | sort)
NON_THEME=()
NON_THEME_NO_GLASS=()
for f in "${ALL[@]}"; do
  case "$f" in
    lib/theme/*) ;;
    *)
      NON_THEME+=("$f")
      [ "$f" = "$GLASS" ] || NON_THEME_NO_GLASS+=("$f")
      ;;
  esac
done

violations=0

check() {
  local desc="$1" re="$2" exclude="${3:-}"
  shift 3 || true
  [ "$#" -eq 0 ] && return 0
  local out
  out=$(grep -nE "$re" "$@" 2>/dev/null || true)
  if [ -n "$exclude" ]; then
    out=$(printf '%s\n' "$out" | grep -vE "$exclude" || true)
  fi
  if [ -n "$out" ]; then
    printf 'VIOLATION: %s\n%s\n\n' "$desc" "$out"
    violations=$((violations + 1))
  fi
}

big_re='0x[0-9A-Fa-f]{8}'
color_re='Color\(|Color\.fromRGBO\('
colors_re='Colors\.'
font_re='fontSize:[[:space:]]*[0-9]'
textstyle_re='TextStyle\('
radius_re='BorderRadius\.circular\('
icons_re='\bIcons\.'
blur_re='BackdropFilter'

check "hex color outside lib/theme/" "$big_re" "" "${NON_THEME[@]}"
check "Color()/Color.fromRGBO() outside lib/theme/" "$color_re" "" "${NON_THEME[@]}"
check "Colors. constant outside lib/theme/ (Colors.transparent allowed in GlassSurface)" \
  "$colors_re" "Colors\.transparent" "${NON_THEME[@]}"
check "numeric fontSize outside lib/theme/" "$font_re" "" "${NON_THEME[@]}"
check "TextStyle() outside lib/theme/" "$textstyle_re" "" "${NON_THEME[@]}"
check "BorderRadius.circular() outside lib/theme/ and GlassSurface" "$radius_re" "" "${NON_THEME_NO_GLASS[@]}"
check "Material Icons. outside lib/theme/" "$icons_re" "" "${NON_THEME[@]}"
check "BackdropFilter outside GlassSurface" "$blur_re" "" "${NON_THEME_NO_GLASS[@]}"

if [ "$violations" -gt 0 ]; then
  printf 'Total violations: %d\n' "$violations"
  exit 1
fi

printf 'No design-token violations found.\n'
