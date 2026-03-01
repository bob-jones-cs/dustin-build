#!/usr/bin/env python3
"""
Analyze profiling CSV data from dustin gameplay sessions.

The dustin engine can emit per-frame and per-event profiling data when built
with the PROFILING compile flag (see project.xml).  During gameplay, PlayState
records timing for each update phase and writes two CSV files on exit:

    profiling_frames.csv  – one row per rendered frame
    profiling_events.csv  – one row per chart event execution

This script reads those CSVs and prints a human-readable summary including:

  * Overall frame count, duration, and average FPS
  * Slow-frame histogram at configurable thresholds
  * Per-phase average breakdown (scripts, rating, camera, draw, …)
  * GC collection count and memory growth rates
  * Worst individual frames with per-phase attribution
  * Slow chart-event listing

Usage
-----
    python3 analyze_profiling.py [OPTIONS] [FRAMES_CSV]

    FRAMES_CSV defaults to ``profiling/profiling_frames.csv`` (the engine
    default output location).  The companion events CSV is resolved
    automatically by replacing ``profiling_frames`` with ``profiling_events``
    in the same directory.

Options
-------
    -s, --song NAME
        Song name shown in the report header (default: "SONG").

    -n, --top N
        Maximum number of slow frames / events to display (default: 20).

    --slow THRESHOLD[,THRESHOLD,...]
        Comma-separated millisecond thresholds for the slow-frame histogram
        (default: 12,16,25).

    --event-threshold MS
        Minimum duration in milliseconds for an event to be listed as slow
        (default: 2.0).

    --phase-threshold MS
        Minimum per-phase millisecond value for a phase to appear in the
        per-frame breakdown (default: 1.0).

    --script-warn MS
        Print a warning count for frames where ``scripts_pre`` exceeds this
        many milliseconds (default: 3.0).

    -h, --help
        Show this help message and exit.

Examples
--------
    # Analyze the default profiling output after a gameplay session:
    python3 building/analyze_profiling.py

    # Specify a custom CSV and song name:
    python3 building/analyze_profiling.py -s "Haunted" profiling/profiling_frames.csv

    # Tighter thresholds for a 120-FPS target:
    python3 building/analyze_profiling.py --slow 8,12,16 --event-threshold 1

CSV Schema (profiling_frames.csv)
---------------------------------
The engine writes the following columns (see PlayState.__profRecordFrame):

    frame, wall_s, song_ms, elapsed_ms,
    scripts_pre_ms, rating_ms, cam_zoom_ms, icons_ms, sync_ms,
    events_ms, camera_ms, input_ms, super_update_ms, scripts_post_ms,
    draw_ms, total_ms,
    mem_mb, gc_current_mb, gc_reserved_mb,
    draw_scripts_ms, draw_super_ms, draw_post_ms,
    frame_gap_ms, gc_current_start_mb,
    tween_count, display_count

CSV Schema (profiling_events.csv)
---------------------------------
    frame, song_ms, event_name, event_time_ms, duration_ms
"""

from __future__ import annotations

import argparse
import csv
import os
import sys
from typing import Any


