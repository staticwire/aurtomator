#!/usr/bin/env bash
#
# lib.sh - Sources the files of lib/ for the scripts; strategies source lib/common.sh, and
# pypi.sh lib/pep440.sh and lib/requires.sh too
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/pep440.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/pep440.sh"
# shellcheck source=lib/requires.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/requires.sh"
# shellcheck source=lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
# shellcheck source=lib/pkgbuild.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/pkgbuild.sh"
# shellcheck source=lib/aur.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/aur.sh"
# shellcheck source=lib/prepared.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prepared.sh"
# shellcheck source=lib/arch.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/arch.sh"
# shellcheck source=lib/archdb.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/archdb.sh"
# shellcheck source=lib/pyrules.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/pyrules.sh"
# shellcheck source=lib/sums.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/sums.sh"
# shellcheck source=lib/issue.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/issue.sh"
# shellcheck source=lib/status.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/status.sh"
# shellcheck source=lib/stats.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stats.sh"
# shellcheck source=lib/alerts.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/alerts.sh"
# shellcheck source=lib/version.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/version.sh"
