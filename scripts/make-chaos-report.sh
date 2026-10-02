#!/usr/bin/env bash
# make-chaos-report.sh — детерминированная генерация отчёта docs/chaos-report-<date>.md
# из уже собранных скриптом collect-chaos-report.sh данных (.state/chaos-report-<date>/).
#
# Таблицы и ссылки на графики строит скрипт; качественные «Вывод»/«Ключевые находки»
# дописывает AI (см. AGENTS.md). Метрики в «Эффект» и в Explore-ссылке берутся из
# одной и той же карты EFFECT_METRICS, поэтому текст и график всегда соответствуют друг другу.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RUN_DATE="${RUN_DATE:-$(date +%F)}"
OUT_DIR="${OUT_DIR:-$ROOT/.state/chaos-report-$RUN_DATE}"
REPORT="${REPORT:-$ROOT/docs/chaos-report-$RUN_DATE.md}"
ZONES="${ZONES:-ru-central1-a}"
GRAFANA_URL="${GRAFANA_URL:-$(terraform output -raw grafana_url 2>/dev/null || echo '')}"
DS_UID="${DS_UID:-VictoriaMetrics}"
RATE="${RATE:-1m}"

[ -f "$OUT_DIR/windows.tsv" ] || { echo "нет $OUT_DIR/windows.tsv — сначала collect-chaos-report.sh" >&2; exit 1; }

# --- выражения метрик (источник истины для ссылок) ---
expr_of() {
  case "$1" in
    bulk_err_pct)          echo "100 * sum(rate(loadgen_bulk_err_total[${RATE}])) / clamp_min(sum(rate(loadgen_bulk_ok_total[${RATE}])) + sum(rate(loadgen_bulk_err_total[${RATE}])), 1)" ;;
    search_err_pct)        echo "100 * sum(rate(loadgen_search_err_total[${RATE}])) / clamp_min(sum(rate(loadgen_search_ok_total[${RATE}])) + sum(rate(loadgen_search_err_total[${RATE}])), 1)" ;;
    bulk_ok_rps)           echo "sum(rate(loadgen_bulk_ok_total[${RATE}]))" ;;
    search_ok_rps)         echo "sum(rate(loadgen_search_ok_total[${RATE}]))" ;;
    bulk_p99_s)            echo "histogram_quantile(0.99, sum(rate(loadgen_bulk_duration_seconds_bucket[${RATE}])) by (le))" ;;
    search_p99_s)          echo "histogram_quantile(0.99, sum(rate(loadgen_search_duration_seconds_bucket[${RATE}])) by (le))" ;;
    es_unassigned)         echo 'sum(elasticsearch_cluster_health_unassigned_shards{cluster="elastic"})' ;;
    es_health_red)         echo 'max(elasticsearch_cluster_health_status{cluster="elastic",color="red"})' ;;
    es_nodes)              echo 'sum(elasticsearch_cluster_health_number_of_nodes{cluster="elastic"})' ;;
    es_queue)              echo 'sum(elasticsearch_thread_pool_queue_count{cluster="elastic"})' ;;
    es_pending)            echo 'sum(elasticsearch_cluster_health_number_of_pending_tasks{cluster="elastic"})' ;;
    goldpinger_unhealthy)  echo 'sum(goldpinger_nodes_health_total{status="unhealthy"})' ;;
    cilium_max_s)          echo 'max(cilium_node_connectivity_latency_seconds)' ;;
    *) return 1 ;;
  esac
}

# --- какие метрики показывать для события (и в тексте, и на графике) ---
# chaos: по шагу; sg: по действию.
effect_metrics() {
  local kind="$1" scope="$2" action="$3"
  if [ "$kind" = chaos ]; then
    case "$scope" in
      pod-kill) echo "es_unassigned es_health_red es_queue es_pending" ;;
      loss)     echo "bulk_p99_s search_p99_s" ;;
      delay)    echo "bulk_p99_s search_p99_s" ;;
      isolate)  echo "bulk_err_pct search_err_pct goldpinger_unhealthy cilium_max_s" ;;
    esac
  else
    case "$action" in
      isolate) echo "bulk_err_pct search_err_pct bulk_ok_rps search_ok_rps" ;;
      restore) echo "search_err_pct bulk_ok_rps goldpinger_unhealthy cilium_max_s" ;;
      *)       echo "bulk_err_pct bulk_ok_rps" ;;
    esac
  fi
}

