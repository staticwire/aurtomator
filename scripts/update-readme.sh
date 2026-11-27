#!/usr/bin/env bash
#
# update-readme.sh - Write the badges and the package table of README.md between the markers
# <!-- BADGES:START -->, <!-- BADGES:END -->, <!-- PACKAGES:START --> and <!-- PACKAGES:END -->
#
# Usage: ./scripts/update-readme.sh
#
# Exits with 3 when it leaves README.md as it is for its shape: a link, no file or broken markers.
# The run-as-builder action turns that code into a warning, so the run goes on.

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd yq

readonly README="${AURTOMATOR_DATA_DIR}/README.md"
readonly STATUS_DIR="${AURTOMATOR_DATA_DIR}/.status"

if [[ -L "$README" ]]; then
  log_err "README.md is a symbolic link, so the update would copy the text of the file it points to into README.md"
  exit 3
fi
if [[ ! -f "$README" ]]; then
  log_err "README.md not found"
  exit 3
fi

# Fixed names such as README.md.tmp can be links that a commit added
new_readme="" new_page=""
trap 'rm -f ${new_readme:+"$new_readme"} ${new_page:+"$new_page"}' EXIT

# Move file $1, the new text of README.md, over README.md with the mode README.md has
replace_readme() {
  chmod --reference="$README" "$1"
  mv "$1" "$README"
}

readonly BADGES_START="<!-- BADGES:START -->"
readonly BADGES_END="<!-- BADGES:END -->"
readonly PKG_START="<!-- PACKAGES:START -->"
readonly PKG_END="<!-- PACKAGES:END -->"

# Succeeds when the README holds markers $1 and $2 once each, on lines of their own, start first:
# a missing end marker would drop the rest of the README, a second one copy it into itself
check_markers() {
  local marker count
  for marker in "$1" "$2"; do
    count=$(grep -cxF -- "$marker" "$README" || true)
    if ((count == 0)); then
      log_err "No $marker marker found in README.md"
      return 1
    elif ((count > 1)); then
      log_err "README.md has the $marker line $count times, it needs it once"
      return 1
    fi
  done
  if (($(grep -nxF -- "$2" "$README" | cut -d: -f1) < $(grep -nxF -- "$1" "$README" | cut -d: -f1))); then
    log_err "README.md has $2 above $1"
    return 1
  fi
}

