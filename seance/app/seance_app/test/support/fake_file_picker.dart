// A file_picker platform with scripted picks, and picked files with scripted
// lengths and byte streams, for the app's own picker callers.
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// A picked file whose reported length and contents the test sets.
///
/// [readAsBytes] throws, so a test passes only if the caller streams.
final class FakePickedFile extends PlatformFile {
  /// A document-provider pick without a filesystem path.
  FakePickedFile.stream(
    this.name,
    Stream<List<int>> Function() open, {
    this.reportedLength,
  }) : _open = open,
       _uri = Uri(scheme: 'content', path: '/picked/$name');

  /// [contents] without a filesystem path.
  FakePickedFile.bytes(this.name, List<int> contents, {this.reportedLength})
    : _open = (() => Stream.value(contents)),
      _uri = Uri(scheme: 'content', path: '/picked/$name');

  /// A pick of the file at [path], read from disk.
  FakePickedFile.path(this.name, String path, {this.reportedLength})
    : _open = File(path).openRead,
      _uri = Uri.file(path);

  @override
  final String name;

  /// What the picker reported without reading, as [lengthSync] answers.
  final int? reportedLength;

  final Stream<List<int>> Function() _open;
  final Uri _uri;

  /// How many times the contents were opened.
  int reads = 0;

  @override
  Uri get uri => _uri;

  @override
  Never get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => reportedLength;

  @override
  Future<int?> length() async => reportedLength;

  @override
  Future<Uint8List> readAsBytes() =>
      throw StateError('the caller loaded the whole file instead of streaming');

  @override
  Stream<Uint8List> readAsByteStream() {
    reads++;
    return _open().map(Uint8List.fromList);
  }
}

/// The platform pickers with a scripted answer: [picked] for a multiple
/// selection, its first file for a single one.
final class FakeFilePicker extends FilePickerPlatform {
  List<PlatformFile> picked = const [];

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => picked;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => picked.isEmpty ? null : picked.first;
}
