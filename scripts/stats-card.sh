#!/usr/bin/env bash
#
# stats-card.sh - Draw card.svg and card-dark.svg, the statistics card of
# the README, from the event journal, see Statistics in docs/WORKFLOW.md

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd gawk
export LC_ALL=C

readonly USAGE="Usage: stats-card.sh --journal <file> --packages <dir> --name <repository> --out <dir>"

declare -A ARG=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --journal | --packages | --name | --out)
      if [[ -z "${2:-}" ]]; then
        log_err "$1 needs a value"
        exit 1
      fi
      ARG[${1#--}]="$2"
      shift 2
      ;;
    *)
      log_err "Unknown option: $1"
      exit 1
      ;;
  esac
done
for key in journal packages name out; do
  if [[ -z "${ARG[$key]:-}" ]]; then
    log_err "$USAGE"
    exit 1
  fi
done

DATE="${AURTOMATOR_STATS_DATE:-$(date -u +%F)}"
if [[ ! "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ || "$(date -u -d "$DATE" +%F 2>/dev/null)" != "$DATE" ]]; then
  log_err "AURTOMATOR_STATS_DATE is not a day of the form YYYY-MM-DD: ${DATE@Q}"
  exit 1
fi
if [[ ! "${ARG[name]}" =~ ^[A-Za-z0-9._-]{1,100}$ ]]; then
  log_err "--name is not the name of a GitHub repository: ${ARG[name]@Q}"
  exit 1
fi
for key in packages out; do
  if [[ ! -d "${ARG[$key]}" ]]; then
    log_err "--$key is not a directory: ${ARG[$key]}"
    exit 1
  fi
done
if [[ ! -f "${ARG[journal]}" ]]; then
  log_err "--journal is not a file: ${ARG[journal]}"
  exit 1
fi

pkg_count=0
for file in "${ARG[packages]}"/*.yml; do
  name="${file##*/}"
  [[ -f "$file" && "${name%.yml}" =~ ^[A-Za-z0-9@_+][A-Za-z0-9@._+-]*$ ]] || continue
  ((++pkg_count))
done
numbers=$(stats_numbers "${ARG[journal]}" "$DATE") || exit 1

# Background, border, text, muted, faint, the five levels of a cell, red
# and green
readonly LIGHT="#ffffff #d0d7de #1f2328 #59636e #818b98 #eff2f5 #c4e3f5 #74bde6 #1793d1 #0e6a9e #cf222e #1a7f37"
readonly DARK="#0d1117 #3d444d #f0f6fc #9198a1 #656c76 #151b23 #0f3a52 #145c86 #1793d1 #62bdf0 #f85149 #3fb950"

# The Arch Linux logo of Simple Icons
readonly ARCH="M11.39.605C10.376 3.092 9.764 4.72 8.635 7.132c.693.734 1.543 1.589 2.923 2.554-1.484-.61-2.496-1.224-3.252-1.86C6.86 10.842 4.596 15.138 0 23.395c3.612-2.085 6.412-3.37 9.021-3.862a6.61 6.61 0 01-.171-1.547l.003-.115c.058-2.315 1.261-4.095 2.687-3.973 1.426.12 2.534 2.096 2.478 4.409a6.52 6.52 0 01-.146 1.243c2.58.505 5.352 1.787 8.914 3.844-.702-1.293-1.33-2.459-1.929-3.57-.943-.73-1.926-1.682-3.933-2.713 1.38.359 2.367.772 3.137 1.234-6.09-11.334-6.582-12.84-8.67-17.74zM22.898 21.36v-.623h-.234v-.084h.562v.084h-.234v.623h.331v-.707h.142l.167.5.034.107a2.26 2.26 0 01.038-.114l.17-.493H24v.707h-.091v-.593l-.206.593h-.084l-.205-.602v.602h-.091"

# Reads the lines of stats_numbers. A heatmap column is a week from Sunday,
# and the last one ends on the day of the card.
# shellcheck disable=SC2016
readonly CARD='
function month(t) { return strftime("%m", t, 1) + 0 }
function plural(n, one, many) { return n == 1 ? one : many }
function level(c) { return c == 0 ? 0 : c == 1 ? 1 : c <= 3 ? 2 : c <= 5 ? 3 : 4 }
BEGIN {
  split(palette, P, " ")
  bg = P[1]; bd = P[2]; tx = P[3]; mu = P[4]; fa = P[5]; red = P[11]; grn = P[12]
  for (l = 0; l <= 4; l++) cell[l] = P[6 + l]
  split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", MON, " ")
  today = mktime(substr(date, 1, 4) " " substr(date, 6, 2) " " substr(date, 9, 2) " 0 0 0", 1)
  days = 52 * 7 + strftime("%w", today, 1) + 1
}
$1 ~ /^(pushes|packages|added|failed)$/ { n[$1, 1] = $2; n[$1, 2] = $3; n[$1, 3] = $4 }
$1 == "failing" { failing = $2 }
$1 == "first" { first = $2 }
$1 == "day" { on[$2] = $3 }
END {
  if (first == "") first = 0
  H = 356
  printf "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"680\" height=\"%d\" viewBox=\"0 0 680 %d\" font-family=\"-apple-system,BlinkMacSystemFont,%sSegoe UI%s,Helvetica,Arial,sans-serif\">\n", H, H, "\047", "\047"
  printf "<rect x=\"0.5\" y=\"0.5\" width=\"679\" height=\"%d\" rx=\"6\" fill=\"%s\" stroke=\"%s\"/>\n", H - 1, bg, bd
  printf "<svg x=\"24\" y=\"18\" width=\"22\" height=\"22\" viewBox=\"0 0 24 24\"><path fill=\"#1793d1\" d=\"%s\"/></svg>\n", arch
  # A longer name runs into the package count on the right
  if (length(name) > 32) name = substr(name, 1, 30) "..."
  printf "<text x=\"54\" y=\"35\" font-size=\"18\" font-weight=\"600\" fill=\"%s\">%s</text>\n", tx, name
  printf "<text x=\"656\" y=\"35\" font-size=\"14\" text-anchor=\"end\" fill=\"%s\"><tspan font-weight=\"600\" fill=\"%s\">%d</tspan> %s", mu, tx, packages, plural(packages, "package", "packages")
  if (failing > 0) printf " <tspan fill=\"%s\">\302\267 %d failing</tspan>", red, failing
  print "</text>"
  printf "<text x=\"54\" y=\"54\" font-size=\"12\" fill=\"%s\">AUR packages maintained with aurtomator</text>\n", mu
  # The day of the card, so a card no run has drawn again shows its age
  printf "<text x=\"656\" y=\"54\" font-size=\"12\" text-anchor=\"end\" fill=\"%s\">updated %s %d, %s</text>\n", mu, MON[month(today)], strftime("%d", today, 1) + 0, substr(date, 1, 4)

  split("7 30 365", window, " ")
  split("436 546 656", cx, " ")
  for (i = 1; i <= 3; i++) {
    head = window[i] " days"
    if (first < window[i] - 1) {
      t = today - first * 86400
      head = "since " MON[month(t)] " " (strftime("%d", t, 1) + 0)
    }
    printf "<text x=\"%d\" y=\"90\" font-size=\"12\" text-anchor=\"end\" fill=\"%s\">%s</text>\n", cx[i], mu, head
  }
  split("packages pushes added failed", key, " ")
  split("Packages updated|Pushes to AUR|New packages|Failed checks", label, "|")
  color["pushes"] = tx; color["packages"] = tx; color["added"] = grn; color["failed"] = red
  for (j = 1; j <= 4; j++) {
    y = 120 + (j - 1) * 28
    printf "<text x=\"24\" y=\"%d\" font-size=\"14\" fill=\"%s\">%s</text>\n", y, tx, label[j]
    for (i = 1; i <= 3; i++) {
      v = n[key[j], i] + 0
      printf "<text x=\"%d\" y=\"%d\" font-size=\"16\" font-weight=\"600\" text-anchor=\"end\" fill=\"%s\">%d</text>\n", cx[i], y, (v > 0 ? color[key[j]] : fa), v
    }
    printf "<line x1=\"24\" x2=\"656\" y1=\"%d\" y2=\"%d\" stroke=\"%s\" stroke-width=\"0.5\"/>\n", y + 10, y + 10, bd
  }

  gx = 60; gy = 244; labeled = -9
  for (i = 0; i < days; i++) {
    age = days - 1 - i
    col = int(i / 7); row = i % 7
    x = gx + col * 11; y = gy + row * 11
    if (age > first) {
      outline = outline sprintf("<rect x=\"%.1f\" y=\"%.1f\" width=\"8\" height=\"8\" rx=\"1.5\"/>\n", x + 0.5, y + 0.5)
    } else {
      l = level(on[age] + 0)
      group[l] = group[l] sprintf("<rect x=\"%d\" y=\"%d\" width=\"9\" height=\"9\" rx=\"2\"/>\n", x, y)
    }
    if (row == 0) {
      m = month(today - age * 86400)
      if (m != (i >= 7 ? month(today - (age + 7) * 86400) : 0) && col - labeled >= 3) {
        printf "<text x=\"%d\" y=\"%d\" font-size=\"11\" fill=\"%s\">%s</text>\n", x, gy - 6, fa, MON[m]
        labeled = col
      }
    }
  }
  split("Mon Wed Fri", weekday, " ")
  for (r = 1; r <= 3; r++) printf "<text x=\"24\" y=\"%d\" font-size=\"11\" fill=\"%s\">%s</text>\n", gy + (2 * r - 1) * 11 + 8, fa, weekday[r]
  if (outline != "") printf "<g fill=\"none\" stroke=\"%s\">\n%s</g>\n", bd, outline
  for (l = 0; l <= 4; l++) if (l in group) printf "<g fill=\"%s\">\n%s</g>\n", cell[l], group[l]

  year = n["pushes", 3] + 0
  printf "<text x=\"24\" y=\"%d\" font-size=\"12\" fill=\"%s\"><tspan font-weight=\"600\" fill=\"%s\">%d</tspan> %s in the last year</text>\n", H - 14, mu, tx, year, plural(year, "push", "pushes")
  lx = 656 - 34 - 5 * 11
  printf "<text x=\"%d\" y=\"%d\" font-size=\"11\" text-anchor=\"end\" fill=\"%s\">Less</text>\n", lx - 6, H - 14, fa
  for (l = 0; l <= 4; l++) printf "<rect x=\"%d\" y=\"%d\" width=\"9\" height=\"9\" rx=\"2\" fill=\"%s\"/>\n", lx + l * 11, H - 23, cell[l]
  printf "<text x=\"656\" y=\"%d\" font-size=\"11\" text-anchor=\"end\" fill=\"%s\">More</text>\n", H - 14, fa
  print "</svg>"
}'

out="${ARG[out]}"
trap 'rm -f -- "$out/card.svg.tmp" "$out/card-dark.svg.tmp"' EXIT
for theme in light dark; do
  palette="$LIGHT" file=card.svg
  [[ "$theme" == light ]] || palette="$DARK" file=card-dark.svg
  gawk -v date="$DATE" -v name="${ARG[name]}" -v packages="$pkg_count" -v palette="$palette" \
    -v arch="$ARCH" "$CARD" <<<"$numbers" >"$out/$file.tmp"
done
mv -f -- "$out/card.svg.tmp" "$out/card.svg"
mv -f -- "$out/card-dark.svg.tmp" "$out/card-dark.svg"
log_ok "Drew the statistics card of ${ARG[name]} for $DATE"
