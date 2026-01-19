#!/bin/bash
# Helper script to analyze benchmark logs

if [ -z "$1" ]; then
    echo "Usage: $0 <log_file> [--csv]"
    echo
    echo "Options:"
    echo "  --csv    Output results in CSV format for comparison"
    echo
    echo "Available logs:"
    ls -lth logs/*.log 2>/dev/null | head -10 || echo "  No logs found. Run ./run_bench.sh first."
    exit 1
fi

LOG_FILE="$1"
CSV_MODE=false
if [ "$2" = "--csv" ]; then
    CSV_MODE=true
fi

if [ ! -f "$LOG_FILE" ]; then
    echo "Error: Log file not found: $LOG_FILE"
    exit 1
fi

# Extract frame timing data into a temp file for processing
TIMING_DATA=$(mktemp)
grep "FRAME_END:" "$LOG_FILE" | sed 's/.*total=//' | while read line; do
    # Extract: total, layout, prepaint, paint (convert to microseconds)
    total=$(echo "$line" | grep -o 'total=[^ ]*' | sed 's/total=//' | sed 's/[^0-9.]//g')
    layout=$(echo "$line" | grep -o 'layout=[^ ]*' | sed 's/layout=//' | sed 's/[^0-9.]//g')
    prepaint=$(echo "$line" | grep -o 'prepaint=[^ ]*' | sed 's/prepaint=//' | sed 's/[^0-9.]//g')
    paint=$(echo "$line" | grep -o 'paint=[^ ]*' | sed 's/paint=//' | sed 's/[^0-9.]//g')

    # Handle different time units (ms vs µs vs ns)
    if echo "$line" | grep -q 'total=[0-9.]*ms'; then
        total=$(awk "BEGIN {printf \"%.0f\", $total * 1000}")
    elif echo "$line" | grep -q 'total=[0-9.]*ns'; then
        total=$(awk "BEGIN {printf \"%.0f\", $total / 1000}")
    fi

    echo "$total $layout $prepaint $paint"
done > "$TIMING_DATA"

# Function to compute statistics from a column
compute_stats() {
    local col=$1
    local label=$2

    awk -v col=$col -v label="$label" '
    BEGIN { count=0; sum=0; min=999999999; max=0 }
    {
        val = $col
        if (val ~ /[0-9]/ && val > 0) {
            values[count++] = val
            sum += val
            if (val < min) min = val
            if (val > max) max = val
        }
    }
    END {
        if (count == 0) { print label ": no data"; exit }

        avg = sum / count

        # Sort for percentiles
        for (i = 0; i < count-1; i++) {
            for (j = i+1; j < count; j++) {
                if (values[i] > values[j]) {
                    tmp = values[i]
                    values[i] = values[j]
                    values[j] = tmp
                }
            }
        }

        p50_idx = int(count * 0.5)
        p95_idx = int(count * 0.95)
        p99_idx = int(count * 0.99)

        p50 = values[p50_idx]
        p95 = values[p95_idx]
        p99 = values[p99_idx]

        printf "%s: avg=%.0fµs p50=%.0fµs p95=%.0fµs p99=%.0fµs min=%.0fµs max=%.0fµs (n=%d)\n",
               label, avg, p50, p95, p99, min, max, count
    }
    ' "$TIMING_DATA"
}

# Count frames and skip first frame (initial render)
FRAME_COUNT=$(wc -l < "$TIMING_DATA" | xargs)
STEADY_STATE_DATA=$(mktemp)
tail -n +2 "$TIMING_DATA" > "$STEADY_STATE_DATA"
STEADY_FRAME_COUNT=$((FRAME_COUNT - 1))

if $CSV_MODE; then
    # CSV output for comparison
    echo "metric,avg_us,p50_us,p95_us,p99_us,min_us,max_us,count"

    # Parse each metric and output as CSV
    for metric in "total:1" "prepaint:3" "paint:4"; do
        label=$(echo $metric | cut -d: -f1)
        col=$(echo $metric | cut -d: -f2)

        awk -v col=$col -v label="$label" '
        BEGIN { count=0; sum=0; min=999999999; max=0 }
        {
            val = $col
            if (val ~ /[0-9]/ && val > 0) {
                values[count++] = val
                sum += val
                if (val < min) min = val
                if (val > max) max = val
            }
        }
        END {
            if (count == 0) exit
            avg = sum / count
            for (i = 0; i < count-1; i++) {
                for (j = i+1; j < count; j++) {
                    if (values[i] > values[j]) { tmp = values[i]; values[i] = values[j]; values[j] = tmp }
                }
            }
            p50 = values[int(count * 0.5)]
            p95 = values[int(count * 0.95)]
            p99 = values[int(count * 0.99)]
            printf "%s,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%d\n", label, avg, p50, p95, p99, min, max, count
        }
        ' "$STEADY_STATE_DATA"
    done

    # Prepaint stats
    EXEC_COUNT=$(grep -c "PREPAINT_EXEC" "$LOG_FILE" 2>/dev/null || echo 0)
    REPLAY_COUNT=$(grep -c "PREPAINT_REPLAY" "$LOG_FILE" 2>/dev/null || echo 0)
    echo "prepaint_exec,$EXEC_COUNT,,,,,,$FRAME_COUNT"
    echo "prepaint_replay,$REPLAY_COUNT,,,,,,$FRAME_COUNT"

    rm -f "$TIMING_DATA" "$STEADY_STATE_DATA"
    exit 0
fi

echo "===================================="
echo "Log Analysis: $(basename $LOG_FILE)"
echo "===================================="
echo

echo "Frame Timing Statistics (steady-state, skipping first frame):"
echo "--------------------------------------------------------------"

# Parse FRAME_END lines properly
awk '
function parse_time(str, prefix) {
    # Find the value after prefix= (ensure we match exact prefix with space before)
    search = " " prefix "="
    idx = index(str, search)
    if (idx == 0) {
        # Try at start of line or after other chars
        search = prefix "="
        idx = index(str, search)
        # Make sure this isnt a suffix match (e.g. "prepaint" matching "paint")
        if (idx > 1) {
            prev_char = substr(str, idx - 1, 1)
            if (prev_char != " " && prev_char != "\t") {
                # Find next occurrence
                rest = substr(str, idx + 1)
                next_idx = index(rest, search)
                if (next_idx > 0) {
                    idx = idx + next_idx
                } else {
                    return 0
                }
            }
        }
    } else {
        idx = idx + 1  # skip the leading space
    }
    if (idx == 0) return 0

    # Extract the number and unit
    rest = substr(str, idx + length(prefix) + 1)
    val = 0
    unit = ""

    # Parse number
    match(rest, /^[0-9.]+/)
    if (RSTART > 0) {
        val = substr(rest, RSTART, RLENGTH) + 0
        unit = substr(rest, RSTART + RLENGTH, 2)
    }

    # Convert to microseconds
    if (unit == "ms") return val * 1000
    if (unit == "ns") return val / 1000
    return val  # assume µs or us
}

/FRAME_END:/ {
    total = parse_time($0, "total")
    prepaint = parse_time($0, "prepaint")
    paint = parse_time($0, "paint")

    frame_count++

    # Skip first frame (initial render)
    if (frame_count == 1) next

    # Accumulate stats
    total_sum += total; total_values[total_count++] = total
    if (total < total_min || total_min == 0) total_min = total
    if (total > total_max) total_max = total

    prepaint_sum += prepaint; prepaint_values[prepaint_count++] = prepaint
    if (prepaint < prepaint_min || prepaint_min == 0) prepaint_min = prepaint
    if (prepaint > prepaint_max) prepaint_max = prepaint

    paint_sum += paint; paint_values[paint_count++] = paint
    if (paint < paint_min || paint_min == 0) paint_min = paint
    if (paint > paint_max) paint_max = paint
}

function sort_array(arr, n) {
    for (i = 0; i < n-1; i++) {
        for (j = i+1; j < n; j++) {
            if (arr[i] > arr[j]) {
                tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp
            }
        }
    }
}

function percentile(arr, n, p) {
    sort_array(arr, n)
    idx = int(n * p)
    if (idx >= n) idx = n - 1
    return arr[idx]
}

END {
    if (total_count == 0) {
        print "  No frame timing data found"
        exit
    }

    printf "  Total frames:  %d (analyzed %d steady-state)\n", frame_count, total_count
    printf "\n"

    # Sort arrays for percentiles
    sort_array(total_values, total_count)
    sort_array(prepaint_values, prepaint_count)
    sort_array(paint_values, paint_count)

    total_p50 = total_values[int(total_count * 0.5)]
    total_p95 = total_values[int(total_count * 0.95)]
    total_p99 = total_values[int(total_count * 0.99)]

    prepaint_p50 = prepaint_values[int(prepaint_count * 0.5)]
    prepaint_p95 = prepaint_values[int(prepaint_count * 0.95)]
    prepaint_p99 = prepaint_values[int(prepaint_count * 0.99)]

    paint_p50 = paint_values[int(paint_count * 0.5)]
    paint_p95 = paint_values[int(paint_count * 0.95)]
    paint_p99 = paint_values[int(paint_count * 0.99)]

    printf "  %-10s avg=%7.0fµs  p50=%7.0fµs  p95=%7.0fµs  p99=%7.0fµs  max=%7.0fµs\n",
           "TOTAL:", total_sum/total_count, total_p50, total_p95, total_p99, total_max
    printf "  %-10s avg=%7.0fµs  p50=%7.0fµs  p95=%7.0fµs  p99=%7.0fµs  max=%7.0fµs\n",
           "prepaint:", prepaint_sum/prepaint_count, prepaint_p50, prepaint_p95, prepaint_p99, prepaint_max
    printf "  %-10s avg=%7.0fµs  p50=%7.0fµs  p95=%7.0fµs  p99=%7.0fµs  max=%7.0fµs\n",
           "paint:", paint_sum/paint_count, paint_p50, paint_p95, paint_p99, paint_max
}
' "$LOG_FILE"

echo

echo "Prepaint Cache Statistics:"
echo "--------------------------"
EXEC_TOTAL=$(grep -c "PREPAINT_EXEC" "$LOG_FILE" 2>/dev/null || echo 0)
REPLAY_TOTAL=$(grep -c "PREPAINT_REPLAY" "$LOG_FILE" 2>/dev/null || echo 0)

# Per-frame breakdown (skip first frame)
awk '
/FRAME_START/ {
    if (frame > 0 && (exec_count > 0 || replay_count > 0)) {
        frames++
        exec_sum += exec_count
        replay_sum += replay_count
    }
    frame++
    exec_count = 0
    replay_count = 0
}
/PREPAINT_EXEC/ { exec_count++ }
/PREPAINT_REPLAY/ { replay_count++ }
END {
    if (frames > 0) {
        printf "  Per-frame (steady-state): EXEC=%.1f  REPLAY=%.1f\n", exec_sum/frames, replay_sum/frames
    }
    printf "  Total: EXEC=%d  REPLAY=%d\n", exec_sum + exec_count, replay_sum + replay_count
}
' "$LOG_FILE"

echo

echo "Fiber Reconciliation:"
echo "--------------------"
RECONCILE_TOTAL=$(grep -c "FIBER_RECONCILE:" "$LOG_FILE" 2>/dev/null || echo 0)
RECONCILE_CHANGES=$(grep -c "FIBER_RECONCILE_CHANGE" "$LOG_FILE" 2>/dev/null || echo 0)
BAILOUT_TOTAL=$(grep -c "RECONCILE_BAILOUT" "$LOG_FILE" 2>/dev/null || echo 0)

echo "  Total reconciliations: $RECONCILE_TOTAL"
echo "  Bailouts: $BAILOUT_TOTAL"
echo "  Changes detected: $RECONCILE_CHANGES"

# Unique fibers that changed
if [ $RECONCILE_CHANGES -gt 0 ]; then
    UNIQUE_CHANGED=$(grep "FIBER_RECONCILE_CHANGE" "$LOG_FILE" | sed 's/.*id=\([^ ]*\).*/\1/' | sort -u | wc -l | xargs)
    echo "  Unique fibers changed: $UNIQUE_CHANGED"
