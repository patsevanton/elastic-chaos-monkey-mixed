#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GRAFANA_URL="${GRAFANA_URL:-$(terraform output -raw grafana_url)}"
GRAFANA_USER=admin
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-$(kubectl --context app -n vmks get secret vmks-grafana -o jsonpath='{.data.admin-password}' | base64 -d)}"
DS_UID="${DS_UID:-VictoriaMetrics}"
STEP_QUERY="${STEP_QUERY:-15}"
RATE="${RATE:-1m}"

ZONES="${ZONES:-ru-central1-a}"
RUN_DATE="${RUN_DATE:-$(date +%F)}"
OUT_DIR="${OUT_DIR:-$ROOT/.state/chaos-report-$RUN_DATE}"
mkdir -p "$OUT_DIR"

NOW="$(date +%s)"
FROM_MS=$(( ${RUN_FROM:-$((NOW - 86400))} * 1000 ))
TO_MS=$(( ${RUN_TO:-$NOW} * 1000 ))

api() { curl -fsS -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" "$@"; }

# --- сырые аннотации ---
api "$GRAFANA_URL/api/annotations?from=$FROM_MS&to=$TO_MS&limit=2000" > "$OUT_DIR/annotations.json"
jq -r '.[] | [.id, (.time / 1000 | floor), .text, (.tags | join(" "))] | @tsv' \
  "$OUT_DIR/annotations.json" > "$OUT_DIR/annotations.tsv"

# --- классификация: chaos-шаги и SG-смены ---
: > "$OUT_DIR/chaos.tsv"   # epoch zone step target phase
: > "$OUT_DIR/sg.tsv"      # epoch zone ng action phase
while IFS=$'\t' read -r _id epoch text tags; do
  [ -z "${epoch:-}" ] && continue
  kind=skip
  case " $tags " in
    *" chaos "*) kind=chaos ;;
    *" sg "*)    kind=sg ;;
  esac
  [ "$kind" = skip ] && continue
  phase=""
  case " $tags " in
    *" start "*) phase=start ;;
    *" end "*)   phase=end ;;
  esac
  [ -z "$phase" ] && continue
  zone="$(printf '%s\n' $tags | grep -m1 -E '^(ru-central1-)?[abd]$' || true)"
  case "$zone" in a|b|d) zone="ru-central1-$zone" ;; esac
  [ -z "$zone" ] && continue
  case " $ZONES " in *" $zone "*) ;; *) continue ;; esac
  if [ "$kind" = chaos ]; then
    step="$(printf '%s\n' $tags | grep -m1 -E '^(pod-kill|loss|delay|isolate)$' || true)"
    [ -z "$step" ] && continue
    target="$(printf '%s\n' $tags | sed -n 's/^target-//p' | head -n1)"
    [ -z "$target" ] && target=x
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$zone" "$step" "$target" "$phase" >> "$OUT_DIR/chaos.tsv"
  else
    ng="$(printf '%s\n' $tags | grep -m1 -E '^(elastic-master|elastic-data|app)-[abd]$' || true)"
    [ -z "$ng" ] && continue
    action=isolate
    case "$text" in *restore*) action=restore ;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$zone" "$ng" "$action" "$phase" >> "$OUT_DIR/sg.tsv"
  fi
done < "$OUT_DIR/annotations.tsv"

sort -n -k1,1 "$OUT_DIR/chaos.tsv" > "$OUT_DIR/chaos.sorted"
sort -n -k1,1 "$OUT_DIR/sg.tsv" > "$OUT_DIR/sg.sorted"

# --- окна chaos: start -> end по (zone, step, target) ---
# Строки chaos.sorted: epoch zone step target phase.
awk -F'\t' '
  $5 == "start" { k = $2 SUBSEP $3 SUBSEP $4; sc[k]++; st[k, sc[k]] = $1 }
  $5 == "end"   { k = $2 SUBSEP $3 SUBSEP $4; ec[k]++; en[k, ec[k]] = $1 }
  END {
    for (k in sc) {
      n = sc[k]; if (ec[k] < n) n = ec[k]
      split(k, b, SUBSEP)
      for (i = 1; i <= n; i++) printf "%s\t%s\t%s\t%s\t%s\n", b[1], b[2], b[3], st[k, i], en[k, i]
    }
  }
