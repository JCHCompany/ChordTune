part of 'research_bloc.dart';

enum ResearchStatus { initial, warmup, ready, permissionDenied, stopped }

sealed class ResearchEvent extends Equatable {
  const ResearchEvent();
  @override
  List<Object?> get props => [];
}

class ResearchStart extends ResearchEvent { const ResearchStart(); }
class ResearchStop extends ResearchEvent { const ResearchStop(); }
class ResearchSelectDetector extends ResearchEvent {
  final String detector; // 'auto' | 'MPM' | 'YIN' | 'SRH'
  const ResearchSelectDetector(this.detector);
  @override
  List<Object?> get props => [detector];
}

class ResearchExportLogs extends ResearchEvent { const ResearchExportLogs(); }

class ResearchAudioChunk extends ResearchEvent {
  final Uint8List data;
  const ResearchAudioChunk(this.data);
  @override
  List<Object?> get props => [data];
}