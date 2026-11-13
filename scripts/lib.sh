# shellcheck shell=bash
# shellcheck disable=SC2034  # variables here (fail, TENANTS) are used by the scripts that source this file
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
prom() {
  kubectl get --raw "/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")" 2>/dev/null \
    | python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else "")' 2>/dev/null || true
}
TENANTS="${TENANTS:-$(grep -E '^[a-z0-9-]+:' tenants.yaml | cut -d: -f1 | tr '\n' ' ')}"
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
odoo_body() {
  kubectl -n "$1" exec deploy/odoo -c odoo -- python3 -c "import urllib.request,sys
print(urllib.request.urlopen('http://localhost:8069'+sys.argv[1]).read().decode())" "$2" 2>/dev/null || true
}

can_connect() {
kubectl -n "$1" exec deploy/odoo -c odoo -- python3 -c "import socket;s=socket.socket();s.settimeout(3)
try: s.connect(('$2',5432)); print('open')
except Exception: print('blocked')" 2>/dev/null || true
}
