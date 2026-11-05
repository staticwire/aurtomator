#!/usr/bin/env bash
#
# Prints the script aurtomator.sh of the template: the fenced bash block of
# docs/SETUP.md that starts with a shebang. Fails when there is no such block.

set -euo pipefail

awk '
  /^```bash$/ { start = NR + 1; next }
  NR == start && $0 == "#!/usr/bin/env bash" { inside = 1 }
  inside && /^```$/ { exit }
  inside { found = 1; print }
  END { exit !found }
' "$(dirname "${BASH_SOURCE[0]}")/../../docs/SETUP.md"
