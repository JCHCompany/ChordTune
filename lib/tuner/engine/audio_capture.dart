import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'logger.dart';

typedef SamplesCallback = void Function(List<double> samples, int sampleRate);

/// Captures raw PCM from microphone. Attempts to use unprocessed audio sources
/// where supported (Android: UNPROCESSED). Falls back gracefully otherwise.
class AudioCaptureService {
  AudioCaptureService({this.preferredSampleRate = 48000});

  final int preferredSampleRate;
  final AudioRecorder _record = AudioRecorder();
  StreamSubscription<Amplitude>? _ampSub; // not used, placeholder for level
  StreamSubscription<Uint8List>? _streamSub;

  Future<bool> hasPermission() => _record.hasPermission();

  Future<void> start(SamplesCallback onSamples) async {
    final can = await _record.hasPermission();
    if (!can) {
      throw StateError('No mic permission');
    }
    final cfg = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      numChannels: 1,
      sampleRate: preferredSampleRate,
      autoGain: false,
      echoCancel: false,
      noiseSuppress: false,
      androidConfig: const AndroidRecordConfig(
        audioSource: AndroidAudioSource.unprocessed,
        manageBluetooth: false,
        speakerphone: false,
      ),
    );

    final stream = await _record.startStream(cfg);
    _streamSub = stream.listen((data) {
      // Convert bytes (little endian PCM16) to float -1..1
      final bd = ByteData.sublistView(data);
      final n = bd.lengthInBytes ~/ 2;
      final out = List<double>.filled(n, 0.0);
      for (var i = 0; i < n; i++) {
        final s = bd.getInt16(i * 2, Endian.little);
        out[i] = (s.toDouble() / 32768.0).clamp(-1.0, 1.0);
      }
      onSamples(out, preferredSampleRate);
    });
    TunerLogger.d('AudioCapture started @ $preferredSampleRate Hz');
  }

  Future<void> stop() async {
    await _streamSub?.cancel();
    await _ampSub?.cancel();
    await _record.stop();
    await _record.dispose();
    TunerLogger.d('AudioCapture stopped');
  }
}
