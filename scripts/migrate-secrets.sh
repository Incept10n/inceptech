#!/usr/bin/env bash
# Recursively copy every secret from one OpenBao/Vault KV v2 instance to another
# (e.g. when migrating to a rebuilt cluster).
#
# Usage:
#   export SRC_TOKEN="s...."   # token of the SOURCE instance
#   export DST_TOKEN="s...."   # token of the DESTINATION instance
#
#   # port-forward each instance so they are reachable locally:
#   #   source      -> http://127.0.0.1:8200
#   #   destination -> http://127.0.0.1:8201
#
#   ./scripts/migrate-secrets.sh
#
# Requires: bao CLI and jq locally.
set -euo pipefail

SRC="http://127.0.0.1:8200"
DST="http://127.0.0.1:8201"
KV_PATH="secret"   # KV v2 mount point name

: "${SRC_TOKEN:?export SRC_TOKEN (source instance token)}"
: "${DST_TOKEN:?export DST_TOKEN (destination instance token)}"

# Verify destination KV mount exists (create if missing)
VAULT_ADDR="$DST" VAULT_TOKEN="$DST_TOKEN" bao secrets list | grep -q "^${KV_PATH}/" || \
  VAULT_ADDR="$DST" VAULT_TOKEN="$DST_TOKEN" bao secrets enable -path="$KV_PATH" kv-v2

recurse() {
  local prefix="$1"
  local items
  items=$(VAULT_ADDR="$SRC" VAULT_TOKEN="$SRC_TOKEN" bao kv list -format=json "${KV_PATH}/${prefix}" 2>/dev/null | jq -r '.[]' 2>/dev/null || true)
  [ -z "$items" ] && return

  for item in $items; do
    if [[ "$item" == */ ]]; then
      recurse "${prefix}${item}"
    else
      echo "Copying: ${KV_PATH}/${prefix}${item}"
      local data
      data=$(VAULT_ADDR="$SRC" VAULT_TOKEN="$SRC_TOKEN" bao kv get -format=json "${KV_PATH}/${prefix}${item}" | jq '.data.data')
      echo "$data" | VAULT_ADDR="$DST" VAULT_TOKEN="$DST_TOKEN" bao kv put "${KV_PATH}/${prefix}${item}" - > /dev/null
    fi
  done
}

recurse ""
echo "Done."
