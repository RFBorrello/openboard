import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/board_models.dart';
import '../../core/services/board_preferences_store.dart';
import '../../core/services/csv_document_service.dart';

final boardControllerProvider =
    StateNotifierProvider<BoardController, BoardState>((ref) {
  return BoardController(
    ref.watch(csvDocumentServiceProvider),
    ref.watch(boardPreferencesStoreProvider),
  )..loadRecentFiles();
});

class BoardState {
  const BoardState({
    this.document,
    this.recentFiles = const [],
    this.filterQuery = '',
    this.selectedRecordId,
    this.isLoading = false,
    this.isSaving = false,
    this.errorMessage,
  });

  final BoardDocument? document;
  final List<String> recentFiles;
  final String filterQuery;
  final String? selectedRecordId;
  final bool isLoading;
  final bool isSaving;
  final String? errorMessage;

  BoardState copyWith({
    BoardDocument? document,
    bool keepDocument = true,
    List<String>? recentFiles,
    String? filterQuery,
    String? selectedRecordId,
    bool clearSelectedRecord = false,
    bool? isLoading,
    bool? isSaving,
    String? errorMessage,
    bool clearError = false,
  }) {
    return BoardState(
      document: keepDocument ? (document ?? this.document) : document,
      recentFiles: recentFiles ?? this.recentFiles,
      filterQuery: filterQuery ?? this.filterQuery,
      selectedRecordId: clearSelectedRecord
          ? null
          : (selectedRecordId ?? this.selectedRecordId),
      isLoading: isLoading ?? this.isLoading,
      isSaving: isSaving ?? this.isSaving,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class BoardController extends StateNotifier<BoardState> {
  BoardController(this._csvService, this._preferences)
      : super(const BoardState());

  final CsvDocumentService _csvService;
  final BoardPreferencesStore _preferences;

  Future<void> loadRecentFiles() async {
    final files = await _preferences.loadRecentFiles();
    state = state.copyWith(recentFiles: files);
  }

  Future<void> openFile(String filePath) async {
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearSelectedRecord: true,
    );

    try {
      final document = await _csvService.openDocument(filePath);
      final mapping = await _preferences.loadMapping(
        filePath,
        document.headerFingerprint,
      );
      final savedStatusOrder = await _preferences.loadStatusOrder(
        filePath,
        document.headerFingerprint,
      );
      final detectedMapping = CsvColumnMapping.autoDetect(document.headers);
      final resolvedMapping =
          mapping != null && mapping.isValidForHeaders(document.headers)
              ? mapping
              : detectedMapping;
      final hydrated = document.copyWith(
        mapping: resolvedMapping,
        keepExistingMapping: false,
        statusOrder: resolvedMapping == null
            ? const []
            : _csvService.deriveStatusOrder(
                document.records,
                resolvedMapping,
                preferredOrder: savedStatusOrder ?? const [],
              ),
      );
      await _preferences.saveRecentFile(filePath);
      final recentFiles = await _preferences.loadRecentFiles();
      state = state.copyWith(
        document: hydrated,
        recentFiles: recentFiles,
        filterQuery: '',
        isLoading: false,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: error.toString(),
      );
    }
  }

  Future<void> applyMapping(CsvColumnMapping mapping) async {
    final document = state.document;
    if (document == null) {
      return;
    }
    if (!mapping.isValidForHeaders(document.headers)) {
      state = state.copyWith(
        errorMessage: 'The mapping does not match the CSV headers.',
      );
      return;
    }

    final nextStatusOrder = _csvService.deriveStatusOrder(
      document.records,
      mapping,
      preferredOrder: document.statusOrder,
    );

    await _preferences.saveMapping(
      document.filePath,
      document.headerFingerprint,
      mapping,
    );
    await _preferences.saveStatusOrder(
      document.filePath,
      document.headerFingerprint,
      nextStatusOrder,
    );

    state = state.copyWith(
      document: document.copyWith(
        mapping: mapping,
        keepExistingMapping: false,
        statusOrder: nextStatusOrder,
      ),
      clearError: true,
    );
  }

  List<BoardColumn> buildColumns() {
    final document = state.document;
    final mapping = document?.mapping;
    if (document == null || mapping == null) {
      return const [];
    }

    final filter = state.filterQuery.trim().toLowerCase();
    final grouped = <String, List<BoardRecord>>{};
    final orderedStatuses = _csvService.deriveStatusOrder(
      document.records,
      mapping,
      preferredOrder: document.statusOrder,
    );
    if (orderedStatuses.isEmpty) {
      orderedStatuses.add('To Do');
    }

    for (final status in orderedStatuses) {
      grouped[status] = <BoardRecord>[];
    }

    for (final record in document.records) {
      if (filter.isNotEmpty && !_matchesFilter(record, filter)) {
        continue;
      }
      final status = record.read(mapping.statusColumn).trim();
      final bucket = status.isEmpty ? orderedStatuses.first : status;
      grouped.putIfAbsent(bucket, () => <BoardRecord>[]).add(record);
    }

    return grouped.entries
        .map(
          (entry) => BoardColumn(
            name: entry.key,
            records: [...entry.value]
              ..sort(
                (left, right) =>
                    left.sourceRowIndex.compareTo(right.sourceRowIndex),
              ),
          ),
        )
        .toList(growable: false);
  }

  String createCard({String? initialStatus}) {
    final document = state.document;
    final mapping = document?.mapping;
    if (document == null || mapping == null) {
      throw StateError('Load and map a CSV before creating cards.');
    }

    final statuses = _csvService.deriveStatusOrder(
      document.records,
      mapping,
      preferredOrder: document.statusOrder,
    );
    final targetStatus =
        (initialStatus ?? (statuses.isNotEmpty ? statuses.first : 'To Do')).trim();
    final nextIndex = document.records.isEmpty
        ? 0
        : document.records
                .map((record) => record.sourceRowIndex)
                .reduce((left, right) => left > right ? left : right) +
            1;
    final recordId = 'row_new_$nextIndex';
    final values = {
      for (final header in document.headers) header: '',
      mapping.titleColumn: 'New card',
      mapping.statusColumn: targetStatus,
    };
    final nextRecords = [
      ...document.records,
      BoardRecord(id: recordId, sourceRowIndex: nextIndex, values: values),
    ];
    final nextStatuses = _csvService.deriveStatusOrder(
      nextRecords,
      mapping,
      preferredOrder: [...document.statusOrder, targetStatus],
    );

    final nextDocument = document.copyWith(
      records: nextRecords,
      dirty: true,
      clearLastSavedAt: true,
      statusOrder: nextStatuses,
    );
    state = state.copyWith(
      document: nextDocument,
      selectedRecordId: recordId,
    );
    _persistStatusOrder(nextDocument, nextStatuses);
    return recordId;
  }

  void addColumn(String name) {
    final document = state.document;
    final mapping = document?.mapping;
    if (document == null || mapping == null) {
      return;
    }

    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }

    final nextStatuses = _csvService.deriveStatusOrder(
      document.records,
      mapping,
      preferredOrder: [...document.statusOrder, trimmed],
    );
    final nextDocument = document.copyWith(
      dirty: true,
      clearLastSavedAt: true,
      statusOrder: nextStatuses,
    );
    state = state.copyWith(document: nextDocument);
    _persistStatusOrder(nextDocument, nextStatuses);
  }

  void renameColumn(String previousName, String nextName) {
    final document = state.document;
    final mapping = document?.mapping;
    if (document == null || mapping == null) {
      return;
    }

    final trimmed = nextName.trim();
    if (trimmed.isEmpty || trimmed == previousName) {
      return;
    }

    final nextRecords = [
      for (final record in document.records)
        if (record.read(mapping.statusColumn).trim() == previousName)
          record.copyWith(
            values: {
              ...record.values,
              mapping.statusColumn: trimmed,
            },
          )
        else
          record,
    ];

    final nextStatuses = _csvService.deriveStatusOrder(
      nextRecords,
      mapping,
      preferredOrder: [
        for (final status in document.statusOrder)
          if (status == previousName) trimmed else status,
      ],
    );

    final nextDocument = document.copyWith(
      records: nextRecords,
      dirty: true,
      clearLastSavedAt: true,
      statusOrder: nextStatuses,
    );
    state = state.copyWith(document: nextDocument);
    _persistStatusOrder(nextDocument, nextStatuses);
  }

  void applyRecordValues(String recordId, Map<String, String> values) {
    final document = state.document;
    final mapping = document?.mapping;
    if (document == null || mapping == null) {
      return;
    }

    final nextRecords = [
      for (final record in document.records)
        if (record.id == recordId)
          record.copyWith(
            values: {
              for (final header in document.headers)
                header: values[header] ?? '',
            },
          )
        else
          record,
    ];
    final nextStatuses = _csvService.deriveStatusOrder(
      nextRecords,
      mapping,
      preferredOrder: document.statusOrder,
    );

    final nextDocument = document.copyWith(
      records: nextRecords,
      dirty: true,
      clearLastSavedAt: true,
      statusOrder: nextStatuses,
    );
    state = state.copyWith(document: nextDocument);
    _persistStatusOrder(nextDocument, nextStatuses);
  }

  void moveRecord(String recordId, String status) {
    final document = state.document;
    final mapping = document?.mapping;
    if (document == null || mapping == null) {
      return;
    }

    final trimmed = status.trim();
    final nextRecords = [
      for (final record in document.records)
        if (record.id == recordId)
          record.copyWith(
            values: {
              ...record.values,
              mapping.statusColumn: trimmed,
            },
          )
        else
          record,
    ];
    final nextStatuses = _csvService.deriveStatusOrder(
      nextRecords,
      mapping,
      preferredOrder: [...document.statusOrder, trimmed],
    );

    final nextDocument = document.copyWith(
      records: nextRecords,
      dirty: true,
      clearLastSavedAt: true,
      statusOrder: nextStatuses,
    );
    state = state.copyWith(document: nextDocument);
    _persistStatusOrder(nextDocument, nextStatuses);
  }

  void moveColumn(String columnName, int delta) {
    final document = state.document;
    final mapping = document?.mapping;
    if (document == null || mapping == null || delta == 0) {
      return;
    }

    final nextStatuses = _csvService
        .deriveStatusOrder(
          document.records,
          mapping,
          preferredOrder: document.statusOrder,
        )
        .toList(growable: true);
    final currentIndex = nextStatuses.indexOf(columnName);
    if (currentIndex < 0) {
      return;
    }

    final targetIndex = (currentIndex + delta).clamp(0, nextStatuses.length - 1);
    if (targetIndex == currentIndex) {
      return;
    }

    final moved = nextStatuses.removeAt(currentIndex);
    nextStatuses.insert(targetIndex, moved);

    final nextDocument = document.copyWith(statusOrder: nextStatuses);
    state = state.copyWith(document: nextDocument);
    _persistStatusOrder(nextDocument, nextStatuses);
  }

  void selectRecord(String? recordId) {
    state = state.copyWith(
      selectedRecordId: recordId,
      clearSelectedRecord: recordId == null,
    );
  }

  void setFilter(String query) {
    state = state.copyWith(filterQuery: query);
  }

  Future<void> saveDocument() async {
    final document = state.document;
    final mapping = document?.mapping;
    if (document == null || mapping == null) {
      return;
    }

    state = state.copyWith(isSaving: true, clearError: true);
    try {
      await _csvService.saveDocument(document);
      await _preferences.saveRecentFile(document.filePath);
      final recentFiles = await _preferences.loadRecentFiles();
      state = state.copyWith(
        document: document.copyWith(
          dirty: false,
          lastSavedAt: DateTime.now(),
        ),
        recentFiles: recentFiles,
        isSaving: false,
      );
    } catch (error) {
      state = state.copyWith(
        isSaving: false,
        errorMessage: error.toString(),
      );
    }
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  bool _matchesFilter(BoardRecord record, String filter) {
    return record.values.values.any(
      (value) => value.toLowerCase().contains(filter),
    );
  }

  void _persistStatusOrder(BoardDocument document, List<String> statusOrder) {
    unawaited(
      _preferences.saveStatusOrder(
        document.filePath,
        document.headerFingerprint,
        statusOrder,
      ),
    );
  }
}

