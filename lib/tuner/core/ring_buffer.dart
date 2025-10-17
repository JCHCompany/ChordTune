/// A lock-free ring buffer for float samples.
/// Not thread-safe for concurrent multi-writers/readers; the audio thread writes,
/// the DSP thread reads using snapshot indices.
class FloatRingBuffer {
  FloatRingBuffer(int capacity)
      : assert(capacity > 0),
        _buffer = List<double>.filled(capacity, 0.0),
        _mask = _nextPow2(capacity) - 1;

  static int _nextPow2(int x) {
    var v = x - 1;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    return v + 1;
  }

  final List<double> _buffer;
  final int _mask;
  int _writeIndex = 0; // monotonically increasing

  int get capacity => _buffer.length;

  void writeSamples(List<double> samples) {
    for (final s in samples) {
      _buffer[_writeIndex & _mask] = s;
      _writeIndex++;
    }
  }

  /// Copies the last [count] samples into [out] (length must be >= count).
  void readLast(int count, List<double> out) {
    assert(count <= out.length);
    final start = _writeIndex - count;
    for (var i = 0; i < count; i++) {
      out[i] = _buffer[(start + i) & _mask];
    }
  }
}
