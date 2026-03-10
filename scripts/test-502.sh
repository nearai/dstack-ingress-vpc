#!/bin/bash
# Test script to reproduce intermittent 502s on cloud API ingress
# Usage: ./test-502.sh [URL] [TOTAL_REQUESTS] [CONCURRENCY]

URL="${1:-https://cloud-stg-api.near.ai/v1/model/list}"
TOTAL="${2:-200}"
CONCURRENCY="${3:-10}"

echo "Target:      $URL"
echo "Requests:    $TOTAL"
echo "Concurrency: $CONCURRENCY"
echo "---"

count_200=0
count_502=0
count_000=0
count_other=0
start=$(date +%s)

run_request() {
    curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$URL"
}

# Run requests in batches of $CONCURRENCY
for ((i = 0; i < TOTAL; i += CONCURRENCY)); do
    batch_size=$((TOTAL - i < CONCURRENCY ? TOTAL - i : CONCURRENCY))
    codes=()
    for ((j = 0; j < batch_size; j++)); do
        codes[$j]=$(run_request) &
    done
    wait

    # Collect results from background jobs - re-run to get actual codes
    # (above just spawns, need to capture output properly)
    :
done

# Simpler approach: use temp file for results
RESULTS=$(mktemp)
trap 'rm -f "$RESULTS"' EXIT

for ((i = 0; i < TOTAL; i += CONCURRENCY)); do
    batch_size=$((TOTAL - i < CONCURRENCY ? TOTAL - i : CONCURRENCY))
    for ((j = 0; j < batch_size; j++)); do
        (curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 "$URL" >> "$RESULTS") &
    done
    wait
    completed=$((i + batch_size))
    printf "\r[%d/%d] " "$completed" "$TOTAL"
done
echo ""

elapsed=$(( $(date +%s) - start ))

echo "---"
echo "Results (${elapsed}s elapsed):"
sort "$RESULTS" | uniq -c | sort -rn | while read count code; do
    pct=$(echo "scale=1; $count * 100 / $TOTAL" | bc)
    case "$code" in
        200) label="OK" ;;
        502) label="Bad Gateway" ;;
        000) label="Connection failed" ;;
        *)   label="" ;;
    esac
    printf "  %s: %d (%s%%) %s\n" "$code" "$count" "$pct" "$label"
done

total_fail=$(grep -cv '^200$' "$RESULTS" 2>/dev/null || echo 0)
if [ "$total_fail" -gt 0 ]; then
    fail_pct=$(echo "scale=1; $total_fail * 100 / $TOTAL" | bc)
    echo ""
    echo "FAIL: ${total_fail}/${TOTAL} requests failed (${fail_pct}%)"
    exit 1
else
    echo ""
    echo "PASS: all requests succeeded"
    exit 0
fi
