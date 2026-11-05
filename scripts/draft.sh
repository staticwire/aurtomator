#!/usr/bin/env bash
#
# draft.sh - Write packages/<pkgbase>.yml from the .SRCINFO of the AUR
# package, then validate and check it. docs/WORKFLOW.md 7.2 has the rules.

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd git
require_cmd yq

# aurtomator.sh of the template sets AURTOMATOR_RUNNER to the path it was run by
if [[ -n "${AURTOMATOR_RUNNER:-}" ]]; then
  readonly USAGE="Usage: $AURTOMATOR_RUNNER draft <pkgbase>"
else
  readonly USAGE="Usage: $0 <pkgbase>"
fi

# The name reaches a URL and a path, so it has the form of a package name
if [[ $# -ne 1 || ! "$1" =~ ^[A-Za-z0-9@_+][A-Za-z0-9@._+-]*$ ]]; then
  echo "$USAGE" >&2
  exit 1
fi
readonly NAME="$1"
readonly FILE="${AURTOMATOR_DATA_DIR}/packages/${NAME}.yml"
if [[ -e "$FILE" || -L "$FILE" ]]; then
  log_err "packages/${NAME}.yml exists already"
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_TERMINAL_PROMPT=0
# A checkout would apply the attributes and filters of the AUR repository
aur_clone "https://aur.archlinux.org/${NAME}.git" "$tmp/aur" --depth 1 --no-checkout -q >&2 || exit 1
aur_export "$tmp/aur" "$tmp/files" || exit 1
info_file="$tmp/files/.SRCINFO"
# The AUR answers an unknown name with an empty repository
if [[ ! -e "$info_file" && ! -L "$info_file" ]]; then
  log_err "No AUR package $NAME"
  exit 1
fi
if [[ -L "$info_file" || ! -f "$info_file" ]]; then
  log_err "The .SRCINFO of $NAME is no regular file"
  exit 1
fi

# The pkgbase section ends at the first pkgname. Every value stays text.
PKGVER="" EPOCH="" URL="" SOURCES=()
line_re='^[[:space:]]*([a-z0-9_]+) = (.*)$'
mapfile -t lines <"$info_file"
for line in "${lines[@]}"; do
  [[ "$line" =~ $line_re ]] || continue
  case "${BASH_REMATCH[1]}" in
    pkgname) break ;;
    pkgver) PKGVER="${BASH_REMATCH[2]}" ;;
    epoch) EPOCH="${BASH_REMATCH[2]}" ;;
    url) URL="${BASH_REMATCH[2]}" ;;
    source | source_*) SOURCES+=("${BASH_REMATCH[2]}") ;;
  esac
done
if [[ -n "$PKGVER" ]] && ! validate_pkgver "$PKGVER"; then
  log_err "The .SRCINFO of $NAME has a pkgver that current cannot hold, so no YAML is written"
  exit 1
fi

STRATEGY="" FIELDS=()

# Set git-latest of type $1 for a -git package, with the branch of the
# source, else strategy $2. The fields after them go to both.
git_source() {
  local type="$1" tag_strategy="$2"
  shift 2
  if [[ "$NAME" == *-git ]]; then
    STRATEGY=git-latest FIELDS=("type=$type" "$@")
    [[ -z "$branch" ]] || FIELDS+=("branch=$branch")
  else
    STRATEGY="$tag_strategy" FIELDS=("$@")
  fi
}

