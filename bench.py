#!/usr/bin/env python3
"""
Benchmark harness for gpui-grid frame timing analysis.

Usage:
    python bench.py [--duration SECONDS] [--debug] [--compare]
"""

import subprocess
import time
import csv
import sys
import os
import signal
from pathlib import Path
from dataclasses import dataclass
from typing import Optional

@dataclass
class FrameStats:
    total_frames: int
    layout_skipped: int  # frames with 0 layout_fibers
    layout_needed: int   # frames with >0 layout_fibers
    avg_layout_us_skipped: float
    avg_layout_us_needed: float
    avg_total_us: float
    p50_total_us: float
    p95_total_us: float
    p99_total_us: float

def run_benchmark(duration_secs: float = 5.0, debug: bool = False, build: bool = True) -> Optional[Path]:
    """Run the benchmark for the specified duration and return the CSV path."""

    grid_dir = Path(__file__).parent
    csv_filename = "frame_log_debug.csv" if debug else "frame_log_release.csv"
    csv_path = grid_dir / csv_filename

    # Remove old CSV
    if csv_path.exists():
        csv_path.unlink()

    profile = [] if debug else ["--release"]
    profile_name = "debug" if debug else "release"

    # Build if requested
    if build:
        print(f"Building gpui-grid ({profile_name}, fiber feature)...")
        cmd = ["cargo", "build", "-q", "--features", "fiber"] + profile
        result = subprocess.run(
            cmd,
            cwd=grid_dir,
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            print(f"Build failed: {result.stderr}")
            return None

    # Run the benchmark
    print(f"Running benchmark for {duration_secs}s ({profile_name})...")
    cmd = ["cargo", "run", "-q", "--features", "fiber"] + profile
    proc = subprocess.Popen(
        cmd,
        cwd=grid_dir,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        preexec_fn=os.setsid
    )

    time.sleep(duration_secs)

    # Gracefully terminate
    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        proc.wait()

    # Check if CSV was created
    if not csv_path.exists():
        print(f"Warning: {csv_filename} not created")
        return None

    return csv_path

def analyze_csv(csv_path: Path) -> Optional[FrameStats]:
    """Analyze the frame timing CSV and return statistics."""

    frames = []
    with open(csv_path, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            frames.append({
                'frame': int(row['frame']),
                'layout_fibers': int(row['layout_fibers']),
                'layout_us': int(row['layout_us']),
                'total_us': int(row['total_us']),
            })

    if len(frames) < 10:
        print(f"Warning: Only {len(frames)} frames captured")
        return None

    # Skip first few frames (warmup)
    frames = frames[5:]

    skipped = [f for f in frames if f['layout_fibers'] == 0]
    needed = [f for f in frames if f['layout_fibers'] > 0]

    total_times = sorted([f['total_us'] for f in frames])
    n = len(total_times)

    return FrameStats(
        total_frames=len(frames),
        layout_skipped=len(skipped),
        layout_needed=len(needed),
        avg_layout_us_skipped=sum(f['layout_us'] for f in skipped) / len(skipped) if skipped else 0,
        avg_layout_us_needed=sum(f['layout_us'] for f in needed) / len(needed) if needed else 0,
        avg_total_us=sum(f['total_us'] for f in frames) / len(frames),
        p50_total_us=total_times[n // 2],
        p95_total_us=total_times[int(n * 0.95)],
        p99_total_us=total_times[int(n * 0.99)],
    )

def print_stats(stats: FrameStats, label: str = ""):
    """Print formatted statistics."""
    if label:
        print(f"\n{'='*60}")
        print(f"  {label}")
        print(f"{'='*60}")

    pct_skipped = 100*stats.layout_skipped/stats.total_frames if stats.total_frames > 0 else 0
    pct_needed = 100*stats.layout_needed/stats.total_frames if stats.total_frames > 0 else 0

    print(f"\nFrames analyzed: {stats.total_frames}")
    print(f"  Layout skipped (probe pass success): {stats.layout_skipped} ({pct_skipped:.1f}%)")
    print(f"  Layout needed:                       {stats.layout_needed} ({pct_needed:.1f}%)")

    print(f"\nLayout time (µs):")
    print(f"  When skipped: {stats.avg_layout_us_skipped:.1f} µs avg")
    print(f"  When needed:  {stats.avg_layout_us_needed:.1f} µs avg")

    print(f"\nTotal frame time (µs):")
    print(f"  Average: {stats.avg_total_us:.1f} µs")
    print(f"  p50:     {stats.p50_total_us} µs")
    print(f"  p95:     {stats.p95_total_us} µs")
    print(f"  p99:     {stats.p99_total_us} µs")

def compare_stats(before: FrameStats, after: FrameStats):
    """Print comparison between two benchmark runs."""
    print(f"\n{'='*60}")
    print(f"  COMPARISON: Before vs After Optimization")
    print(f"{'='*60}")

    print(f"\nLayout skipped:")
    print(f"  Before: {before.layout_skipped} ({100*before.layout_skipped/before.total_frames:.1f}%)")
    print(f"  After:  {after.layout_skipped} ({100*after.layout_skipped/after.total_frames:.1f}%)")

    print(f"\nAvg layout time when needed:")
    print(f"  Before: {before.avg_layout_us_needed:.1f} µs")
    print(f"  After:  {after.avg_layout_us_needed:.1f} µs")

    print(f"\nAvg total frame time:")
    print(f"  Before: {before.avg_total_us:.1f} µs")
    print(f"  After:  {after.avg_total_us:.1f} µs")
    if before.avg_total_us > 0:
        improvement = (before.avg_total_us - after.avg_total_us) / before.avg_total_us * 100
        print(f"  Improvement: {improvement:.1f}%")

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Benchmark gpui-grid frame timing")
    parser.add_argument("--duration", type=float, default=5.0, help="Benchmark duration in seconds")
    parser.add_argument("--debug", action="store_true", help="Run in debug mode instead of release")
    parser.add_argument("--no-build", action="store_true", help="Skip cargo build")
    parser.add_argument("--analyze-only", type=str, help="Only analyze existing CSV file")
    parser.add_argument("--compare", action="store_true", help="Run both debug and release for comparison")
    args = parser.parse_args()

    if args.analyze_only:
        csv_path = Path(args.analyze_only)
        if not csv_path.exists():
            print(f"File not found: {csv_path}")
            sys.exit(1)
        stats = analyze_csv(csv_path)
        if stats:
            print_stats(stats, f"Analysis of {csv_path.name}")
        sys.exit(0)

    if args.compare:
        # Run both modes for comparison
        print("Running comparison benchmark...")

        release_csv = run_benchmark(args.duration, debug=False, build=not args.no_build)
        if release_csv is None:
            sys.exit(1)
        release_stats = analyze_csv(release_csv)

        debug_csv = run_benchmark(args.duration, debug=True, build=not args.no_build)
        if debug_csv is None:
            sys.exit(1)
        debug_stats = analyze_csv(debug_csv)

        if release_stats:
            print_stats(release_stats, f"Release build ({args.duration}s)")
        if debug_stats:
            print_stats(debug_stats, f"Debug build ({args.duration}s)")

        sys.exit(0)

    # Single run
    csv_path = run_benchmark(args.duration, debug=args.debug, build=not args.no_build)
    if csv_path is None:
        sys.exit(1)

    stats = analyze_csv(csv_path)
    if stats is None:
        sys.exit(1)

    mode = "debug" if args.debug else "release"
    print_stats(stats, f"gpui-grid benchmark ({mode}, {args.duration}s)")

if __name__ == "__main__":
    main()