epoch() { date -u -d "$1" +%s; }

# --- сборка Explore-URL через jq (@uri) ---
explore_url() {
  local frm_ms="$1" to_ms="$2"; shift 2
  local qjson="[]" m
  for m in "$@"; do
    qjson="$(jq -c --argjson q "$qjson" --arg e "$(expr_of "$m")" --arg uid "$DS_UID" \
      '$q + [{refId:(($q|length)|[65+.]|implode),expr:$e,datasource:{type:"prometheus",uid:$uid},editorMode:"code",range:true,instant:false}]' <<<null)"
  done
  local pane
  pane="$(jq -cn --argjson q "$qjson" --arg uid "$DS_UID" --arg from "$frm_ms" --arg to "$to_ms" \
    '{a1:{datasource:$uid,queries:$q,range:{from:$from,to:$to}}}')"
  printf '%s/explore?schemaVersion=1&orgId=1&panes=%s' "$GRAFANA_URL" "$(jq -rn --arg p "$pane" '$p|@uri')"
}

# --- форматирование значения ---
fmt() { awk -v v="$1" 'BEGIN{ if (v=="") {print "—"; exit} if (v+0==int(v+0) && (v+0>=100 || v+0<=-100)) printf "%.0f", v; else printf "%.3g", v }'; }

# --- ячейка «Эффект» из analysis.tsv по idx ---
effect_cell() {
  local idx="$1"; shift
  local m out=""
  for m in "$@"; do
    local row
    row="$(awk -F'\t' -v i="$idx" -v mm="$m" '$1==i && $6==mm{print; exit}' "$OUT_DIR/analysis.tsv")"
    [ -z "$row" ] && continue
    local pmin pavg pmax emin eavg emax
    pmin="$(cut -f7 <<<"$row")"; pavg="$(cut -f8 <<<"$row")"; pmax="$(cut -f9 <<<"$row")"
    emin="$(cut -f10 <<<"$row")"; eavg="$(cut -f11 <<<"$row")"; emax="$(cut -f12 <<<"$row")"
    if [ -z "$emax" ]; then
      out+="\`$m\` — данных мало; "
    else
      out+="\`$m\` $(fmt "$pavg") → **$(fmt "$eavg")** (max $(fmt "$emax")); "
    fi
  done
  printf '%s' "${out%; }"
}

link_for() {
  local idx="$1" pre_start="$2" end="$3"; shift 3
  local url; url="$(explore_url "$(( $(epoch "$pre_start") * 1000 ))" "$(( $(epoch "$end") * 1000 ))" "$@")"
  printf '[график](%s)' "$url"
}

label_for() {
  local kind="$1" zone="$2" scope="$3" action="$4"
  if [ "$kind" = chaos ]; then printf '**%s**' "$scope"; else printf '`%s SG %s`' "${action:-isolate}" "$scope"; fi
}