' "$OUT_DIR/chaos.sorted" > "$OUT_DIR/chaos_windows.tsv"

# --- окна SG: i-й start -> i-й end по (zone,ng,action) ---
awk -F'\t' '
  $5 == "start" { k = $2 SUBSEP $3 SUBSEP $4; sc[k]++; st[k, sc[k]] = $1 }
  $5 == "end"   { k = $2 SUBSEP $3 SUBSEP $4; ec[k]++; en[k, ec[k]] = $1 }
  END {
    for (k in sc) {
      n = sc[k]; if (ec[k] < n) n = ec[k]
      split(k, b, SUBSEP)
      for (i = 1; i <= n; i++) printf "%s\t%s\t%s\t%s\t%s\n", b[1], b[2], b[3], st[k, i], en[k, i]
    }
  }
' "$OUT_DIR/sg.sorted" > "$OUT_DIR/sg_windows.tsv"

# --- метрики эффекта (все агрегированы в одну серию) ---
METRICS="$(cat <<EOF
bulk_err_pct|100 * sum(rate(loadgen_bulk_err_total[${RATE}])) / clamp_min(sum(rate(loadgen_bulk_ok_total[${RATE}])) + sum(rate(loadgen_bulk_err_total[${RATE}])), 1)
search_err_pct|100 * sum(rate(loadgen_search_err_total[${RATE}])) / clamp_min(sum(rate(loadgen_search_ok_total[${RATE}])) + sum(rate(loadgen_search_err_total[${RATE}])), 1)
bulk_ok_rps|sum(rate(loadgen_bulk_ok_total[${RATE}]))
search_ok_rps|sum(rate(loadgen_search_ok_total[${RATE}]))
bulk_p50_s|histogram_quantile(0.50, sum(rate(loadgen_bulk_duration_seconds_bucket[${RATE}])) by (le))
bulk_p99_s|histogram_quantile(0.99, sum(rate(loadgen_bulk_duration_seconds_bucket[${RATE}])) by (le))
search_p50_s|histogram_quantile(0.50, sum(rate(loadgen_search_duration_seconds_bucket[${RATE}])) by (le))
search_p99_s|histogram_quantile(0.99, sum(rate(loadgen_search_duration_seconds_bucket[${RATE}])) by (le))
es_health_yellow|max(elasticsearch_cluster_health_status{cluster="elastic",color="yellow"})
es_health_red|max(elasticsearch_cluster_health_status{cluster="elastic",color="red"})
es_nodes|sum(elasticsearch_cluster_health_number_of_nodes{cluster="elastic"})
es_unassigned|sum(elasticsearch_cluster_health_unassigned_shards{cluster="elastic"})
es_initializing|sum(elasticsearch_cluster_health_initializing_shards{cluster="elastic"})
es_relocating|sum(elasticsearch_cluster_health_relocating_shards{cluster="elastic"})
es_docs_load|sum(elasticsearch_indices_docs_primary{cluster="elastic",index="load"})
es_rejected_rps|sum(rate(elasticsearch_thread_pool_rejected_count{cluster="elastic"}[${RATE}]))
es_queue|sum(elasticsearch_thread_pool_queue_count{cluster="elastic"})
es_pending|sum(elasticsearch_cluster_health_number_of_pending_tasks{cluster="elastic"})
es_search_ms|1000 * sum(rate(elasticsearch_indices_search_query_time_seconds{cluster="elastic"}[${RATE}])) / clamp_min(sum(rate(elasticsearch_indices_search_query_total{cluster="elastic"}[${RATE}])), 1)
es_index_ms|1000 * sum(rate(elasticsearch_indices_indexing_index_time_seconds_total{cluster="elastic"}[${RATE}])) / clamp_min(sum(rate(elasticsearch_indices_indexing_index_total{cluster="elastic"}[${RATE}])), 1)
goldpinger_health|max(goldpinger_cluster_health_total)
goldpinger_unhealthy|sum(goldpinger_nodes_health_total{status="unhealthy"})
goldpinger_p99_s|histogram_quantile(0.99, sum(rate(goldpinger_peers_response_time_s_bucket[${RATE}])) by (le))
cilium_avg_s|avg(cilium_node_connectivity_latency_seconds)
cilium_max_s|max(cilium_node_connectivity_latency_seconds)
EOF
)"

