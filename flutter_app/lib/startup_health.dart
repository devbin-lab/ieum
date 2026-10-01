import 'dart:io';

/// Restricts the native launcher's acknowledgement to its managed build folder.
File? startupHealthFile(String buildsPath, String markerPath) {
  final directory = Directory(buildsPath).absolute.uri
      .normalizePath()
      .toFilePath();
  final prefix = directory.endsWith(Platform.pathSeparator)
      ? directory
      : '$directory${Platform.pathSeparator}';
  final marker = File(
    File(markerPath).absolute.uri.normalizePath().toFilePath(),
  );
  return marker.path.toLowerCase().startsWith(prefix.toLowerCase()) &&
          marker.uri.pathSegments.last.startsWith('.startup-')
      ? marker
      : null;
}
