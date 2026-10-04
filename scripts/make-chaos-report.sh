#!/usr/bin/env bash
# make-chaos-report.sh — детерминированная генерация отчёта docs/chaos-report-<date>.md
# из уже собранных скриптом collect-chaos-report.sh данных (.state/chaos-report-<date>/).
#
# Таблицы и ссылки на графики строит скрипт; качественные «Вывод»/«Ключевые находки»
# дописывает AI (см. AGENTS.md). Для каждого события берётся единый набор метрик
# (effect_metrics), поэтому колонки «Дашборд → панель» и «График» покрывают любую
# метрику, которую AI может упомянуть в «Выводе». AI обязан называть в тексте
# только метрики из набора события — иначе появится упоминание без ссылки.
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
    es_pending)           echo 'sum(elasticsearch_cluster_health_number_of_pending_tasks{cluster="elastic"})' ;;
    es_docs_load)         echo 'sum(elasticsearch_indices_docs_primary{cluster="elastic",index="load"})' ;;
    es_index_ms)         echo "1000 * sum(rate(elasticsearch_indices_indexing_index_time_seconds_total{cluster=\"elastic\"}[${RATE}])) / clamp_min(sum(rate(elasticsearch_indices_indexing_index_total{cluster=\"elastic\"}[${RATE}])), 1)" ;;
    es_search_ms)         echo "1000 * sum(rate(elasticsearch_indices_search_query_time_seconds{cluster=\"elastic\"}[${RATE}])) / clamp_min(sum(rate(elasticsearch_indices_search_query_total{cluster=\"elastic\"}[${RATE}])), 1)" ;;
    goldpinger_unhealthy) echo 'sum(goldpinger_nodes_health_total{status="unhealthy"})' ;;
    cilium_max_s)          echo 'max(cilium_node_connectivity_latency_seconds)' ;;
    *) return 1 ;;
  esac
}

# --- дашборд/панель, где видна метрика (для колонки «Дашборд → панель») ---
# Формат: "uid дашборда|Название дашборда|Название панели"
dashboard_panel() {
  case "$1" in
    bulk_err_pct)         echo "elastic-loadgen-app|elastic-loadgen-app|Bulk error rate" ;;
    search_err_pct)       echo "elastic-loadgen-app|elastic-loadgen-app|Search error rate" ;;
    bulk_ok_rps)          echo "elastic-loadgen-app|elastic-loadgen-app|Bulk throughput" ;;
    search_ok_rps)        echo "elastic-loadgen-app|elastic-loadgen-app|Search rate" ;;
    bulk_p99_s)           echo "elastic-loadgen-app|elastic-loadgen-app|Bulk latency (p50/p90/p99)" ;;
    search_p99_s)         echo "elastic-loadgen-app|elastic-loadgen-app|Search latency (p50/p90/p99)" ;;
    es_unassigned)        echo "elasticsearch-cluster|elasticsearch-cluster|unassigned shards" ;;
    es_health_red)        echo "elasticsearch-cluster|elasticsearch-cluster|cluster health: red / yellow" ;;
    es_nodes)             echo "elasticsearch-cluster|elasticsearch-cluster|number of nodes" ;;
    es_queue)             echo "elasticsearch-cluster|elasticsearch-cluster|thread pool: в очереди (по пулам indexing/search)" ;;
    es_pending)           echo "elasticsearch-cluster|elasticsearch-cluster|pending tasks (master queue)" ;;
    es_docs_load)         echo "elasticsearch-cluster|elasticsearch-cluster|documents (всего первичных)" ;;
    es_index_ms)          echo "elasticsearch-cluster|elasticsearch-cluster|indexing время (ms/операцию)" ;;
    es_search_ms)         echo "elasticsearch-cluster|elasticsearch-cluster|search: query + fetch время (ms/операцию)" ;;
    goldpinger_unhealthy) echo "goldpinger|goldpinger|healthy / unhealthy узлов" ;;
    cilium_max_s)         echo "cilium-node-latency|Cilium Node Connectivity Latency|Top 10 per-nodes Cilium ICMP Latency" ;;
    *) return 1 ;;
  esac
}