iso() { date -u -d "@$1" +%FT%TZ; }

# refmap: M1<TAB>bulk_err_pct ...
awk -F'|' 'NF==2 && $1!="" {printf "M%d\t%s\n", ++i, $1}' <<<"$METRICS" > "$OUT_DIR/refmap.tsv"

QUERIES_JSON="$(
  i=0
  printf '['
  while IFS=$'\t' read -r ref mname; do
    [ -z "${ref:-}" ] && continue
    expr="$(awk -F'|' -v n="$mname" '$1==n{print $2}' <<<"$METRICS")"
    i=$((i + 1))
    [ "$i" -gt 1 ] && printf ','
    jq -cn --arg ref "$ref" --arg expr "$expr" --arg uid "$DS_UID" --argjson iv "${STEP_QUERY}000" \
      '{refId:$ref,datasource:{type:"prometheus",uid:$uid},expr:$expr,range:true,intervalMs:$iv,maxDataPoints:2000}'
  done < "$OUT_DIR/refmap.tsv"
  printf ']'
)"

# один batched-запрос на окно; печатает "name ts value"
batch_query() {
  local start="$1" end="$2"
  api -H 'Content-Type: application/json' -X POST "$GRAFANA_URL/api/ds/query" -d "$(
    jq -cn --argjson q "$QUERIES_JSON" --arg from "$(( start * 1000 ))" --arg to "$(( end * 1000 ))" \
      '{queries:$q, from:$from, to:$to}'
  )" | jq -r --slurpfile map <(jq -Rn '[inputs|split("\t")]' <"$OUT_DIR/refmap.tsv") '
    ($map[0] | map({key: .[0], value: .[1]}) | from_entries) as $names
    | .results | to_entries[]
    | .key as $ref | ($names[$ref]) as $name
    | .value.frames[0].data.values[0] as $ts
    | .value.frames[0].data.values[1] as $vs
    | select($ts != null)
    | range(0; ($ts | length))
    | "\($name)\t\(($ts[.] / 1000) | floor)\t\($vs[.])"
  ' 2>/dev/null
}

printf 'idx\tkind\tzone\tscope\taction\tstart\tend\tpre_start\tpre_end\n' > "$OUT_DIR/windows.tsv"

EVENT_N=0
run_event() {
  local kind="$1" zone="$2" scope="$3" action="$4" start="$5" end="$6" text="$7"
  EVENT_N=$((EVENT_N + 1))
  local dur=$(( end - start )); [ "$dur" -lt 60 ] && dur=60
  local pre_start=$(( start - dur )) pre_end=$start
  local name
  name="$(printf '%02d-%s-%s-%s-%s' "$EVENT_N" "$kind" "$zone" "$scope" "${action:-x}" | tr '/ ' '__')"
  local out="$OUT_DIR/$name.tsv"
  printf 'phase\tmetric\tts\tvalue\n' > "$out"
  local resp
  resp="$(batch_query "$pre_start" "$pre_end")" || resp=""
  while IFS=$'\t' read -r m ts val; do
    [ -z "${ts:-}" ] && continue
    printf 'pre\t%s\t%s\t%s\n' "$m" "$ts" "$val" >> "$out"
  done <<<"$resp"
  resp="$(batch_query "$start" "$end")" || resp=""
  while IFS=$'\t' read -r m ts val; do
    [ -z "${ts:-}" ] && continue
    printf 'event\t%s\t%s\t%s\n' "$m" "$ts" "$val" >> "$out"
  done <<<"$resp"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$EVENT_N" "$kind" "$zone" "$scope" "${action:--}" "$(iso "$start")" "$(iso "$end")" "$(iso "$pre_start")" "$(iso "$pre_end")" \
    >> "$OUT_DIR/windows.tsv"
  printf '%s\t%s\n' "$name" "$text" >> "$OUT_DIR/events.txt"
  echo "собрано: $name [$kind $zone $scope${action:+ $action}] $(iso "$start") .. $(iso "$end")"
}