# Set kde-tarball from tarball URL $1 named after pkgver. Its path is its
# directory without src/ and without a directory of a version or a series.
kde_source() {
  local rest="${1#https://download.kde.org/}" file project path
  local -a dirs
  [[ "$1" == https://download.kde.org/*/* ]] || return 1
  file="${rest##*/}"
  [[ "$file" == ?*-"$PKGVER".tar.xz ]] || return 1
  project="${file%-"$PKGVER".tar.xz}"
  IFS=/ read -ra dirs <<<"${rest%/*}"
  if ((${#dirs[@]} > 0)) && [[ "${dirs[-1]}" == src ]]; then
    unset 'dirs[-1]'
  fi
  if ((${#dirs[@]} > 0)) && [[ "${dirs[-1]}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    unset 'dirs[-1]'
  fi
  ((${#dirs[@]} > 0)) || return 1
  path=$(IFS=/ && printf '%s' "${dirs[*]}")
  STRATEGY=kde-tarball FIELDS=()
  [[ "$project" == "$NAME" ]] || FIELDS+=("project=$project")
  [[ "$path" == "stable/$project" ]] || FIELDS+=("path=$path")
}

# Set the strategy from source $1, or fail when no rule matches it. A local
# file and a signature match none.
from_source() {
  local src="${1#*::}" fragment="" branch=""
  local repo='([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)'
  local group='([A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+)'
  if [[ "$src" == *'#'* ]]; then
    fragment="${src#*#}"
  fi
  if [[ "$fragment" =~ ^branch=(.+)$ ]]; then
    branch="${BASH_REMATCH[1]}"
  fi
  src="${src%%[#?]*}"
  src="${src%/}"
  [[ ! "$src" =~ \.(sig|asc|sign)$ ]] || return 1
  if [[ "$src" =~ ^https://github\.com/$repo/releases/download/ ]]; then
    STRATEGY=github-release FIELDS=("project=${BASH_REMATCH[1]}")
  elif [[ "$src" =~ ^https://github\.com/$repo/archive/ ]]; then
    STRATEGY=github-tag FIELDS=("project=${BASH_REMATCH[1]}")
  elif [[ "$src" =~ ^git\+https://github\.com/$repo$ ]]; then
    git_source github github-tag "project=${BASH_REMATCH[1]%.git}"
  elif [[ "$src" =~ ^https://([A-Za-z0-9.-]+)/$group/-/archive/ ]]; then
    STRATEGY=gitlab-tag FIELDS=("host=${BASH_REMATCH[1]}" "project=${BASH_REMATCH[2]}")
  elif [[ "$src" =~ ^git\+https://gitlab\.com/$group$ ]]; then
    git_source gitlab gitlab-tag host=gitlab.com "project=${BASH_REMATCH[1]%.git}"
  elif [[ "$src" =~ ^https://codeberg\.org/$repo/releases/download/ ]]; then
    STRATEGY=gitea-release FIELDS=(host=codeberg.org "project=${BASH_REMATCH[1]}")
  elif [[ "$src" =~ ^https://codeberg\.org/$repo/archive/ ]]; then
    STRATEGY=gitea-tag FIELDS=(host=codeberg.org "project=${BASH_REMATCH[1]}")
  elif [[ "$src" =~ ^git\+(https://.+)$ ]]; then
    git_source git git-tag "url=${BASH_REMATCH[1]}"
  elif [[ "$src" =~ ^https://(files\.pythonhosted\.org|pypi\.io)/packages/source/[^/]/([A-Za-z0-9_.-]+)/ ]]; then
    STRATEGY=pypi FIELDS=("registry=${BASH_REMATCH[2]}")
  elif [[ "$src" =~ ^https://registry\.npmjs\.org/((@[A-Za-z0-9_.-]+/)?[A-Za-z0-9_.-]+)/-/ ]]; then
    STRATEGY=npm FIELDS=("registry=${BASH_REMATCH[1]}")
  elif [[ "$src" =~ ^https://(static\.crates\.io/crates|crates\.io/api/v1/crates)/([A-Za-z0-9_-]+)/ ]]; then
    STRATEGY=crates FIELDS=("registry=${BASH_REMATCH[2]}")
  else
    kde_source "$src"
  fi
}

# Set a tag strategy from the url $1 of the package, or fail
from_url() {
  local url="${1%%[#?]*}" project
  url="${url%/}"
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(/|$) ]]; then
    STRATEGY=github-tag FIELDS=("project=${BASH_REMATCH[1]%.git}")
  elif [[ "$url" =~ ^https://codeberg\.org/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(/|$) ]]; then
    STRATEGY=gitea-tag FIELDS=(host=codeberg.org "project=${BASH_REMATCH[1]%.git}")
  elif [[ "$url" == https://gitlab.com/* ]]; then
    project="${url#https://gitlab.com/}"
    project="${project%%/-/*}"
    project="${project%.git}"
    [[ "$project" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+$ ]] || return 1
    STRATEGY=gitlab-tag FIELDS=(host=gitlab.com "project=$project")
  else
    return 1
  fi
}

# Print the text with each control byte as ?, since the AUR package sets it
# and the terminal would act on such a byte
shown() {
  printf '%s' "${1//[[:cntrl:]]/?}"
}

origin=""
for source in "${SOURCES[@]}"; do
  if from_source "$source"; then
    origin="${source#*::}"
    break
  fi
done
if [[ -z "$origin" ]] && from_url "$URL"; then
  origin="the url $URL"
fi
if [[ -z "$origin" ]]; then
  log_err "No rule matches the url or a source of ${NAME}:"
  printf '  url: %s\n' "$(shown "$URL")" >&2
  for source in "${SOURCES[@]}"; do
    printf '  source: %s\n' "$(shown "$source")" >&2
  done
  if [[ -n "${AURTOMATOR_RUNNER:-}" ]]; then
    log_info "Write it from the sample: $AURTOMATOR_RUNNER sample > packages/${NAME}.yml"
  else
    log_info "Write it from the sample: cp ${AURTOMATOR_DIR}/packages/example.yml.sample ${AURTOMATOR_DATA_DIR}/packages/${NAME}.yml"
  fi
  exit 1
fi
if [[ -n "$EPOCH" && "$EPOCH" != 0 ]]; then
  warn_epoch "$(shown "$EPOCH")"
fi

# yq takes every value from the environment, so it stays a string
VALUE="$NAME" yq -n '.name = strenv(VALUE)' >"$tmp/draft.yml"
VALUE="$STRATEGY" yq -i '.strategy = strenv(VALUE)' "$tmp/draft.yml"
for field in "${FIELDS[@]}"; do
  VALUE="${field#*=}" yq -i ".upstream.${field%%=*} = strenv(VALUE)" "$tmp/draft.yml"
done
if [[ -n "$PKGVER" ]]; then
  VALUE="$PKGVER" yq -i '.current = strenv(VALUE)' "$tmp/draft.yml"
fi
mkdir -p "${AURTOMATOR_DATA_DIR}/packages"
mv "$tmp/draft.yml" "$FILE"
log_ok "packages/${NAME}.yml: $STRATEGY from $(shown "$origin")"
sed 's/^/  /' "$FILE" >&2

if ! "${AURTOMATOR_DIR}/scripts/validate-pkg.sh" "$NAME" || ! "${AURTOMATOR_DIR}/scripts/check-update.sh" "$NAME"; then
  log_err "Fix packages/${NAME}.yml, or delete it"
  exit 1
fi
