#!/usr/bin/env bash
#
# lib.sh - Shared functions for aurtomator scripts
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Requires: yq (https://github.com/mikefarah/yq)
#
# The functions live in lib/, one file per concern. A strategy sources
# lib/common.sh alone.

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/pkgbuild.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/pkgbuild.sh"
# shellcheck source=lib/aur.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/aur.sh"
# shellcheck source=lib/prepared.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prepared.sh"
# shellcheck source=lib/sums.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/sums.sh"
# shellcheck source=lib/issue.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/issue.sh"
# shellcheck source=lib/alerts.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/alerts.sh"
# shellcheck source=lib/version.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/version.sh"
