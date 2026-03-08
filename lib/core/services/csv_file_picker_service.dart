import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

final csvFilePickerServiceProvider = Provider<CsvFilePickerService>((ref) {
  return const CsvFilePickerService();
});

class CsvFilePickResult {
  const CsvFilePickResult({required this.launchedPicker, this.path});

  final bool launchedPicker;
  final String? path;
}

class CsvFilePickerService {
  const CsvFilePickerService();

  Future<CsvFilePickResult> pickCsvPath() async {
    if (Platform.isWindows) {
      return _pickWindows();
    }
    if (Platform.isMacOS) {
      return _pickMacOs();
    }
    if (Platform.isLinux) {
      return _pickLinux();
    }
    return const CsvFilePickResult(launchedPicker: false);
  }

  Future<CsvFilePickResult> _pickWindows() async {
    const script = r'''
Add-Type -AssemblyName System.Windows.Forms
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = 'Open CSV'
$dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
$dialog.Multiselect = $false
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  Write-Output $dialog.FileName
}
''';

    final result = await Process.run('powershell', [
      '-NoProfile',
      '-STA',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);

    if (result.exitCode != 0) {
      return const CsvFilePickResult(launchedPicker: false);
    }

    final path = (result.stdout as String).trim();
    return CsvFilePickResult(
      launchedPicker: true,
      path: path.isEmpty ? null : path,
    );
  }

  Future<CsvFilePickResult> _pickMacOs() async {
    const script = r'''
set chosenFile to choose file with prompt "Open CSV" of type {"public.comma-separated-values-text", "public.text"}
POSIX path of chosenFile
''';

    final result = await Process.run('osascript', ['-e', script]);
    if (result.exitCode != 0) {
      return const CsvFilePickResult(launchedPicker: true);
    }

    final path = (result.stdout as String).trim();
    return CsvFilePickResult(
      launchedPicker: true,
      path: path.isEmpty ? null : path,
    );
  }

  Future<CsvFilePickResult> _pickLinux() async {
    final zenity = await Process.run('which', ['zenity']);
    if (zenity.exitCode == 0) {
      final result = await Process.run('zenity', [
        '--file-selection',
        '--title=Open CSV',
        '--file-filter=CSV files | *.csv',
        '--file-filter=All files | *',
      ]);
      if (result.exitCode == 1) {
        return const CsvFilePickResult(launchedPicker: true);
      }
      if (result.exitCode == 0) {
        final path = (result.stdout as String).trim();
        return CsvFilePickResult(
          launchedPicker: true,
          path: path.isEmpty ? null : path,
        );
      }
    }

    final kdialog = await Process.run('which', ['kdialog']);
    if (kdialog.exitCode == 0) {
      final result = await Process.run('kdialog', [
        '--getopenfilename',
        '.',
        '*.csv|CSV files',
      ]);
      if (result.exitCode == 1) {
        return const CsvFilePickResult(launchedPicker: true);
      }
      if (result.exitCode == 0) {
        final path = (result.stdout as String).trim();
        return CsvFilePickResult(
          launchedPicker: true,
          path: path.isEmpty ? null : path,
        );
      }
    }

    return const CsvFilePickResult(launchedPicker: false);
  }
}