{
  echo "# Отчёт о влиянии аннотаций: зона \`$ZONES\`"
  echo
  echo "**Дата прогона:** $RUN_DATE"
  echo "**Зона:** \`$ZONES\` (изоляция SG и chaos-тесты выполняются только для неё)"
  echo "**Источник данных:** аннотации Grafana + метрики VictoriaMetrics"
  echo "**Сбор:** \`RUN_FROM=<epoch> ZONES=$ZONES scripts/collect-chaos-report.sh\`"
  echo "**Сырые данные:** \`.state/chaos-report-$RUN_DATE/\` (\`windows.tsv\`, \`analysis.tsv\`, \`*.tsv\`)"
  echo
  echo "## Методика"
  echo
  echo "Скрипт \`scripts/collect-chaos-report.sh\` забирает из Grafana аннотации прогона, классифицирует их на"
  echo "\`chaos\` (pod-kill/loss/delay/isolate) и \`sg\` (isolate/restore/verify по node group), для каждой"
  echo "запрашивает в VictoriaMetrics метрики эффекта и считает \`pre\`-окно (равное событию, непосредственно перед ним)"
  echo "и \`event\`-окно. Порог «существенное изменение» не задан — значение трактуется по форме кривой, как в README."
  echo
  echo "Колонка **Эффект** — детерминированная выжимка из \`analysis.tsv\`: \`avg → avg (max)\`. Колонка **График** —"
  echo "ссылка на Grafana Explore (datasource \`$DS_UID\`) с теми же метриками за окно \`pre + event\`; текст и график"
  echo "соответствуют друг другу по построению. Колонка **Вывод** и раздел «Ключевые находки» дописывает AI."
  echo
  echo "> Оговорка: baseline ошибок у loadgen обычно нулевой, рост с нуля даёт \`inf%\`. Низкоуровневые метрики ES"
  echo "> (\`es_nodes\`, \`es_docs_load\`) дискретны и в коротких SG-окнах дают артефакты — читать как «данных мало»."
  echo
  echo "## Сводка по аннотациям"
  echo
  echo "### Chaos-шаги (зона \`$ZONES\`)"
  echo
  echo "| # | Шаг | Эффект \`event\` относительно \`pre\` | График | Вывод |"
  echo "|---|---|---|---|---|"
  tail -n +2 "$OUT_DIR/windows.tsv" | sort -t$'\t' -k6,6 | while IFS=$'\t' read -r idx kind zone scope action start end pre_start pre_end; do
    [ -z "${idx:-}" ] && continue
    [ "$kind" = chaos ] || continue
    metric_list="$(effect_metrics "$kind" "$scope" "$action")"
    # shellcheck disable=SC2086
    printf '| %s | %s | %s | %s | _заполняет AI_ |\n' "$idx" "$(label_for "$kind" "$zone" "$scope" "$action")" "$(effect_cell "$idx" $metric_list)" "$(link_for "$idx" "$pre_start" "$end" $metric_list)"
  done
  echo
  echo "### Смена security group (зона \`$ZONES\`)"
  echo
  echo "| # | Аннотация | Эффект | График | Вывод |"
  echo "|---|---|---|---|---|"
  tail -n +2 "$OUT_DIR/windows.tsv" | sort -t$'\t' -k6,6 | while IFS=$'\t' read -r idx kind zone scope action start end pre_start pre_end; do
    [ -z "${idx:-}" ] && continue
    [ "$kind" = sg ] || continue
    metric_list="$(effect_metrics "$kind" "$scope" "$action")"
    # shellcheck disable=SC2086
    printf '| %s | %s | %s | %s | _заполняет AI_ |\n' "$idx" "$(label_for "$kind" "$zone" "$scope" "$action")" "$(effect_cell "$idx" $metric_list)" "$(link_for "$idx" "$pre_start" "$end" $metric_list)"
  done
  echo
  echo "## Ключевые находки"
  echo
  echo "_Заполняет AI по \`analysis.tsv\` и графикам: основной вклад, сравнение шагов, связность, сохранность данных._"
  echo
  echo "## Замечания к качеству данных"
  echo
  echo "- Короткие SG-окна (30–60 c) при \`STEP_QUERY=30\` дают 1–2 точки на метрику — низкоуровневые метрики ES шумные."
  echo "- \`pod-kill\` задевает поды loadgen: счётчики успевают сброситься (провалы \`es_nodes\`/\`docs\`)."
  echo "- Для повторного прогона отчёта задавать \`RUN_FROM\` = epoch начала прогона."
} > "$REPORT"

echo "отчёт: $REPORT"
