#!/usr/bin/env bash
#
# issue.sh - The texts of the issues of the workflow, and the hosts whose failed checks share one
#
# Sourced by lib.sh.

# Body of the issue of a newer release of aurtomator, from _upstream file $1, for run URL $2
upstream_issue_body() {
  local release setup
  release=$(<"$1")
  release="${release#newer: }"
  # aurtomator.dev serves staticwire/aurtomator; a fork gets the page in its repository
  setup="https://aurtomator.dev/setup/#the-calling-workflows"
  if [ "$AURTOMATOR_UPSTREAM" != staticwire/aurtomator ]; then
    setup="https://github.com/${AURTOMATOR_UPSTREAM}/blob/main/site/src/content/docs/setup.md#the-calling-workflows"
  fi
  # shellcheck disable=SC2016
  printf 'aurtomator %s is out, and this repository runs %s.\n\nTo update: Insights > Dependency graph > Dependabot > Recent update jobs > Check for updates. Dependabot opens the pull request that moves the pin. The first run on the new pin also updates `aurtomator.sh` to this release.\n\nRelease notes: https://github.com/%s/releases/tag/v%s\nManual update: %s\nRun: %s\n\nAuto-created by update workflow, which closes it once the pin of the calling workflows names this release, or once a newer release is out.\n' "$release" "$(aurtomator_version)" "$AURTOMATOR_UPSTREAM" "$release" "$setup" "$2"
}

# Body of the issue of a held update, or of a published one with a notice. The notes come from
# _alerts, which builder writes, so they go into a code block; clean_statuses checked the version
# Args: $1=status file in .status/, named after the package, $2=URL of the run
# The backticks are Markdown code
# shellcheck disable=SC2016
alert_issue_body() {
  local status package notes state=Published footer="Close it once the edit is done."
  status=$(<"$1")
  package="${1##*/}"
  notes=$(awk -F'\t' -v p="$package" '$1 "" == p "" { sub(/^[^\t]*\t[^\t]*\t/, ""); print }' "${1%/*}/_alerts" 2>/dev/null) || true
  [[ -z "$notes" ]] || notes=$(_code_block "$notes")
  if [[ "$status" == held:* ]]; then
    state=Held
    footer='Publish the version by hand after the edit and set `current` in the package YAML to it. The next run closes this issue.'
  fi
  printf 'Package: `%s`\n%s version: `%s`\nRun: %s\n\n%s\n\nAuto-created by update workflow. %s\n' "$package" "$state" "${status#*: }" "$2" "$notes" "$footer"
}

# Succeeds when _alerts beside status file $1 holds lines of its package and each of them is a
# wait for another package, whose own issue names it
only_waits() {
  [[ -f "${1%/*}/_alerts" ]] || return 1
  awk -F'\t' -v p="${1##*/}" '$1 "" == p "" { n++; if ($2 != "wait") other = 1 } END { exit !(n > 0 && !other) }' "${1%/*}/_alerts"
}

