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
odoo_http() {
kubectl -n "$1" exec deploy/odoo -c odoo -- python3 -c "import urllib.request,urllib.error,sys
try: print(urllib.request.urlopen('http://localhost:8069'+sys.argv[1]).status)
except urllib.error.HTTPError as e: print(e.code)" "$2" 2>/dev/null || true
}
can_connect() {
kubectl -n "$1" exec deploy/odoo -c odoo -- python3 -c "import socket;s=socket.socket();s.settimeout(3)
try: s.connect(('$2',5432)); print('open')
except Exception: print('blocked')" 2>/dev/null || true
}