pkg_files=()
# Links count wherever they lead, since the jobs hand builder each one as a link to itself
for pkg_file in "${AURTOMATOR_DATA_DIR}"/packages/*.yml; do
  [[ -f "$pkg_file" || -L "$pkg_file" ]] || continue
  pkg_files+=("$pkg_file")
done
# Repositories made from the template keep their setup steps until their first
# package, and the aurtomator README stays as it is
if ((${#pkg_files[@]} == 0)); then
  log_info "packages/ holds no package, README.md stays as it is"
  exit 0
fi

check_markers "$PKG_START" "$PKG_END" || exit 3
has_badges=false
if grep -qxF -- "$BADGES_START" "$README"; then
  check_markers "$BADGES_START" "$BADGES_END" || exit 3
  has_badges=true
  # The badge rewrite drops the lines between its markers, so a marker of the table there would go
  line_of() { grep -nxF -- "$1" "$README" | cut -d: -f1; }
  if (($(line_of "$BADGES_END") > $(line_of "$PKG_START") && $(line_of "$PKG_END") > $(line_of "$BADGES_START"))); then
    log_err "README.md has a marker of one pair between $BADGES_START and $BADGES_END or between $PKG_START and $PKG_END; keep the two pairs apart"
    exit 3
  fi
fi

# CI names the repo in GITHUB_REPOSITORY, and the data directory there has
# no .git. Otherwise only a GitHub origin names it, never a local path.
repo_url=""
if [[ "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$ ]]; then
  repo_url="$GITHUB_REPOSITORY"
else
  origin_url=$(git -C "$AURTOMATOR_DATA_DIR" remote get-url origin 2>/dev/null || true)
  if [[ "$origin_url" =~ [/@]github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+) ]]; then
    repo_url="${BASH_REMATCH[1]%.git}"
  fi
fi

# === BADGES ===

if [[ "$has_badges" == true ]]; then
  badges=""

  if [[ -n "$repo_url" ]]; then
    badges+="[![Validate packages](https://github.com/${repo_url}/actions/workflows/validate.yml/badge.svg)](https://github.com/${repo_url}/actions/workflows/validate.yml) "
    badges+="[![Check AUR Package Updates](https://github.com/${repo_url}/actions/workflows/check-updates.yml/badge.svg)](https://github.com/${repo_url}/actions/workflows/check-updates.yml) "
  fi

  # Names the project itself, so it does not follow AURTOMATOR_UPSTREAM;
  # 1793d1 is the blue of the Arch Linux logo
  badges+="[![maintained with aurtomator](https://img.shields.io/badge/maintained%20with-aurtomator-1793d1?logo=archlinux&logoColor=white)](https://github.com/staticwire/aurtomator)"

  new_readme=$(mktemp "${README}.XXXXXX")
  {
    sed -n "0,/^${BADGES_START}\$/p" "$README"
    echo "$badges"
    sed -n "/^${BADGES_END}\$/,\$p" "$README"
  } >"$new_readme"
  replace_readme "$new_readme"
  log_ok "Badges updated (repo: ${repo_url:-unknown})"
fi

# === PACKAGES ===

# The table is HTML, since a Markdown table cell takes no attributes. nowrap
# keeps Strategy, Updated and Status on one line, and the package name wraps.
table_row() {
  printf '\n<tr><td>%s</td><td>%s</td><td nowrap>%s</td><td nowrap>%s</td><td nowrap>%s</td></tr>' "$@"
}

# Print value $1 as HTML text on one line, for YAML that reached the branch without the
# validator: a blank line would end the HTML block of the table
html_text() {
  local text
  text=$(printf '%s' "$1" | LC_ALL=C tr '\001-\037\177' ' ')
  text=${text//'&'/'&amp;'}
  text=${text//'<'/'&lt;'}
  text=${text//'>'/'&gt;'}
  printf '%s' "${text//'"'/'&quot;'}"
}

# The cards stats-card.sh draws in stats/, as a link to the journal. GitHub
# shows the dark card in its dark theme.
readonly CARD='<a href="stats/events.csv">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="stats/card-dark.svg">
  <img width="100%" alt="Packages updated, pushes to AUR, new packages and failed checks over 7, 30 and 365 days" src="stats/card.svg">
</picture>
</a>'

table_rows=""
table_header=$'<table>\n<tr><th>Package</th><th>Version</th><th>Strategy</th><th>Updated</th><th>Status</th></tr>'
# The rows, names, status marks and the rows that need attention, for a README past its limit
row_list=() name_list=() mark_list=() attention=()

pkg_count=0
for pkg_file in "${pkg_files[@]}"; do
  name=${pkg_file##*/}
  name=${name%.yml}
  raw=""
  # Rows go by the file name, as the statuses do. The runs fail a link and a YAML whose name is
  # not its file name, a YAML that yq cannot read among them.
  if [[ -L "$pkg_file" ]] || ! package_name "$pkg_file" >/dev/null 2>&1; then
    (LC_ALL=C && [[ "$name" =~ ^[a-z0-9][a-z0-9.+_-]*$ ]]) || continue
    current="-" strategy="-" last_updated="-" status="❌ failed"
  else
    current=$(pkg_get "$pkg_file" '.current // "-"')
    strategy=$(pkg_get "$pkg_file" .strategy)
    last_updated=$(pkg_get "$pkg_file" '.last_updated // "-"')
    # arch_out values that are no map count as none, as in the check
    arches_out=$(pkg_get "$pkg_file" '.arch_out // {} | keys | join(" ")' 2>/dev/null) || arches_out=""
    status_file="${STATUS_DIR}/${name}"
    if [[ -f "$status_file" ]]; then
      raw=$(cat "$status_file")
      status=$(status_label "$raw" "$arches_out" "$current")
    elif [[ "$current" == "-" || "$current" == "null" ]]; then
      status="✨ new"
      current="-"
    else
      status="✅ tracking"
    fi
  fi

  link="<a href=\"https://aur.archlinux.org/pkgbase/$(html_text "$name")\">$(html_text "$name")</a>"
  row=$(table_row "$link" "$(html_text "$current")" "$(html_text "$strategy")" \
    "$(html_text "$last_updated")" "$(html_text "$status")")
  table_rows+=$row
  row_list+=("$row")
  name_list+=("$name")
  mark_list+=("${status%% *}")
  # Failed, waiting and updated packages, and those without some arches
  case "$raw" in
    check_failed:* | update_failed:* | held:* | pending:* | updated:* | downgrade:* | rebuilt:* | arch_added:*)
      attention+=("$row")
      ;;
    *) [[ "$status" != "❌ failed" && "$status" != "⚠️ "* ]] || attention+=("$row") ;;
  esac
  ((pkg_count++)) || true
done