# Print text $1 as a code block, where links, images and mentions do not
# render. Longer texts keep their last $2 characters, 4000 by default.
_code_block() {
  local text="$1" fence='```' limit="${2:-4000}"
  # In the C locale of the job containers, bash counts bytes
  local LC_ALL=C.UTF-8
  if ((${#text} > limit)); then
    text="[first $((${#text} - limit)) characters cut]"$'\n'"${text:${#text}-limit}"
  fi
  # No run of backticks in the text can close a longer fence
  while [[ "$text" == *"$fence"* ]]; do
    fence+='`'
  done
  printf '%s\n%s\n%s\n' "$fence" "$text" "$fence"
}

# Body of the issue of a failed package; the error holds text from upstream, so it goes into a
# code block. Args: $1=status file in .status/, named after the package, $2=URL of the run
failure_issue_body() {
  local status kind
  status=$(<"$1")
  kind="${status%%:*}"
  # The backticks are Markdown code around the package name
  # shellcheck disable=SC2016
  printf 'Package: `%s`\nStatus: %s\nRun: %s\n\n%s\n\nAuto-created by update workflow, which closes it when the package recovers.\n' \
    "${1##*/}" "${kind//_/ }" "$2" "$(_code_block "${status#*: }")"
}

# Comment on an issue that a run closes; the status can hold an error, so it goes into a code
# block. Args: $1=status file in .status/, named after the package, $2=URL of the run
close_comment() {
  local status
  status=$(<"$1")
  # The backticks are Markdown code around the package name
  # shellcheck disable=SC2016
  printf 'The status of `%s` in %s:\n\n%s\n' "${1##*/}" "$2" "$(_code_block "$status")"
}

# The packages of one host whose checks failed in a run share one issue
# from this count on
HOST_ISSUE_MIN=5

# Print the host that the lines of _hosts on stdin give package $1: check-all.sh writes
# the package and the host of the request its failed check failed on, split by a tab
recorded_host() {
  LC_ALL=C awk -F'\t' -v p="$1" '$1 "" == p "" && NF == 2 && $2 ~ /^[a-z0-9.-]+$/ { h = $2 } END { if (h != "") print h }'
}

# Print the host of check_failed status file $1 from _hosts beside it. The server writes part
# of the error, so a URL in the text names no host.
failure_host() {
  local status
  status=$(<"$1")
  if [[ "$status" == check_failed:* && -f "${1%/*}/_hosts" ]]; then
    recorded_host "${1##*/}" <"${1%/*}/_hosts"
  fi
}

# Print each host with HOST_ISSUE_MIN or more failed checks in status
# directory $1, and its packages, on a line split by spaces
failed_hosts() {
  local file host list
  local -A packages=()
  for file in "$1"/*; do
    [[ -f "$file" ]] || continue
    host=$(failure_host "$file")
    [[ -z "$host" ]] || packages[$host]+=" ${file##*/}"
  done
  for host in "${!packages[@]}"; do
    read -ra list <<<"${packages[$host]}"
    if ((${#list[@]} >= HOST_ISSUE_MIN)); then
      printf '%s%s\n' "$host" "${packages[$host]}"
    fi
  done | LC_ALL=C sort
}

# Bodies of host issues stay within this many characters, under the 65536 that GitHub accepts
HOST_BODY_MAX=60000
# Errors in a host issue keep at least this many characters, or their package is only named
HOST_ERROR_MIN=500

# Print the issue body for host $2, run URL $3 and packages $4... of status directory $1. Errors
# share the room that the lines around them leave, and the packages past it are named in one line.
host_issue_body() {
  local dir="$1" host="$2" url="$3" head foot status entry share room cost i k n limit names=""
  local lead=$'\nThis issue has no room for the errors of '
  shift 3
  # In the C locale of the job containers, bash counts bytes
  local LC_ALL=C.UTF-8
  local -a pkgs=("$@") texts=() least=() prefix=(0) suffix=()
  n=$#
  # The backticks are Markdown code around the host and the package names
  # shellcheck disable=SC2016
  head=$(printf 'Host: `%s`\nStatus: check failed\nRun: %s' "$host" "$url")$'\n'
  foot=$'\nAuto-created by update workflow, which closes it when fewer than '"$HOST_ISSUE_MIN"$' packages of the host fail to check.\n'
  room=$((HOST_BODY_MAX - ${#head} - ${#foot}))
  for ((i = 0; i < n; i++)); do
    status=$(<"$dir/${pkgs[i]}")
    texts+=("${status#*: }")
    entry=$(_host_entry "${pkgs[i]}" "${texts[i]}" "$HOST_ERROR_MIN")$'\n'
    least+=("${#entry}")
    prefix+=($((prefix[i] + ${#entry})))
  done
  # The names in backticks and their separators, from each package to the last
  suffix[n]=0
  for ((i = n - 1; i >= 0; i--)); do
    suffix[i]=$((suffix[i + 1] + ${#pkgs[i]} + 4))
  done
  # The most packages whose errors fit beside the line that names all the others
  for ((k = n; k > 0; k--)); do
    cost=${prefix[k]}
    ((k == n)) || cost=$((cost + ${#lead} + suffix[k] + 6))
    ((cost > room)) || break
  done
  if ((k < n)); then
    names=$(_host_names $((room - prefix[k] - 1)) "${pkgs[@]:k}")$'\n'
  fi
  room=$((room - ${#names}))
  printf '%s' "$head"
  for ((i = 0; i < k; i++)); do
    # Each error gets its least size and an equal part of what the least sizes leave
    share=$((least[i] + (room - prefix[k] + prefix[i]) / (k - i)))
    limit=4000
    entry=$(_host_entry "${pkgs[i]}" "${texts[i]}" "$limit")$'\n'
    while ((${#entry} > share && limit > HOST_ERROR_MIN)); do
      limit=$((limit - ${#entry} + share))
      ((limit > HOST_ERROR_MIN)) || limit=$HOST_ERROR_MIN
      entry=$(_host_entry "${pkgs[i]}" "${texts[i]}" "$limit")$'\n'
    done
    printf '%s' "$entry"
    room=$((room - ${#entry}))
  done
  printf '%s%s' "$names" "$foot"
}

# Print the part of a host issue for package $1 with error $2, cut to its last $3 characters
_host_entry() {
  # shellcheck disable=SC2016
  printf '\nPackage: `%s`\n\n%s' "$1" "$(_code_block "$2" "$3")"
}

# Print the line that names packages $2... in at most $1 characters: as many names as fit, then
# the count of the others
_host_names() {
  local room="$1" lead=$'\nThis issue has no room for the errors of ' line count fits=0 sum=0 size i n
  shift
  local LC_ALL=C.UTF-8
  local -a list=("$@")
  n=$#
  # The names in backticks take their length and 2, a separator 2, and " and " 5
  size=$((${#lead} + 1))
  for ((i = 0; i < n; i++)); do
    sum=$((sum + ${#list[i]} + 2))
  done
  if ((size + sum + (n > 1 ? 2 * (n - 2) + 5 : 0) <= room)); then
    fits=$n
  else
    sum=0
    for ((i = 0; i < n; i++)); do
      sum=$((sum + ${#list[i]} + 2))
      # The count, as in " and 12 more packages", takes at most 31 characters
      ((size + sum + 2 * i + 31 <= room)) || break
      fits=$((i + 1))
    done
  fi
  line=""
  for ((i = 0; i < fits; i++)); do
    if ((i == 0)); then
      line="\`${list[i]}\`"
    elif ((i == n - 1)); then
      line+=" and \`${list[i]}\`"
    else
      line+=", \`${list[i]}\`"
    fi
  done
  if ((fits < n)); then
    count="$((n - fits)) packages"
    ((n - fits != 1)) || count="1 package"
    if ((fits > 0)); then
      line+=" and $((n - fits)) more ${count#* }"
    else
      line=$count
    fi
  fi
  printf '%s%s.' "$lead" "$line"
}

# Print the comment for host $1 and run URL $2 on a host issue a run closes
host_close_comment() {
  # The backticks are Markdown code around the host
  # shellcheck disable=SC2016
  printf 'Fewer than %s packages of `%s` failed to check in %s.\n' "$HOST_ISSUE_MIN" "$1" "$2"
}

# Print the body of the issue of package $1, published at version $2 without
# the arches $3, for run URL $4
# Run gh with $@, an issue write, ISSUE_WRITE_PAUSE_MS after the last one, while the file ISSUE_WRITES counts
# fewer than ISSUE_WRITE_MAX of the 500 writes an hour of GitHub; fail with 3 past it
issue_write() {
  local count=0 last=0 now wait pause=$((${ISSUE_WRITE_PAUSE_MS:-1000} * 1000))
  [[ ! -f "${ISSUE_WRITES:?}" ]] || read -r count last <"$ISSUE_WRITES" || true
  [[ "$count" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]] || count=0 last=0
  ((count < ${ISSUE_WRITE_MAX:-450})) || return 3
  now=${EPOCHREALTIME/[.,]/}
  wait=$((last + pause - now))
  if ((wait > 0)); then
    sleep "$((wait / 1000000)).$(printf '%06d' "$((wait % 1000000))")"
  fi
  printf '%s %s\n' "$((count + 1))" "${EPOCHREALTIME/[.,]/}" >"$ISSUE_WRITES"
  gh "$@"
}

# Print the body of the issue for failed packages $3 on, whose statuses are in directory $1, that the run $2
# had no writes left for; errors hold text of upstream, so each goes in a code span without backticks
grouped_issue_body() {
  local dir=$1 run=$2 name error
  shift 2
  printf 'GitHub allows a run about 450 writes to issues an hour, so these packages failed without an issue of their own in %s. The run summary of its step Create issues holds each whole error.\n\n' "$run"
  for name in "$@"; do
    error=""
    IFS= read -r error <"$dir/$name" || true
    error=${error#*: }
    error=${error//\`/\'}
    # shellcheck disable=SC2016 # Markdown code, not expansions
    printf -- '- `%s`: `%s`\n' "$name" "${error:0:200}"
  done
  printf '\nAuto-created by update workflow, which closes it once each of these packages recovered or has an issue of its own.\n'
}

# Print the body of the issue for the packages of requirements file $1, lines of a name and python or
# ruby, or nothing when it names none; the body holds no run, so an equal list gives an equal body
requirements_issue_body() {
  local line items="" LC_ALL=C re=$'^([a-z0-9][a-z0-9.+_-]*)\t(python|ruby)$'
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ $re ]] || continue
    # shellcheck disable=SC2016 # Markdown code, not expansions
    case ${BASH_REMATCH[2]} in
      python) items+="- \`${BASH_REMATCH[1]}\`: its depends hold Python packages, so set \`python.pypi\`, \`python.pyproject\` or \`python: none\`"$'\n' ;;
      ruby) items+="- \`${BASH_REMATCH[1]}\`: its depends hold Ruby packages, so set \`ruby.gem\` or \`ruby: none\`"$'\n' ;;
    esac
  done <"$1"
  [[ -n "$items" ]] || return 0
  printf 'The YAML of each package below names no source of its requirements, so the requires rules cannot read them and the check of its next version fails:\n\n%s\nSee https://aurtomator.dev/features/update-alerts/\n\nAuto-created by update workflow, which edits it when the list changes and closes it once no package is left.\n' "$items"
}

arch_issue_body() {
  # The backticks are Markdown code around the package, version and arches
  # shellcheck disable=SC2016
  printf 'Package: `%s`\nVersion: `%s`\nMissing arches: `%s`\nRun: %s\n\nThe release of this version has no archive for these arches, so the AUR package builds without them. Each run asks for the archives again and puts an arch back once its archive is out.\n\nAuto-created by update workflow, which closes it when every arch is back.\n' "$1" "$2" "$3" "$4"
}

# Print the comment for package $1 and run URL $2 on an issue that a run closes since the YAML
# of the package is gone
retired_close_comment() {
  # The backticks are Markdown code around the path
  # shellcheck disable=SC2016
  printf '`packages/%s.yml` is gone as of %s.\n' "$1" "$2"
}

# Print the comment for package $1 and run URL $2 on an arch issue a run closes
arch_close_comment() {
  # The backticks are Markdown code around the package
  # shellcheck disable=SC2016
  printf 'Every arch of `%s` is back as of %s.\n' "$1" "$2"
}
