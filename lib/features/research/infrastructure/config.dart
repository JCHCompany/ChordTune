import 'package:flutter/services.dart' show rootBundle;

class ResearchConfig {
  final int fs;
  final int frameMs;
  final double overlap;
  final double alphaEma;
  final double tauConfLow;
  final double tauConfHigh;
  final int kLock;
  final bool antiOctave;
  final String detector;
  final bool whitening;
  final String fallback;
  final double tauSnr;

  const ResearchConfig({
    this.fs = 48000,
    this.frameMs = 50,
    this.overlap = 0.88,
    this.alphaEma = 0.25,
    this.tauConfLow = 0.6,
    this.tauConfHigh = 0.7,
    this.kLock = 4,
    this.antiOctave = true,
    this.detector = 'mpm',
    this.whitening = false,
    this.fallback = 'auto',
    this.tauSnr = 6.0,
  });

  static Future<ResearchConfig> loadFromAsset(String path) async {
    try {
      final text = await rootBundle.loadString(path);
      return parse(text);
    } catch (_) {
      return const ResearchConfig();
    }
  }

  static ResearchConfig parse(String text) {
    int parseInt(String v, int d) => int.tryParse(v.trim()) ?? d;
    double parseDouble(String v, double d) => double.tryParse(v.trim()) ?? d;
    bool parseBool(String v, bool d) => (v.trim().toLowerCase() == 'true') ? true : (v.trim().toLowerCase() == 'false' ? false : d);
    String parseStr(String v, String d) => v.trim().isNotEmpty ? v.trim() : d;

    final map = <String, String>{};
    for (final line in text.split('\n')) {
      final l = line.trim();
      if (l.isEmpty || l.startsWith('#')) continue;
      final idx = l.indexOf(':');
      if (idx <= 0) continue;
      final k = l.substring(0, idx).trim();
      final val = l.substring(idx + 1).trim();
      map[k] = val;
    }

    return ResearchConfig(
      fs: parseInt(map['fs'] ?? '', 48000),
      frameMs: parseInt(map['frame_ms'] ?? '', 50),
      overlap: parseDouble(map['overlap'] ?? '', 0.88),
      alphaEma: parseDouble(map['alpha_ema'] ?? map['α_ema'] ?? '', 0.25),
      tauConfLow: parseDouble(map['tau_conf_low'] ?? map['τ_conf_low'] ?? '', 0.6),
      tauConfHigh: parseDouble(map['tau_conf_high'] ?? map['τ_conf_high'] ?? '', 0.7),
      kLock: parseInt(map['K_lock'] ?? '', 4),
      antiOctave: parseBool(map['anti_octave'] ?? '', true),
      detector: parseStr(map['detector'] ?? '', 'mpm'),
      whitening: parseBool(map['whitening'] ?? '', false),
      fallback: parseStr(map['fallback'] ?? '', 'auto'),
      tauSnr: parseDouble(map['tau_snr'] ?? '', 6.0),
    );
  }
}