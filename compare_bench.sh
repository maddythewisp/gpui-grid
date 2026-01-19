#!/bin/bash
# Compare two benchmark runs side by side

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <baseline_log> <test_log>"
    echo
    echo "Compares timing statistics between two benchmark runs."
    echo
    echo "Available logs:"
    ls -lth logs/*.log 2>/dev/null | head -10 || echo "  No logs found."
    exit 1
fi

BASELINE="$1"
TEST="$2"

if [ ! -f "$BASELINE" ]; then
    echo "Error: Baseline log not found: $BASELINE"
    exit 1
fi

if [ ! -f "$TEST" ]; then
    echo "Error: Test log not found: $TEST"
    exit 1
fi

# Extract statistics from a log file
extract_stats() {
    local log="$1"

    awk '
    /FRAME_END:/ {
        total = 0; prepaint = 0; paint = 0

        if (match($0, /total=([0-9.]+)ms/)) {
            total = substr($0, RSTART+6, RLENGTH-8) * 1000
        } else if (match($0, /total=([0-9.]+)µs/) || match($0, /total=([0-9.]+)us/)) {
            total = substr($0, RSTART+6, RLENGTH-8)
        }

        if (match($0, /prepaint=([0-9.]+)ms/)) {
            prepaint = substr($0, RSTART+9, RLENGTH-11) * 1000
        } else if (match($0, /prepaint=([0-9.]+)µs/) || match($0, /prepaint=([0-9.]+)us/)) {
            prepaint = substr($0, RSTART+9, RLENGTH-11)
        }

        if (match($0, /paint=([0-9.]+)ms/)) {
            paint = substr($0, RSTART+6, RLENGTH-8) * 1000
        } else if (match($0, /paint=([0-9.]+)µs/) || match($0, /paint=([0-9.]+)us/)) {
            paint = substr($0, RSTART+6, RLENGTH-8)
        }

        frame_count++
        if (frame_count == 1) next  # Skip first frame

        total_sum += total; total_values[total_count++] = total
        prepaint_sum += prepaint; prepaint_values[prepaint_count++] = prepaint
        paint_sum += paint; paint_values[paint_count++] = paint
    }

    function sort_array(arr, n) {
        for (i = 0; i < n-1; i++) {
            for (j = i+1; j < n; j++) {
                if (arr[i] > arr[j]) { tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp }
            }
        }
    }

    END {
        if (total_count == 0) exit

        sort_array(total_values, total_count)
        sort_array(prepaint_values, prepaint_count)
        sort_array(paint_values, paint_count)

        printf "%.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %d\n",
            total_sum/total_count, total_values[int(total_count*0.5)], total_values[int(total_count*0.95)],
            prepaint_sum/prepaint_count, prepaint_values[int(prepaint_count*0.5)], prepaint_values[int(prepaint_count*0.95)],
            paint_sum/paint_count, paint_values[int(paint_count*0.5)], paint_values[int(paint_count*0.95)],
            total_count
    }
    ' "$log"
}

# Get stats
BASELINE_STATS=$(extract_stats "$BASELINE")
TEST_STATS=$(extract_stats "$TEST")

if [ -z "$BASELINE_STATS" ] || [ -z "$TEST_STATS" ]; then
    echo "Error: Could not extract timing data from logs"
    exit 1
fi

# Parse stats
read B_TOTAL_AVG B_TOTAL_P50 B_TOTAL_P95 B_PP_AVG B_PP_P50 B_PP_P95 B_PAINT_AVG B_PAINT_P50 B_PAINT_P95 B_COUNT <<< "$BASELINE_STATS"
read T_TOTAL_AVG T_TOTAL_P50 T_TOTAL_P95 T_PP_AVG T_PP_P50 T_PP_P95 T_PAINT_AVG T_PAINT_P50 T_PAINT_P95 T_COUNT <<< "$TEST_STATS"

# Calculate changes
calc_change() {
    local base=$1
    local test=$2
    if [ "$base" -eq 0 ]; then
        echo "N/A"
    else
        awk "BEGIN { change = (($test - $base) / $base) * 100; printf \"%+.1f%%\", change }"
    fi
}

echo "=============================================="
echo "Benchmark Comparison"
echo "=============================================="
echo "Baseline: $(basename $BASELINE) ($B_COUNT frames)"
echo "Test:     $(basename $TEST) ($T_COUNT frames)"
echo "=============================================="
echo

printf "%-12s %12s %12s %12s\n" "Metric" "Baseline" "Test" "Change"
printf "%-12s %12s %12s %12s\n" "------" "--------" "----" "------"

printf "%-12s %10sµs %10sµs %12s\n" "total avg" "$B_TOTAL_AVG" "$T_TOTAL_AVG" "$(calc_change $B_TOTAL_AVG $T_TOTAL_AVG)"
printf "%-12s %10sµs %10sµs %12s\n" "total p50" "$B_TOTAL_P50" "$T_TOTAL_P50" "$(calc_change $B_TOTAL_P50 $T_TOTAL_P50)"
printf "%-12s %10sµs %10sµs %12s\n" "total p95" "$B_TOTAL_P95" "$T_TOTAL_P95" "$(calc_change $B_TOTAL_P95 $T_TOTAL_P95)"
echo
printf "%-12s %10sµs %10sµs %12s\n" "prepaint avg" "$B_PP_AVG" "$T_PP_AVG" "$(calc_change $B_PP_AVG $T_PP_AVG)"
printf "%-12s %10sµs %10sµs %12s\n" "prepaint p50" "$B_PP_P50" "$T_PP_P50" "$(calc_change $B_PP_P50 $T_PP_P50)"
printf "%-12s %10sµs %10sµs %12s\n" "prepaint p95" "$B_PP_P95" "$T_PP_P95" "$(calc_change $B_PP_P95 $T_PP_P95)"
echo
printf "%-12s %10sµs %10sµs %12s\n" "paint avg" "$B_PAINT_AVG" "$T_PAINT_AVG" "$(calc_change $B_PAINT_AVG $T_PAINT_AVG)"
printf "%-12s %10sµs %10sµs %12s\n" "paint p50" "$B_PAINT_P50" "$T_PAINT_P50" "$(calc_change $B_PAINT_P50 $T_PAINT_P50)"
printf "%-12s %10sµs %10sµs %12s\n" "paint p95" "$B_PAINT_P95" "$T_PAINT_P95" "$(calc_change $B_PAINT_P95 $T_PAINT_P95)"
echo

# Prepaint cache stats comparison
B_EXEC=$(grep -c "PREPAINT_EXEC" "$BASELINE" 2>/dev/null || echo 0)
B_REPLAY=$(grep -c "PREPAINT_REPLAY" "$BASELINE" 2>/dev/null || echo 0)
T_EXEC=$(grep -c "PREPAINT_EXEC" "$TEST" 2>/dev/null || echo 0)
T_REPLAY=$(grep -c "PREPAINT_REPLAY" "$TEST" 2>/dev/null || echo 0)

echo "Prepaint Cache:"
printf "%-12s %12s %12s %12s\n" "exec total" "$B_EXEC" "$T_EXEC" "$(calc_change $B_EXEC $T_EXEC)"
printf "%-12s %12s %12s %12s\n" "replay total" "$B_REPLAY" "$T_REPLAY" "$(calc_change $B_REPLAY $T_REPLAY)"
echo

# Summary
IMPROVEMENT=$(awk "BEGIN { printf \"%.1f\", (1 - $T_TOTAL_AVG / $B_TOTAL_AVG) * 100 }")
if (( $(echo "$T_TOTAL_AVG < $B_TOTAL_AVG" | bc -l) )); then
    echo "Result: Test is ${IMPROVEMENT#-}% FASTER"
else
    echo "Result: Test is ${IMPROVEMENT#-}% SLOWER"
fi
