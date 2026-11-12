set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
TENANTS="${TENANTS:-acme globex}"
log()   { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
tf()    { terraform -chdir=terraform "$@"; }
check() {
local name="$1" expected="$2" actual="$3"
if [ "$actual" = "$expected" ]; then
    printf '  \033[32mPASS\033[0m %s\n' "$name"
else
    printf '  \033[31mFAIL\033[0m %s (expected %s, got %s)\n' "$name" "$expected" "$actual"
    fail=1
fi
}