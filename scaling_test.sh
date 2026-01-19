#!/bin/bash
# Run scaling tests with different grid sizes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DURATION=3
ROW_COUNTS="${1:-10 25 50 100 200}"

echo "=============================================="
echo "GPUI Grid Scaling Test"
echo "=============================================="
echo "Row counts: $ROW_COUNTS"
echo "Duration per test: ${DURATION}s"
echo "=============================================="
echo

# Build once
echo "Building project..."
cargo build --release --features fiber -q
echo "Build complete."
echo

RESULTS_FILE=$(mktemp)
echo "rows,cells,total_avg_us,total_p50_us,total_p95_us,prepaint_avg_us,paint_avg_us,exec_per_frame,replay_per_frame" > "$RESULTS_FILE"

for ROWS in $ROW_COUNTS; do
    echo "----------------------------------------"
    echo "Testing with $ROWS rows..."

    LOG_FILE=$(mktemp)
    RUST_LOG="gpui=info" GRID_BENCH_ROWS=$ROWS timeout ${DURATION}s ./target/release/gpui-grid > "$LOG_FILE" 2>&1 || true

    # Extract stats using compatible awk
    STATS=$(awk '
    function parse_time(str, prefix) {
        search = " " prefix "="
        idx = index(str, search)
        if (idx == 0) {
            search = prefix "="
            idx = index(str, search)
            if (idx > 1) {
                prev_char = substr(str, idx - 1, 1)
                if (prev_char != " " && prev_char != "\t") {
                    rest = substr(str, idx + 1)
                    next_idx = index(rest, search)
                    if (next_idx > 0) idx = idx + next_idx
                    else return 0
                }
            }
        } else {
            idx = idx + 1
        }
        if (idx == 0) return 0
        rest = substr(str, idx + length(prefix) + 1)
        match(rest, /^[0-9.]+/)
        if (RSTART > 0) {
            val = substr(rest, RSTART, RLENGTH) + 0
            unit = substr(rest, RSTART + RLENGTH, 2)
            if (unit == "ms") return val * 1000
            if (unit == "ns") return val / 1000
        }
        return val
    }

    /FRAME_END:/ {
        total = parse_time($0, "total")
        prepaint = parse_time($0, "prepaint")
        paint = parse_time($0, "paint")

        frame_count++
        if (frame_count == 1) next

        total_sum += total; total_values[total_count++] = total
        prepaint_sum += prepaint
        paint_sum += paint
    }

    function sort_array(arr, n) {
        for (i = 0; i < n-1; i++) {
            for (j = i+1; j < n; j++) {
                if (arr[i] > arr[j]) { tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp }
            }
        }
    }

    END {
        if (total_count == 0) { print "0 0 0 0 0 0"; exit }
        sort_array(total_values, total_count)
        printf "%.0f %.0f %.0f %.0f %.0f\n",
            total_sum/total_count,
            total_values[int(total_count*0.5)],
            total_values[int(total_count*0.95)],
            prepaint_sum/total_count,
            paint_sum/total_count
    }
    ' "$LOG_FILE")

    read TOTAL_AVG TOTAL_P50 TOTAL_P95 PREPAINT_AVG PAINT_AVG <<< "$STATS"

    # Per-frame prepaint stats
    PREPAINT_STATS=$(awk '
    /FRAME_START/ {
        if (frame > 0) {
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
        if (frames > 0) printf "%.1f %.1f\n", exec_sum/frames, replay_sum/frames
        else print "0 0"
    }
    ' "$LOG_FILE")

    read EXEC_PER_FRAME REPLAY_PER_FRAME <<< "$PREPAINT_STATS"

    # Estimate cell count (cols depends on window width, assume ~25)
    COLS=25
    CELLS=$((ROWS * COLS))

    echo "  Cells: ~$CELLS"
    echo "  Total: avg=${TOTAL_AVG}µs p50=${TOTAL_P50}µs p95=${TOTAL_P95}µs"
    echo "  Prepaint: ${PREPAINT_AVG}µs  Paint: ${PAINT_AVG}µs"
    echo "  Per-frame: exec=${EXEC_PER_FRAME} replay=${REPLAY_PER_FRAME}"

    echo "$ROWS,$CELLS,$TOTAL_AVG,$TOTAL_P50,$TOTAL_P95,$PREPAINT_AVG,$PAINT_AVG,$EXEC_PER_FRAME,$REPLAY_PER_FRAME" >> "$RESULTS_FILE"

    rm -f "$LOG_FILE"
done

echo
echo "=============================================="
echo "Scaling Results Summary"
echo "=============================================="
echo
printf "%-6s %-8s %12s %12s %12s %12s\n" "Rows" "Cells" "Total(avg)" "Prepaint" "Paint" "Exec/Frame"
printf "%-6s %-8s %12s %12s %12s %12s\n" "----" "-----" "----------" "--------" "-----" "----------"

tail -n +2 "$RESULTS_FILE" | while IFS=, read rows cells total_avg total_p50 total_p95 prepaint_avg paint_avg exec replay; do
    printf "%-6s %-8s %10sµs %10sµs %10sµs %12s\n" "$rows" "~$cells" "$total_avg" "$prepaint_avg" "$paint_avg" "$exec"
done

echo
echo "CSV output saved to: $RESULTS_FILE"
echo "View with: cat $RESULTS_FILE"

# Copy to logs dir with timestamp
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROW_LIST=$(echo $ROW_COUNTS | tr ' ' '-')
cp "$RESULTS_FILE" "$SCRIPT_DIR/logs/scaling_rows${ROW_LIST}_${TIMESTAMP}.csv"
echo "Also saved: logs/scaling_rows${ROW_LIST}_${TIMESTAMP}.csv"