target_words() {
  case "$1" in
    elastic-master) echo "elastic master" ;;
    elastic-data)   echo "elastic data" ;;
    loadgen)        echo "loadgen" ;;
    *)              echo "$1" ;;
  esac
}
while IFS=$'\t' read -r zone step target start end; do
  [ -z "${zone:-}" ] && continue
  tw="$(target_words "$target")"
  short="zone-${zone##*-}"
  run_event chaos "$zone" "$step $tw" "" "$start" "$end" "$step $tw $short"
done < "$OUT_DIR/chaos_windows.tsv"

while IFS=$'\t' read -r zone ng action start end; do
  [ -z "${zone:-}" ] && continue
  run_event sg "$zone" "$ng" "$action" "$start" "$end" "sg $zone: $action $ng"
done < "$OUT_DIR/sg_windows.tsv"

# --- анализ: pre-окно vs event-окно по каждой метрике ---
ANALYSIS="$OUT_DIR/analysis.tsv"
printf 'idx\tkind\tzone\tscope\taction\tmetric\tpre_min\tpre_avg\tpre_max\tev_min\tev_avg\tev_max\tdelta_pct\n' > "$ANALYSIS"

analyze_file() {
  local idx="$1" kind="$2" zone="$3" scope="$4" action="$5" f="$6"
  awk -F'\t' -v idx="$idx" -v kind="$kind" -v zone="$zone" -v scope="$scope" -v action="$action" '
    NR == 1 { next }
    $4 == "" { next }
    {
      m = $2; ph = $1; v = $4 + 0
      if (ph == "pre") { if (!(m in pn)) { pmin[m] = v; pmax[m] = v }; if (v < pmin[m]) pmin[m] = v; if (v > pmax[m]) pmax[m] = v; psum[m] += v; pn[m]++ }
      else { if (!(m in en)) { emin[m] = v; emax[m] = v }; if (v < emin[m]) emin[m] = v; if (v > emax[m]) emax[m] = v; esum[m] += v; en[m]++ }
      if (!(m in seen)) { seen[m] = 1; order[++k] = m }
    }
    END {
      for (i = 1; i <= k; i++) {
        m = order[i]
        pminv = (m in pn) ? sprintf("%.4f", pmin[m]) : ""
        pavg = (m in pn) ? sprintf("%.4f", psum[m] / pn[m]) : ""
        pmaxv = (m in pn) ? sprintf("%.4f", pmax[m]) : ""
        eminv = (m in en) ? sprintf("%.4f", emin[m]) : ""
        eavg = (m in en) ? sprintf("%.4f", esum[m] / en[m]) : ""
        emaxv = (m in en) ? sprintf("%.4f", emax[m]) : ""
        d = ""
        if (pmaxv != "" && emaxv != "") d = (pmaxv + 0 == 0) ? ((emaxv + 0 == 0) ? "0" : "inf") : sprintf("%.1f", 100 * (emaxv - pmaxv) / pmaxv)
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", idx, kind, zone, scope, action, m, pminv, pavg, pmaxv, eminv, eavg, emaxv, d
      }
    }
  ' "$f"
}

while IFS=$'\t' read -r idx kind zone scope action start end pre_start pre_end; do
  [ "$idx" = "idx" ] && continue
  [ "$action" = "-" ] && action=""
  f="$OUT_DIR/$(printf '%02d-%s-%s-%s-%s' "$idx" "$kind" "$zone" "$scope" "${action:-x}" | tr '/ ' '__').tsv"
  [ -f "$f" ] || continue
  analyze_file "$idx" "$kind" "$zone" "$scope" "$action" "$f" >> "$ANALYSIS"
done < "$OUT_DIR/windows.tsv"

echo "сырые данные: $OUT_DIR"
echo "окна: $OUT_DIR/windows.tsv"
echo "анализ: $ANALYSIS"

# --- markdown-отчёт с таблицами и ссылками на графики (детерминированно) ---
RUN_DATE="$RUN_DATE" OUT_DIR="$OUT_DIR" ZONES="$ZONES" "$ROOT/scripts/make-chaos-report.sh"