fi

# Per-frame reconciliation stats
# Collect all frame counts, then report median and show if first few frames are outliers
awk '
/FRAME_START/ {
    if (frame > 0 && reconcile_count > 0) {
        frames++
        frame_reconciles[frames] = reconcile_count
        frame_bailouts[frames] = bailout_count
        reconcile_sum += reconcile_count
        bailout_sum += bailout_count
        if (reconcile_count > 100) {
            outlier_frames++
        } else {
            steady_reconcile_sum += reconcile_count
            steady_bailout_sum += bailout_count
            steady_frames++
        }
    }
    frame++
    reconcile_count = 0
    bailout_count = 0
}
/FIBER_RECONCILE:/ { reconcile_count++ }
/RECONCILE_BAILOUT/ { bailout_count++ }
END {
    if (frames > 0) {
        printf "  Per-frame (all): reconciles=%.1f  bailouts=%.1f  (frames=%d)\n", reconcile_sum/frames, bailout_sum/frames, frames
        if (outlier_frames > 0 && steady_frames > 0) {
            printf "  Per-frame (steady): reconciles=%.1f  bailouts=%.1f  (frames=%d, outliers=%d)\n", steady_reconcile_sum/steady_frames, steady_bailout_sum/steady_frames, steady_frames, outlier_frames
        }
    }
}
' "$LOG_FILE"

echo

echo "Sample Frame Timings (last 10 steady-state):"
echo "---------------------------------------------"
grep "FRAME_END:" "$LOG_FILE" | tail -11 | head -10 | while read line; do
    echo "$line" | sed 's/.*FRAME_END:/  /'
done
echo

rm -f "$TIMING_DATA" "$STEADY_STATE_DATA" 2>/dev/null

echo "===================================="
echo "Quick Commands:"
echo "===================================="
echo "  Compare runs:  ./compare_bench.sh log1.log log2.log"
echo "  CSV export:    $0 $LOG_FILE --csv > results.csv"
echo
