#!/usr/bin/env bash
# 統計 aetherSlide nginx log 裡「搜尋」與「瓦片」的耗時分布(依小時)
# v1.0
# 用法: ./nginx_latency.sh            看最近 24 小時
#       ./nginx_latency.sh 72h        看最近 72 小時
#       ./nginx_latency.sh 2026-10-06 從該日 00:00 看到現在
usage() {
  echo "Usage: $0 [DURATION | DATE]"
  echo "  $0              last 24 hours (default)"
  echo "  $0 72h          last 72 hours"
  echo "  $0 2026-10-06   from 2026-10-06 00:00 until now"
}
SINCE=${1:-24h}
if ! [[ "$SINCE" =~ ^[0-9]+[mh]$ || "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Invalid argument: $*"; usage; exit 1
fi
TMP=$(mktemp)
docker logs --since "$SINCE" aetherslide.nginx 2>&1 | awk '
/ connected upstream / {
  if ($0 ~ /navigation_list/) c = "search"; else if ($0 ~ /\/tile\//) c = "tile"; else next
  u = $0; sub(/.* bytes in /, "", u); sub(/ s .*/, "", u)
  t = $0; sub(/.* to client in /, "", t); sub(/ s.*/, "", t)
  print c " " $1 " " substr($2, 1, 2) "h\t" u + 0 "\t" t + 0
}' > "$TMP"

pct() {
  sort -t"$(printf '\t')" -k1,1 -k"$1","$1"g "$TMP" | awk -F'\t' -v col="$1" '
  function flush() { if (n) printf "%s\t%d\t%.3f\t%.3f\t%.3f\n", k, n, v[int((n-1)*0.5)+1], v[int((n-1)*0.95)+1], v[n] }
  $1 != k { flush(); k = $1; n = 0 } { v[++n] = $col } END { flush() }'
}

echo "Window: --since $SINCE   requests: $(wc -l < "$TMP")   (seconds; upstream = backend time, total = nginx->client)"
printf "%-24s %6s | %8s %8s %8s | %8s %8s %8s\n" "type date hour" "count" "up_p50" "up_p95" "up_max" "tot_p50" "tot_p95" "tot_max"
join -t"$(printf '\t')" <(pct 2) <(pct 3 | cut -f1,3-) | awk -F'\t' '{ printf "%-24s %6s | %8s %8s %8s | %8s %8s %8s\n", $1, $2, $3, $4, $5, $6, $7, $8 }'
echo
echo "Slowest 10 (total s, upstream s):"
sort -t"$(printf '\t')" -k3,3gr "$TMP" | head -10 | awk -F'\t' '{ printf "  %-24s total %7.3f  upstream %7.3f\n", $1, $3, $2 }'
rm -f "$TMP"
