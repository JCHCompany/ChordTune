import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'spectroid_config.dart';

/// Digital signal processing filters and audio effects management
class AudioDSP {
  // IIR 1st order high-pass filter state (DC removal)
  double _iirX1 = 0.0;
  double _iirY1 = 0.0;
  
  // DC blocker filter state
  double _dcBlockerX1 = 0.0;
  double _dcBlockerY1 = 0.0;
  
  // Notch filter states (biquad IIR)
  double _notchX1 = 0.0, _notchX2 = 0.0;
  double _notchY1 = 0.0, _notchY2 = 0.0;
  double _notchB0 = 1.0, _notchB1 = 0.0, _notchB2 = 0.0;
  double _notchA1 = 0.0, _notchA2 = 0.0;
  
  final DcFilterType _dcFilterType;
  final NotchFilter _notchFilter;

  /// Constructor with configuration
  AudioDSP({
    required double sampleRate,
    required DcFilterType dcFilterType,
    required NotchFilter notchFilter,
  }) : _dcFilterType = dcFilterType,
       _notchFilter = notchFilter {
    _initialize(sampleRate.toInt());
  }

  /// Initialize filters for given sample rate and configuration
  void _initialize(int sampleRate) {
    // Reset IIR and DC blocker states
    _iirX1 = _iirY1 = 0.0;
    _dcBlockerX1 = _dcBlockerY1 = 0.0;
    
    // Setup notch filter if enabled
    if (_notchFilter != NotchFilter.none) {
      final notchFreq = _notchFilter == NotchFilter.hz50 ? 50.0 : 60.0;
      _setupNotchFilter(notchFreq, sampleRate);
    }
    
    debugPrint('AudioDSP initialized: SR=$sampleRate, DC=${_dcFilterType.name}, Notch=${_notchFilter.name}');
  }

  /// Process a single audio sample through configured filters
  double process(double sample) {
    double output = sample;
    
    // Apply DC filter
    output = applyDcFilter(output, _dcFilterType);
    
    // Apply notch filter
    output = applyNotchFilter(output, _notchFilter);
    
    return output;
  }

  /// Apply configured DC removal filter
  double applyDcFilter(double sample, DcFilterType filterType) {
    switch (filterType) {
      case DcFilterType.none:
        return sample;
      
      case DcFilterType.iir:
        // IIR 1st order high-pass: Fc ≈ 3Hz at fs=48kHz
        // y[n] = 0.9998*y[n-1] + x[n] - x[n-1]
        const alpha = 0.9998; // -3dB at ~3Hz for fs=48kHz
        final output = alpha * _iirY1 + sample - _iirX1;
        _iirX1 = sample;
        _iirY1 = output;
        return output;
      
      case DcFilterType.dcBlocker:
        // DC blocker: y[n] = x[n] - x[n-1] + 0.995*y[n-1]
        const pole = 0.995;
        final output = sample - _dcBlockerX1 + pole * _dcBlockerY1;
        _dcBlockerX1 = sample;
        _dcBlockerY1 = output;
        return output;
    }
  }

  /// Apply notch filter if enabled
  double applyNotchFilter(double sample, NotchFilter filterType) {
    if (filterType == NotchFilter.none) return sample;
    
    // Biquad IIR notch filter
    final output = _notchB0 * sample + _notchB1 * _notchX1 + _notchB2 * _notchX2 
                 - _notchA1 * _notchY1 - _notchA2 * _notchY2;
    
    // Update delay line
    _notchX2 = _notchX1;
    _notchX1 = sample;
    _notchY2 = _notchY1;
    _notchY1 = output;
    
    return output;
  }

  /// Setup biquad notch filter coefficients
  void _setupNotchFilter(double freqHz, int sampleRate) {
    final w0 = 2.0 * math.pi * freqHz / sampleRate;
    final cosW0 = math.cos(w0);
    final sinW0 = math.sin(w0);
    
    // Q factor for narrow notch
    const q = 30.0;
    final alpha = sinW0 / (2.0 * q);
    
    // Biquad coefficients (normalized by a0)
    final a0 = 1.0 + alpha;
    _notchB0 = 1.0 / a0;
    _notchB1 = -2.0 * cosW0 / a0;
    _notchB2 = 1.0 / a0;
    _notchA1 = (-2.0 * cosW0) / a0;
    _notchA2 = (1.0 - alpha) / a0;
    
    // Reset filter state
    _notchX1 = _notchX2 = 0.0;
    _notchY1 = _notchY2 = 0.0;
    
    debugPrint('Notch filter setup: f=${freqHz}Hz, Q=$q, coeffs=[${_notchB0.toStringAsFixed(6)}, ${_notchB1.toStringAsFixed(6)}, ${_notchB2.toStringAsFixed(6)}]');
  }
}

/// Audio effects status from device
class AudioEffectStatus {
  final bool agcAvailable;
  final bool agcEnabled;
  final bool nsAvailable; 
  final bool nsEnabled;
  final bool aecAvailable;
  final bool aecEnabled;
  final String deviceInfo;
  final bool unprocessedAvailable;

  const AudioEffectStatus({
    this.agcAvailable = false,
    this.agcEnabled = true,
    this.nsAvailable = false,
    this.nsEnabled = true,
    this.aecAvailable = false,
    this.aecEnabled = true,
    this.deviceInfo = 'Unknown',
    this.unprocessedAvailable = false,
  });

  // Convenience getters for disabled status (opposite of enabled)
  bool get agcDisabled => !agcEnabled;
  bool get nsDisabled => !nsEnabled;
  bool get aecDisabled => !aecEnabled;

  // Mutable copy with updated values
  AudioEffectStatus copyWith({
    bool? agcAvailable,
    bool? agcEnabled,
    bool? nsAvailable,
    bool? nsEnabled,
    bool? aecAvailable,
    bool? aecEnabled,
    String? deviceInfo,
    bool? unprocessedAvailable,
  }) => AudioEffectStatus(
    agcAvailable: agcAvailable ?? this.agcAvailable,
    agcEnabled: agcEnabled ?? this.agcEnabled,
    nsAvailable: nsAvailable ?? this.nsAvailable,
    nsEnabled: nsEnabled ?? this.nsEnabled,
    aecAvailable: aecAvailable ?? this.aecAvailable,
    aecEnabled: aecEnabled ?? this.aecEnabled,
    deviceInfo: deviceInfo ?? this.deviceInfo,
    unprocessedAvailable: unprocessedAvailable ?? this.unprocessedAvailable,
  );

  String get statusSummary {
    final parts = <String>[];
    if (agcAvailable) parts.add('AGC:${agcEnabled ? "ON" : "OFF"}');
    if (nsAvailable) parts.add('NS:${nsEnabled ? "ON" : "OFF"}');  
    if (aecAvailable) parts.add('AEC:${aecEnabled ? "ON" : "OFF"}');
    return parts.isEmpty ? 'Introuvable' : parts.join(' ');
  }
}