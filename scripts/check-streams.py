#!/usr/bin/env python3
"""Receive existing BlueMuse streams and print aggregate diagnostics; never save raw samples."""
import argparse
import ctypes as C
import json
import math
from pathlib import Path
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--device', required=True, help='macOS peripheral UUID shown by BlueMuse')
p.add_argument('--seconds', type=float, default=12)
p.add_argument('--library', default=str(Path(__file__).resolve().parents[1] / 'Vendor/lsl.framework/lsl'))
p.add_argument('--telemetry', action='store_true', help='also require the optional telemetry stream')
a = p.parse_args()
lsl = C.CDLL(a.library)
def api(name, result, *args):
    f = getattr(lsl, name); f.restype = result; f.argtypes = list(args); return f
ptr = C.c_void_p
resolve = api('lsl_resolve_byprop', C.c_int32, C.POINTER(ptr), C.c_uint32, C.c_char_p, C.c_char_p, C.c_int32, C.c_double)
create = api('lsl_create_inlet', ptr, ptr, C.c_int32, C.c_int32, C.c_int32)
open_stream = api('lsl_open_stream', None, ptr, C.c_double, C.POINTER(C.c_int32))
pull = api('lsl_pull_sample_d', C.c_double, ptr, C.POINTER(C.c_double), C.c_int32, C.c_double, C.POINTER(C.c_int32))
channels = api('lsl_get_channel_count', C.c_int32, ptr)
nominal = api('lsl_get_nominal_srate', C.c_double, ptr)
format_of = api('lsl_get_channel_format', C.c_int32, ptr)
destroy_info = api('lsl_destroy_streaminfo', None, ptr)
destroy_inlet = api('lsl_destroy_inlet', None, ptr)
streams = []
missing = []
try:
    for sensor in ['EEG', 'Accelerometer', 'Gyroscope', 'PPG'] + (['Telemetry'] if a.telemetry else []):
        infos = (ptr * 8)()
        n = resolve(infos, 8, b'source_id', f'BlueMuse:{a.device}:{sensor}'.encode(), 1, 5)
        if n <= 0:
            missing.append(sensor)
            continue
        try:
            count = channels(infos[0]); rate = nominal(infos[0]); fmt = format_of(infos[0])
            inlet = create(infos[0], 30, 0, 0)
            if not inlet:
                raise RuntimeError(f'Cannot create {sensor} inlet')
            ec = C.c_int32()
            open_stream(inlet, 5, C.byref(ec))
            if ec.value:
                destroy_inlet(inlet)
                raise RuntimeError(f'Cannot open {sensor}: {ec.value}')
            streams.append(dict(sensor=sensor, inlet=inlet, channels=count, nominal=rate, format=fmt,
                                buffer=(C.c_double * count)(), count=0, finite=[0]*count, varying=[False]*count,
                                previous=None, first_ts=None, last_ts=None, backwards=0))
        finally:
            for i in range(n): destroy_info(infos[i])
    # Drain setup-time data so sample counts represent a shared wall-clock interval.
    for s in streams:
        ec = C.c_int32()
        while pull(s['inlet'], s['buffer'], s['channels'], 0, C.byref(ec)):
            pass
    start = time.monotonic()
    while time.monotonic() - start < a.seconds:
        received = False
        for s in streams:
            for _ in range(300):
                ec = C.c_int32()
                ts = pull(s['inlet'], s['buffer'], s['channels'], 0, C.byref(ec))
                if ec.value: raise RuntimeError(f"{s['sensor']} pull error {ec.value}")
                if not ts: break
                received = True; s['count'] += 1
                if s['first_ts'] is None: s['first_ts'] = ts
                if s['last_ts'] is not None and ts < s['last_ts']: s['backwards'] += 1
                s['last_ts'] = ts
                row = list(s['buffer'])
                for i, value in enumerate(row):
                    if math.isfinite(value): s['finite'][i] += 1
                    if s['previous'] is not None and value != s['previous'][i] and math.isfinite(value): s['varying'][i] = True
                s['previous'] = row
        if not received: time.sleep(0.005)
    duration = time.monotonic() - start
    report = {'device': a.device, 'duration_seconds': round(duration, 3), 'missing': missing, 'streams': []}
    for s in streams:
        report['streams'].append(dict(sensor=s['sensor'], channels=s['channels'], nominal_hz=s['nominal'],
             format='double64' if s['format'] == 2 else 'float32', samples=s['count'], received_hz=round(s['count']/duration, 3),
             finite_per_channel=s['finite'], varying_per_channel=s['varying'], backwards_timestamps=s['backwards']))
    print(json.dumps(report, indent=2))
    raise SystemExit(1 if missing or any(s['count'] == 0 for s in streams) else 0)
finally:
    for s in streams: destroy_inlet(s['inlet'])
