#!/usr/bin/env python3
"""Receive BlueMuse MUSE_4CH samples; optionally record timestamp + four channels to CSV."""
import argparse
import csv
from contextlib import ExitStack
import time
from pylsl import resolve_byprop, StreamInlet

CHANNELS = ["TP9", "AF7", "AF8", "TP10"]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-id", help="Select a specific headset's source ID from the app's info panel")
    parser.add_argument("--csv", help="Write samples to a new CSV (refuses to overwrite existing files)")
    parser.add_argument("--seconds", type=float, default=0, help="Stop after this duration; default: until Ctrl-C")
    args = parser.parse_args()
    prop, value = ("source_id", args.source_id) if args.source_id else ("name", "MUSE_4CH")
    streams = resolve_byprop(prop, value, timeout=10)
    if len(streams) != 1:
        raise RuntimeError("Start MUSE_4CH in BlueMuse first. If several streams match, use --source-id.")
    inlet = StreamInlet(streams[0], max_buflen=30, recover=True, processing_flags=0)
    try:
        info = inlet.info(timeout=5)
        if info.channel_count() != 4 or info.type() != "EEG":
            raise RuntimeError("Expected a four-channel EEG stream")
        labels = []
        node = info.desc().child("channels").child("channel")
        while node.name() == "channel":
            labels.append(node.child_value("label")); node = node.next_sibling()
        if labels != CHANNELS:
            raise RuntimeError(f"Unexpected channel order: {labels}")
        print(f"Connected: {info.name()} | {info.nominal_srate():g} Hz | {CHANNELS}")
        print(f"Clock: {info.desc().child_value('primary_timestamp_format')}; timing: {info.desc().child_value('timestamp_behavior')}")
        with ExitStack() as stack:
            writer = None
            if args.csv:
                file = stack.enter_context(open(args.csv, "x", newline="", encoding="utf-8"))
                writer = csv.writer(file); writer.writerow(["timestamp"] + CHANNELS)
            start = last_report = time.monotonic(); received = total = 0
            while args.seconds <= 0 or time.monotonic() - start < args.seconds:
                samples, timestamps = inlet.pull_chunk(timeout=0.2, max_samples=512)
                for sample, timestamp in zip(samples, timestamps):
                    if len(sample) != 4: raise RuntimeError("Unexpected sample shape")
                    if writer: writer.writerow([timestamp] + sample)
                    # Classifier integration: buffer consecutive samples here, then
                    # apply the same preprocessing and windowing used during training.
                received += len(samples); total += len(samples)
                now = time.monotonic()
                if now - last_report >= 1:
                    print(f"Received {received / (now - last_report):.1f} samples/s; total {total}")
                    received = 0; last_report = now
            print(f"Finished: {total} samples received")
    finally:
        inlet.close_stream()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nReceiver stopped.")
