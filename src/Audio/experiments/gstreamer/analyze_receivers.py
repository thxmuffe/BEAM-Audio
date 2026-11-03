#!/usr/bin/env python3
"""Summarize compare_receivers.py artifacts; requires NumPy, not GI bindings."""
import argparse
import json
from pathlib import Path

import numpy as np


def tone_metrics(samples, rate=48000, frequency=997):
    """Fixed-frequency sine fit: includes codec errors AND timing/phase changes.

    This is a synthetic-signal diagnostic, not a perceptual audio-quality score.
    """
    t = np.arange(len(samples)) / rate
    basis = np.column_stack((np.sin(2 * np.pi * frequency * t),
                             np.cos(2 * np.pi * frequency * t), np.ones(len(t))))
    coefficients = np.linalg.lstsq(basis, samples, rcond=None)[0]
    fitted = basis @ coefficients
    residual = samples - fitted
    signal_power = np.mean((fitted - coefficients[2]) ** 2)
    error_power = np.mean(residual ** 2)
    return {
        'rms': float(np.sqrt(np.mean(samples ** 2))),
        'peak': float(np.max(np.abs(samples))),
        'clipped_samples': int(np.count_nonzero(np.abs(samples) >= 32767 / 32768)),
        'sine_residual_db': float(10 * np.log10(signal_power / max(error_power, 1e-30))),
    }


def summarize(path):
    d = json.loads(path.read_text())
    a, b = (d['snapshots'][key] for key in ('start', 'end'))
    pcm = np.fromfile(path.parent / 'output.s16le', dtype='<i2').reshape(-1, 2) / 32768
    blocks = d['output_blocks']
    window = [r for r in blocks if a['host_ns'] <= r[0] < b['host_ns']]
    if not d['checks_passed'] or not window or not np.any(np.abs(pcm) > .001):
        raise ValueError(f'{path}: failed or silent fixture')
    if d['receiver'] == 'neteq' and d['native_final']['output_status_errors']:
        raise ValueError(f'{path}: native output errors')
    start, end = window[0][1], window[-1][1] + window[-1][2]
    metrics = tone_metrics(pcm[start:end, 0])
    first = int(np.flatnonzero(np.any(np.abs(pcm) > .001, axis=1))[0])
    block = next(r for r in blocks if r[1] <= first < r[1] + r[2])
    onset = block[0] + (first - block[1]) / 48000 * 1e9
    metrics.update({
        'case': path.parent.name, 'receiver': d['receiver'],
        'drop_every': d['drop_every'], 'minimum_delay_ms': d['minimum_delay_ms'],
        'encoded_source_sha256': d['encoded_source_sha256'],
        'injected_drops': d['injected_drops'],
        'software_onset_ms': (onset - d['first_payload_host_ns']) / 1e6,
        'fixture_cpu_percent_one_core': 100 * d['window_cpu_seconds'] / d['window_duration_seconds'],
        'fixture_rss_sum_mib': d['rss_sum_peak_bytes'] / 2 ** 20,
        'output_window_frames': end - start,
    })
    if d['receiver'] == 'neteq':
        an, bn = a['native'], b['native']
        delta = {key: bn[key] - an[key] for key in (
            'packetsLost', 'concealedSamples', 'insertedSamplesForDeceleration',
            'removedSamplesForAcceleration', 'jitterBufferDelay', 'jitterBufferEmittedCount')}
        metrics['native_counter_deltas'] = delta
        metrics['mean_jitter_residence_ms'] = (1000 * delta['jitterBufferDelay']
                                              / delta['jitterBufferEmittedCount'])
        metrics['timer_overruns'] = d['native_final']['timer_overruns']
    else:
        metrics['decoder_counter_deltas'] = {
            key: b['decoder'][key] - a['decoder'][key]
            for key in ('num-gap', 'plc-num-samples', 'plc-duration')}
        metrics['jitter_config'] = b['jitter_config']
    return metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    rows = [summarize(p) for p in sorted(args.directory.glob('*/result.json'))]
    if not rows or len({r['encoded_source_sha256'] for r in rows}) != 1:
        raise ValueError('Missing trials or source Opus payloads differ; comparison invalid')
    output = {'source_payloads_identical': True, 'trials': rows,
              'limits': ['Sine residual includes timing changes; not a perceptual quality score.',
                         'Onset is first RTP probe to software callback; not capture-to-speaker latency.',
                         'CPU/RSS cover entire fixtures with different process/binding overhead.',
                         'Loss is before WebRTC send/cache; does not test retransmission or real networks.']}
    (args.directory / 'summary.json').write_text(json.dumps(output, indent=2) + '\n')
    for r in rows:
        print(f"{r['case']:25} tone={r['sine_residual_db']:5.1f} dB "
              f"onset={r['software_onset_ms']:6.1f} ms "
              f"CPU={r['fixture_cpu_percent_one_core']:4.1f}% "
              f"RSS={r['fixture_rss_sum_mib']:4.1f} MiB")


if __name__ == '__main__':
    main()