# ---------------------------------------------------------------------------
# Phases recorded by PlayState (order matches the update loop)
# ---------------------------------------------------------------------------
UPDATE_PHASES = [
    "scripts_pre_ms",
    "rating_ms",
    "cam_zoom_ms",
    "icons_ms",
    "sync_ms",
    "events_ms",
    "camera_ms",
    "input_ms",
    "super_update_ms",
    "scripts_post_ms",
    "draw_ms",
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _coerce_numbers(row: dict[str, Any]) -> None:
    """Convert all numeric-looking values in *row* to ``float`` in-place."""
    for key in row:
        try:
            row[key] = float(row[key])
        except (ValueError, TypeError):
            pass


def _resolve_events_path(frames_path: str) -> str:
    """Derive the events CSV path from the frames CSV path."""
    directory = os.path.dirname(frames_path)
    return os.path.join(directory, "profiling_events.csv")


def _parse_thresholds(raw: str) -> list[float]:
    """Parse a comma-separated list of threshold values."""
    return sorted(float(t) for t in raw.split(","))


# ---------------------------------------------------------------------------
# Core analysis
# ---------------------------------------------------------------------------

def load_frames(path: str) -> list[dict[str, Any]]:
    """Read and coerce the frames CSV."""
    with open(path, newline="") as fh:
        rows = list(csv.DictReader(fh))
    for row in rows:
        _coerce_numbers(row)
    return rows


def load_events(path: str) -> list[dict[str, Any]]:
    """Read and coerce the events CSV (returns empty list on failure)."""
    try:
        with open(path, newline="") as fh:
            rows = list(csv.DictReader(fh))
        for row in rows:
            _coerce_numbers(row)
        return rows
    except (FileNotFoundError, OSError):
        return []


def print_summary(
    rows: list[dict[str, Any]],
    events: list[dict[str, Any]],
    *,
    song_name: str,
    top_n: int,
    slow_thresholds: list[float],
    event_threshold: float,
    phase_threshold: float,
    script_warn_threshold: float,
) -> None:
    """Print the full profiling report to stdout."""

    total_frames = len(rows)
    first, last = rows[0], rows[-1]
    duration_s = max(last["wall_s"] - first["wall_s"], 0.001)
    max_song_ms = max(r["song_ms"] for r in rows)

    # -- Slow-frame buckets ---------------------------------------------------
    slow_buckets = {t: [r for r in rows if r["total_ms"] > t] for t in slow_thresholds}
    max_frame = max(rows, key=lambda r: r["total_ms"])

    # -- GC -------------------------------------------------------------------
    gc_collections = sum(
        1 for r in rows if r["gc_current_mb"] < r["gc_current_start_mb"] - 1
    )
    active_last = max(rows, key=lambda r: r["song_ms"])
    gc_res_growth = active_last["gc_reserved_mb"] - first["gc_reserved_mb"]
    gc_cur_growth = active_last["gc_current_mb"] - first["gc_current_mb"]

    # -- Phase averages -------------------------------------------------------
    phase_avgs = {
        p: sum(r[p] for r in rows) / total_frames for p in UPDATE_PHASES
    }
    total_avg = sum(r["total_ms"] for r in rows) / total_frames

    # -- Header ---------------------------------------------------------------
    print()
    print("=" * 60)
    print(f"  {song_name.upper()} PROFILING SUMMARY")
    print("=" * 60)
    print(
        f"Total frames: {total_frames} | "
        f"Duration: {duration_s:.1f}s | "
        f"Song length: {max_song_ms / 1000:.1f}s"
    )
    print(f"Avg FPS: {total_frames / duration_s:.1f}")

    slow_parts = " | ".join(
        f">{t:.0f}ms={len(slow_buckets[t])}" for t in slow_thresholds
    )
    print(f"Slow frames: {slow_parts}")
    print(
        f"Max frame: {max_frame['total_ms']:.1f}ms "
        f"(frame {int(max_frame['frame'])} at song {max_frame['song_ms']:.0f}ms)"
    )
    print(f"GC collections: {gc_collections}")

    # -- Memory ---------------------------------------------------------------
    print()
    print(
        f"gc_reserved: {first['gc_reserved_mb']:.0f} -> "
        f"{active_last['gc_reserved_mb']:.0f} MB "
        f"({gc_res_growth / duration_s:.1f} MB/s)"
    )
    print(
        f"gc_current:  {first['gc_current_mb']:.0f} -> "
        f"{active_last['gc_current_mb']:.0f} MB "
        f"({gc_cur_growth / duration_s:.2f} MB/s)"
    )

    # -- Phase breakdown ------------------------------------------------------
    print()
    print("--- Average phase breakdown (ms/frame) ---")
    for phase in UPDATE_PHASES:
        label = phase.removesuffix("_ms")
        print(f"  {label:<16s}: {phase_avgs[phase]:.3f}")
    print(f"  {'TOTAL':<16s}: {total_avg:.3f}")

    # -- Slow frames ----------------------------------------------------------
    lowest_threshold = slow_thresholds[0] if slow_thresholds else 12
    slow_all = [r for r in rows if r["total_ms"] > lowest_threshold]
    if slow_all:
        print()
        print(
            f"--- Slow frames >{lowest_threshold:.0f}ms "
            f"(showing up to {top_n}) ---"
        )
        for r in sorted(slow_all, key=lambda r: -r["total_ms"])[:top_n]:
            parts: list[str] = []
            for phase in UPDATE_PHASES:
                val = r[phase]
                if val > phase_threshold:
                    parts.append(f"{phase.removesuffix('_ms')}={int(val)}")

            gc_note = ""
            if r["gc_current_mb"] < r["gc_current_start_mb"] - 1:
                gc_note = (
                    f" GC({r['gc_current_start_mb']:.0f}"
                    f"->{r['gc_current_mb']:.0f}MB)"
                )

            gap_note = ""
            if r["frame_gap_ms"] > 5:
                gap_note = f" gap={int(r['frame_gap_ms'])}"

            print(
                f"  frame {int(r['frame']):6d} @ {r['song_ms']:8.0f}ms: "
                f"{r['total_ms']:5.1f}ms [{', '.join(parts)}]{gc_note}{gap_note}"
            )

    # -- Slow events ----------------------------------------------------------
    if events:
        slow_events = [e for e in events if e["duration_ms"] > event_threshold]
        if slow_events:
            print()
            print(
                f"--- Slow events >{event_threshold:.0f}ms "
                f"({len(slow_events)} of {len(events)}) ---"
            )
            for e in sorted(slow_events, key=lambda e: -e["duration_ms"])[:top_n]:
                print(
                    f"  {e['event_name']:<30s} at {float(e['song_ms']):8.0f}ms: "
                    f"{e['duration_ms']:.1f}ms"
                )

    # -- Script-heavy frames --------------------------------------------------
    script_heavy = [
        r for r in rows if r["scripts_pre_ms"] > script_warn_threshold
    ]
    if script_heavy:
        print()
        print(
            f"--- Frames with scripts_pre >{script_warn_threshold:.0f}ms: "
            f"{len(script_heavy)} ---"
        )

    print()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Analyze profiling CSV data from a dustin gameplay session.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "frames_csv",
        nargs="?",
        default=os.path.join("profiling", "profiling_frames.csv"),
        help=(
            "Path to the frames CSV "
            "(default: profiling/profiling_frames.csv)"
        ),
    )
    parser.add_argument(
        "-s", "--song",
        default="SONG",
        help="Song name shown in the report header (default: SONG)",
    )
    parser.add_argument(
        "-n", "--top",
        type=int,
        default=20,
        help="Max slow frames / events to display (default: 20)",
    )
    parser.add_argument(
        "--slow",
        default="12,16,25",
        help=(
            "Comma-separated ms thresholds for slow-frame histogram "
            "(default: 12,16,25)"
        ),
    )
    parser.add_argument(
        "--event-threshold",
        type=float,
        default=2.0,
        help="Min ms for an event to be listed as slow (default: 2.0)",
    )
    parser.add_argument(
        "--phase-threshold",
        type=float,
        default=1.0,
        help=(
            "Min ms for a phase to appear in per-frame breakdown "
            "(default: 1.0)"
        ),
    )
    parser.add_argument(
        "--script-warn",
        type=float,
        default=3.0,
        help=(
            "Warn about frames where scripts_pre exceeds this many ms "
            "(default: 3.0)"
        ),
    )
    return parser


def main() -> None:
    args = build_parser().parse_args()

    frames_path: str = args.frames_csv
    if not os.path.isfile(frames_path):
        print(f"Error: frames CSV not found: {frames_path}", file=sys.stderr)
        sys.exit(1)

    rows = load_frames(frames_path)
    if not rows:
        print("No frame data!", file=sys.stderr)
        sys.exit(1)

    events_path = _resolve_events_path(frames_path)
    events = load_events(events_path)

    print_summary(
        rows,
        events,
        song_name=args.song,
        top_n=args.top,
        slow_thresholds=_parse_thresholds(args.slow),
        event_threshold=args.event_threshold,
        phase_threshold=args.phase_threshold,
        script_warn_threshold=args.script_warn,
    )


if __name__ == "__main__":
    main()