# --- какие метрики показывать для события (и в тексте, и на графике) ---
# Единый набор на любое событие (chaos и SG): любая метрика, которую AI может
# упомянуть в «Выводе», обязана присутствовать здесь — тогда ссылки на дашборд
# и график гарантированно покрывают текст.
effect_metrics() {
  echo "bulk_err_pct search_err_pct bulk_ok_rps search_ok_rps bulk_p99_s search_p99_s \
es_unassigned es_health_red es_nodes es_queue es_pending es_docs_load es_index_ms es_search_ms \
goldpinger_unhealthy cilium_max_s"
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

link_for() {
  local idx="$1" pre_start="$2" end="$3"; shift 3
  local url; url="$(explore_url "$(( $(epoch "$pre_start") * 1000 ))" "$(( $(epoch "$end") * 1000 ))" "$@")"
  printf '[график](%s)' "$url"
}

# --- ссылка на дашборд за окно pre+event ---
dash_url() {
  local uid="$1" pre_start="$2" end="$3"
  printf '%s/d/%s?from=%s&to=%s' "$GRAFANA_URL" "$uid" "$(( $(epoch "$pre_start") * 1000 ))" "$(( $(epoch "$end") * 1000 ))"
}

# --- ячейка «Дашборд → панель» по списку метрик (панели группируются по дашборду) ---
where_cell() {
  local pre_start="$1" end="$2"; shift 2
  local m map uid dname pname out="" nopanel=""
  local -A dname_of panels_of
  local -a order
  for m in "$@"; do
    if map="$(dashboard_panel "$m" 2>/dev/null)"; then
      uid="$(cut -d'|' -f1 <<<"$map")"
      dname="$(cut -d'|' -f2 <<<"$map")"
      pname="$(cut -d'|' -f3 <<<"$map")"
      if [ -z "${dname_of[$uid]:-}" ]; then order+=("$uid"); dname_of[$uid]="$dname"; fi
      panels_of[$uid]+="«${pname}», "
    else
      nopanel+="\`$m\`, "
    fi
  done
  for uid in "${order[@]}"; do
    out+="[${dname_of[$uid]}]($(dash_url "$uid" "$pre_start" "$end")) → ${panels_of[$uid]%, } ; "
  done
  [ -n "$nopanel" ] && out+="${nopanel%, } — нет панели; "
  printf '%s' "${out%; }"
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
  echo "\`chaos\` (pod-kill/loss/delay/isolate) и \`sg\` (isolate/restore по node group), для каждой"
  echo "запрашивает в VictoriaMetrics метрики эффекта и считает \`pre\`-окно (равное событию, непосредственно перед ним)"
  echo "и \`event\`-окно. Порог «существенное изменение» не задан — значение трактуется по форме кривой, как в README."
  echo
  echo "Колонка **Дашборд → панель** указывает, в каком дашборде и на какой панели видна метрика события;"
  echo "ссылка на дашборд открывается за окно \`pre + event\`. Колонка **График** — ссылка на Grafana Explore"
  echo "(datasource \`$DS_UID\`) с теми же метриками за то же окно. Оба набора метрик задаёт \`effect_metrics\`"
  echo "и они совпадают по построению. \`Вывод\` и раздел «Ключевые находки» дописывает AI по \`analysis.tsv\` и"
  echo "графикам, но **называет только те метрики, что входят в набор события** — иначе упоминание останется"
  echo "без ссылки. Если нужного показателя нет среди метрик события — сначала добавить его в \`effect_metrics\`,"
  echo "\`expr_of\` и \`dashboard_panel\`, затем ссылаться в тексте."
  echo
  echo "> Оговорка: baseline ошибок у loadgen обычно нулевой, рост с нуля даёт \`inf%\`. Низкоуровневые метрики ES"
  echo "> (\`es_nodes\`, \`es_docs_load\`) дискретны и в коротких SG-окнах дают артефакты — читать как «данных мало»."
  echo
  echo "## Сводка по аннотациям"
  echo
  echo "### Chaos-шаги (зона \`$ZONES\`)"
  echo
  echo "| # | Шаг | Дашборд → панель | График | Вывод |"
  echo "|---|---|---|---|---|"
  tail -n +2 "$OUT_DIR/windows.tsv" | sort -t$'\t' -k6,6 | while IFS=$'\t' read -r idx kind zone scope action start end pre_start pre_end; do
    [ -z "${idx:-}" ] && continue
    [ "$kind" = chaos ] || continue
    metric_list="$(effect_metrics "$kind" "$scope" "$action")"
    # shellcheck disable=SC2086
    printf '| %s | %s | %s | %s | _заполняет AI_ |\n' "$idx" "$(label_for "$kind" "$zone" "$scope" "$action")" "$(where_cell "$pre_start" "$end" $metric_list)" "$(link_for "$idx" "$pre_start" "$end" $metric_list)"
  done
  echo
  echo "### Смена security group (зона \`$ZONES\`)"
  echo
  echo "| # | Аннотация | Дашборд → панель | График | Вывод |"
  echo "|---|---|---|---|---|"
  tail -n +2 "$OUT_DIR/windows.tsv" | sort -t$'\t' -k6,6 | while IFS=$'\t' read -r idx kind zone scope action start end pre_start pre_end; do
    [ -z "${idx:-}" ] && continue
    [ "$kind" = sg ] || continue
    metric_list="$(effect_metrics "$kind" "$scope" "$action")"
    # shellcheck disable=SC2086
    printf '| %s | %s | %s | %s | _заполняет AI_ |\n' "$idx" "$(label_for "$kind" "$zone" "$scope" "$action")" "$(where_cell "$pre_start" "$end" $metric_list)" "$(link_for "$idx" "$pre_start" "$end" $metric_list)"
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