# The version of aurtomator, and the newer release the check run found
version_line=""
version=$(aurtomator_version)
if [[ -n "$version" ]]; then
  upstream=""
  [[ ! -f "${STATUS_DIR}/_upstream" ]] || upstream=$(<"${STATUS_DIR}/_upstream")
  version_line="aurtomator ${version}"
  if [[ "$upstream" =~ ^newer:\ ([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    version_line+=" ([${BASH_REMATCH[1]} available](https://github.com/${AURTOMATOR_UPSTREAM}/releases/tag/v${BASH_REMATCH[1]}))"
  fi
fi

# Write README.md with text $1 between the package markers
write_readme() {
  [[ -z "$new_readme" ]] || rm -f -- "$new_readme"
  new_readme=$(mktemp "${README}.XXXXXX")
  {
    sed -n "0,/^${PKG_START}\$/p" "$README"
    printf '%s\n' "$1${version_line:+$'\n\n'$version_line}"
    sed -n "/^${PKG_END}\$/,\$p" "$README"
  } >"$new_readme"
}

# GitHub cuts a README past 500 KiB. Past the limit, the table goes to pages table/<letter>.md,
# and the README keeps the packages that need attention.
readonly PAGES="${AURTOMATOR_DATA_DIR}/table"

# Write rows $3... of letter $1 to table/<letter>.md, and the rows past limit $2 in bytes to
# table/<letter>-2.md and on; each page goes into pages, and its link into links
write_letter_pages() {
  local LC_ALL=C letter=$1 max=$2 part=1 rows="" row name title
  shift 2
  for row in "$@" ""; do
    if [[ -n "$rows" ]] && { [[ -z "$row" ]] || ((${#rows} + ${#row} + ${#table_header} + 200 > max)); }; then
      name=$letter title=$letter
      ((part == 1)) || name+="-$part" title+=", part $part"
      new_page=$(mktemp "$PAGES/.$name.md.XXXXXX")
      printf '# Packages: %s\n\n[Back to the README](../README.md)\n\n%s%s\n</table>\n' "$title" "$table_header" \
        "$rows" >"$new_page"
      chmod --reference="$README" "$new_page"
      mv -f -- "$new_page" "$PAGES/$name.md"
      new_page=""
      pages["$name.md"]=1
      links+=" [$name](table/$name.md)"
      part=$((part + 1)) rows=""
    fi
    rows+=$row
  done
}

readme_max=${AURTOMATOR_README_MAX_KIB:-400}
if [[ ! "$readme_max" =~ ^[1-9][0-9]{0,5}$ ]]; then
  log_err "AURTOMATOR_README_MAX_KIB must be a number of KiB from 1: ${readme_max@Q}"
  exit 1
fi
write_readme "${CARD}"$'\n\n'"${table_header}${table_rows}"$'\n</table>'
declare -A pages=()
if (($(wc -c <"$new_readme") > readme_max * 1024)); then
  if [[ -L "$PAGES" || (-e "$PAGES" && ! -d "$PAGES") ]]; then
    log_err "table is a link or no directory, so the pages of the package table have no place"
    exit 1
  fi
  mkdir -p "$PAGES"
  for page in "$PAGES"/*.md; do
    file=${page##*/}
    if [[ "$file" =~ ^(0-9|[a-z])(-[1-9][0-9]*)?\.md$ ]] && [[ -L "$page" || ! -f "$page" ]]; then
      log_err "table/$file is a link or no file, so the pages of the package table have no place"
      exit 1
    fi
  done
  declare -A page_rows=() counts=()
  marks=()
  for i in "${!row_list[@]}"; do
    letter=${name_list[i]:0:1}
    [[ "$letter" != [0-9] ]] || letter=0-9
    page_rows[$letter]+=" $i"
    [[ -n "${counts[${mark_list[i]}]:-}" ]] || marks+=("${mark_list[i]}")
    counts[${mark_list[i]}]=$((${counts[${mark_list[i]}]:-0} + 1))
  done
  summary="$pkg_count packages:"
  for mark in "${marks[@]}"; do
    summary+=" $mark ${counts[$mark]},"
  done
  links="Every package:"
  for letter in 0-9 {a..z}; do
    [[ -n "${page_rows[$letter]:-}" ]] || continue
    read -ra letter_rows <<<"${page_rows[$letter]}"
    for i in "${!letter_rows[@]}"; do
      letter_rows[i]=${row_list[letter_rows[i]]}
    done
    write_letter_pages "$letter" "$((readme_max * 1024))" "${letter_rows[@]}"
  done
  block="${CARD}"$'\n\n'"${summary%,}"
  if ((${#attention[@]} > 0)); then
    # Runs where most packages fail list most rows here, so the rows stop where the limit would pass
    write_readme "$block"$'\n\n'"$links"
    room=$((readme_max * 1024 - $(wc -c <"$new_readme") - ${#table_header} - 200))
    rows="" kept=0
    for row in "${attention[@]}"; do
      (($(LC_ALL=C && printf '%s' "$rows$row" | wc -c) <= room)) || break
      rows+=$row
      kept=$((kept + 1))
    done
    block+=$'\n\nNeeds attention:\n\n'"${table_header}${rows}"$'\n</table>'
    ((kept == ${#attention[@]})) || block+=$'\n\n'"$((${#attention[@]} - kept)) more packages need attention, in the pages below"
  fi
  write_readme "$block"$'\n\n'"$links"
fi
replace_readme "$new_readme"
# Pages and parts of letters without packages, and every page under the limit, go
if [[ -d "$PAGES" && ! -L "$PAGES" ]]; then
  for page in "$PAGES"/*.md; do
    file=${page##*/}
    if [[ -f "$page" && ! -L "$page" && "$file" =~ ^(0-9|[a-z])(-[1-9][0-9]*)?\.md$ && -z "${pages[$file]:-}" ]]; then
      rm -f -- "$page"
    fi
  done
fi
log_ok "README.md updated ($pkg_count packages)"
