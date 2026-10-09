#!/usr/bin/env bash
# Port 8443 (sing-box vless-ws-in, the Cloudflare origin) accepts Cloudflare + loopback only.
#
# Why: anyone hitting <VPS_IP>:8443 directly got the origin cert, which tied the
# domain to this (blocked) IP for scanners. Cloudflare only ever connects from its
# published ranges, so nothing legitimate is lost.
#
# Lives in its own nftables table (inet cf8443): no other port, no other rule is touched,
# and "remove" puts everything back exactly as it was.
#
#   cf8443-firewall.sh update   fetch Cloudflare ranges, validate, save, apply
#   cf8443-firewall.sh apply    (re)load the table from the saved ranges, atomically
#   cf8443-firewall.sh dryrun   build the ruleset and let nft check it, load nothing
#   cf8443-firewall.sh remove   drop the table (8443 open to everyone again)
#   cf8443-firewall.sh status   rules + drop counter
set -u

DIR=/etc/cf8443
PORT=8443
TABLE="inet cf8443"
API=https://api.cloudflare.com/client/v4/ips

fail() { echo "FAIL: $*" >&2; exit 1; }

build() {  # writes the ruleset to stdout from the saved ranges
  local v4 v6
  v4=$(paste -sd, "$DIR/v4.txt")
  v6=$(paste -sd, "$DIR/v6.txt" 2>/dev/null)
  echo "table $TABLE"          # make sure it exists so the delete below cannot fail,
  echo "delete table $TABLE"   # then replace it in the same transaction (atomic)
  echo "table $TABLE {"
  echo "  set cf4 { type ipv4_addr; flags interval; elements = { $v4 } }"
  [ -n "$v6" ] && echo "  set cf6 { type ipv6_addr; flags interval; elements = { $v6 } }"
  echo "  chain input {"
  echo "    type filter hook input priority -10; policy accept;"
  echo "    iif lo tcp dport $PORT accept"
  echo "    ip saddr @cf4 tcp dport $PORT accept"
  [ -n "$v6" ] && echo "    ip6 saddr @cf6 tcp dport $PORT accept"
  echo "    tcp dport $PORT counter drop"
  echo "  }"
  echo "}"
}

update() {
  local j v4 v6
  mkdir -p "$DIR"
  j=$(curl -fsS --max-time 30 "$API") || fail "fetch failed, keeping the saved ranges"
  [ "$(printf '%s' "$j" | jq -r .success)" = true ] || fail "API answered success!=true, keeping the saved ranges"
  v4=$(printf '%s' "$j" | jq -r '.result.ipv4_cidrs[]' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$')
  v6=$(printf '%s' "$j" | jq -r '.result.ipv6_cidrs[]' | grep -E '^[0-9a-f:]+/[0-9]{1,3}$')
  [ "$(printf '%s\n' "$v4" | grep -c .)" -ge 10 ] || fail "fewer than 10 IPv4 ranges, keeping the saved ranges"
  printf '%s\n' "$v4" > "$DIR/v4.tmp" && mv -f "$DIR/v4.tmp" "$DIR/v4.txt"
  printf '%s\n' "$v6" > "$DIR/v6.tmp" && mv -f "$DIR/v6.tmp" "$DIR/v6.txt"
  echo "ranges: $(grep -c . "$DIR/v4.txt") IPv4, $(grep -c . "$DIR/v6.txt") IPv6"
  apply
}

apply() {
  [ -s "$DIR/v4.txt" ] || fail "no saved ranges in $DIR; run update first"
  local f
  f=$(mktemp)
  build > "$f"
  if ! nft -f "$f"; then rm -f "$f"; fail "nft rejected the ruleset (the old table, if any, is unchanged)"; fi
  rm -f "$f"
  echo "applied: $PORT accepts Cloudflare + loopback only"
}

dryrun() {
  [ -s "$DIR/v4.txt" ] || fail "no saved ranges in $DIR; run update first"
  local f
  f=$(mktemp)
  build > "$f"
  cat "$f"
  nft -c -f "$f" && echo "dryrun: nft accepts this ruleset"
  rm -f "$f"
}

remove() { nft delete table $TABLE 2>/dev/null; echo "removed: $PORT open to everyone"; }

status() { nft list table $TABLE 2>/dev/null | grep -E 'dport|elements' | cut -c1-140 || echo "no table: $PORT open to everyone"; }

case "${1:-}" in
  update|apply|dryrun|remove|status) "$1" ;;
  *) echo "usage: $0 update|apply|dryrun|remove|status"; exit 2 ;;
esac
