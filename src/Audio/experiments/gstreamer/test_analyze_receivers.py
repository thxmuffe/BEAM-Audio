import unittest

import numpy as np

from analyze_receivers import tone_metrics


class ToneMetricsTests(unittest.TestCase):
    def test_phase_and_dc_are_fitted_without_becoming_noise(self):
        t = np.arange(48000) / 48000
        samples = .05 * np.sin(2 * np.pi * 997 * t + .7) + .002
        metrics = tone_metrics(samples)
        self.assertGreater(metrics['sine_residual_db'], 200)
        self.assertEqual(metrics['clipped_samples'], 0)

    def test_added_noise_has_known_residual(self):
        t = np.arange(48000) / 48000
        samples = .05 * np.sin(2 * np.pi * 997 * t) + .0005 * np.sin(2 * np.pi * 1703 * t)
        self.assertAlmostEqual(tone_metrics(samples)['sine_residual_db'], 40, places=4)

    def test_saturation_is_counted(self):
        samples = np.clip(2 * np.sin(2 * np.pi * 997 * np.arange(48000) / 48000), -1, 32767 / 32768)
        self.assertGreater(tone_metrics(samples)['clipped_samples'], 30000)


if __name__ == '__main__':
    unittest.main()
