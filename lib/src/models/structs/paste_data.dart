import '../../../flutter_quill.dart';

class PasteData {
  const PasteData({this.text, this.delta});

  final String? text;
  final Delta? delta;
}