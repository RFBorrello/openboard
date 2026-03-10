import 'dart:async';
import 'dart:io';

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

enum BoardSyncStatus { idle, saving, reloading, externalUpdate, error }

enum BoardCardSort {
  manual,
  titleAscending,
  titleDescending,
  dueDateAscending,
  dueDateDescending,
}

class BoardState {
  const BoardState({
    this.document,
    this.recentFiles = const [],
    this.filterQuery = '',
    this.selectedRecordId,
    this.isLoading = false,
    this.isSaving = false,
    this.errorMessage,
    this.syncStatus = BoardSyncStatus.idle,
    this.syncMessage,
    this.lastSeenFileFingerprint,
    this.sortMode = BoardCardSort.manual,
  });

  final BoardDocument? document;
  final List<String> recentFiles;
  final String filterQuery;
  final String? selectedRecordId;
  final bool isLoading;
  final bool isSaving;
  final String? errorMessage;
  final BoardSyncStatus syncStatus;
  final String? syncMessage;
  final String? lastSeenFileFingerprint;
  final BoardCardSort sortMode;

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
    BoardSyncStatus? syncStatus,
    String? syncMessage,
    bool clearSyncMessage = false,
    String? lastSeenFileFingerprint,
    BoardCardSort? sortMode,
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
      syncStatus: syncStatus ?? this.syncStatus,
      syncMessage: clearSyncMessage ? null : (syncMessage ?? this.syncMessage),
      lastSeenFileFingerprint: lastSeenFileFingerprint ?? this.lastSeenFileFingerprint,
      sortMode: sortMode ?? this.sortMode,
    );
  }
}

class BoardController extends StateNotifier<BoardState> {
  BoardController(
    this._csvService,
    this._preferences, {
    Duration reloadDebounce = const Duration(milliseconds: 450),
  })  : _reloadDebounce = reloadDebounce,
        super(const BoardState());

  final CsvDocumentService _csvService;
  final BoardPreferencesStore _preferences;
  final Duration _reloadDebounce;

  StreamSubscription<FileSystemEvent>? _watchSubscription;
  Timer? _reloadTimer;
  bool _saveInProgress = false;
  BoardDocument? _queuedSaveDocument;
  final Set<String> _selfSaveFingerprints = <String>{};

  @override
  void dispose() {
    _reloadTimer?.cancel();
    _watchSubscription?.cancel();
    super.dispose();
  }

  Future<void> loadRecentFiles() async {
    final files = await _preferences.loadRecentFiles();
    state = state.copyWith(recentFiles: files);
  }

  Future<void> openFile(String filePath) async {
    _stopWatching();
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearSelectedRecord: true,
      clearSyncMessage: true,
      syncStatus: BoardSyncStatus.reloading,
    );

    try {
      final document = await _csvService.openDocument(filePath);
      final hydrated = await _hydrateOpenedDocument(document);
      await _preferences.saveRecentFile(filePath);
      final recentFiles = await _preferences.loadRecentFiles();
      state = state.copyWith(
        document: hydrated,
        recentFiles: recentFiles,
        filterQuery: '',
        isLoading: false,
        syncStatus: BoardSyncStatus.idle,
        lastSeenFileFingerprint: hydrated.fileFingerprint,
        clearError: true,
        clearSyncMessage: true,
      );
      _startWatching(filePath);
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        syncStatus: BoardSyncStatus.error,
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
        syncStatus: BoardSyncStatus.error,
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
      syncStatus: BoardSyncStatus.idle,
      clearError: true,
      clearSyncMessage: true,
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
              ..sort((left, right) => _compareRecords(left, right, mapping)),
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
      BoardRecord(
        id: recordId,
        rowKey: recordId,
        sourceRowIndex: nextIndex,
        values: values,
      ),
    ];
    final nextStatuses = _csvService.deriveStatusOrder(
      nextRecords,
      mapping,
      preferredOrder: [...document.statusOrder, targetStatus],
    );

    final nextDocument = _buildDirtyDocument(
      document,
      nextRecords,
      statusOrder: nextStatuses,
    );
    state = state.copyWith(
      document: nextDocument,
      selectedRecordId: recordId,
      isSaving: true,
      syncStatus: BoardSyncStatus.saving,
      clearError: true,
      clearSyncMessage: true,
    );
    _persistStatusOrder(nextDocument, nextStatuses);
    _enqueueAutoSave(nextDocument);
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
    final nextDocument = document.copyWith(statusOrder: nextStatuses);
    state = state.copyWith(
      document: nextDocument,
      syncStatus: BoardSyncStatus.idle,
      clearError: true,
      clearSyncMessage: true,
    );
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

    final changedRows = document.records.where(
      (record) => record.read(mapping.statusColumn).trim() == previousName,
    );
    final hasRecordChanges = changedRows.isNotEmpty;
    final nextDocument = hasRecordChanges
        ? _buildDirtyDocument(document, nextRecords, statusOrder: nextStatuses)
        : document.copyWith(statusOrder: nextStatuses);

    state = state.copyWith(
      document: nextDocument,
      isSaving: hasRecordChanges,
      syncStatus: hasRecordChanges ? BoardSyncStatus.saving : BoardSyncStatus.idle,
      clearError: true,
      clearSyncMessage: true,
    );
    _persistStatusOrder(nextDocument, nextStatuses);
    if (hasRecordChanges) {
      _enqueueAutoSave(nextDocument);
    }
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

    final nextDocument = _buildDirtyDocument(
      document,
      nextRecords,
      statusOrder: nextStatuses,
    );
    state = state.copyWith(
      document: nextDocument,
      isSaving: true,
      syncStatus: BoardSyncStatus.saving,
      clearError: true,
      clearSyncMessage: true,
    );
    _persistStatusOrder(nextDocument, nextStatuses);
    _enqueueAutoSave(nextDocument);
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

    final nextDocument = _buildDirtyDocument(
      document,
      nextRecords,
      statusOrder: nextStatuses,
    );
    state = state.copyWith(
      document: nextDocument,
      isSaving: true,
      syncStatus: BoardSyncStatus.saving,
      clearError: true,
      clearSyncMessage: true,
    );
    _persistStatusOrder(nextDocument, nextStatuses);
    _enqueueAutoSave(nextDocument);
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
    state = state.copyWith(
      document: nextDocument,
      syncStatus: BoardSyncStatus.idle,
      clearError: true,
      clearSyncMessage: true,
    );
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

  void setSortMode(BoardCardSort sortMode) {
    state = state.copyWith(sortMode: sortMode);
  }

  Future<void> saveDocument() async {
    final document = state.document;
    final mapping = document?.mapping;
    if (document == null || mapping == null) {
      return;
    }

    state = state.copyWith(
      isSaving: true,
      syncStatus: BoardSyncStatus.saving,
      clearError: true,
      clearSyncMessage: true,
    );
    _enqueueAutoSave(document);
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  void clearSyncMessage() {
    state = state.copyWith(
      clearSyncMessage: true,
      syncStatus: state.syncStatus == BoardSyncStatus.externalUpdate
          ? BoardSyncStatus.idle
          : state.syncStatus,
    );
  }

  bool _matchesFilter(BoardRecord record, String filter) {
    return record.values.values.any(
      (value) => value.toLowerCase().contains(filter),
    );
  }

  int _compareRecords(
    BoardRecord left,
    BoardRecord right,
    CsvColumnMapping mapping,
  ) {
    switch (state.sortMode) {
      case BoardCardSort.manual:
        return left.sourceRowIndex.compareTo(right.sourceRowIndex);
      case BoardCardSort.titleAscending:
        return _compareStrings(
          left.read(mapping.titleColumn),
          right.read(mapping.titleColumn),
          fallback: left.sourceRowIndex.compareTo(right.sourceRowIndex),
        );
      case BoardCardSort.titleDescending:
        return _compareStrings(
          right.read(mapping.titleColumn),
          left.read(mapping.titleColumn),
          fallback: left.sourceRowIndex.compareTo(right.sourceRowIndex),
        );
      case BoardCardSort.dueDateAscending:
        return _compareDueDates(left, right, mapping, ascending: true);
      case BoardCardSort.dueDateDescending:
        return _compareDueDates(left, right, mapping, ascending: false);
    }
  }

  int _compareDueDates(
    BoardRecord left,
    BoardRecord right,
    CsvColumnMapping mapping, {
    required bool ascending,
  }) {
    final dueDateColumn = mapping.dueDateColumn;
    if (dueDateColumn == null) {
      return left.sourceRowIndex.compareTo(right.sourceRowIndex);
    }

    final leftDate = _parseSortableDate(left.read(dueDateColumn));
    final rightDate = _parseSortableDate(right.read(dueDateColumn));
    if (leftDate == null && rightDate == null) {
      return _compareStrings(
        left.read(mapping.titleColumn),
        right.read(mapping.titleColumn),
        fallback: left.sourceRowIndex.compareTo(right.sourceRowIndex),
      );
    }
    if (leftDate == null) {
      return 1;
    }
    if (rightDate == null) {
      return -1;
    }

    final comparison = leftDate.compareTo(rightDate);
    if (comparison != 0) {
      return ascending ? comparison : -comparison;
    }

    return _compareStrings(
      left.read(mapping.titleColumn),
      right.read(mapping.titleColumn),
      fallback: left.sourceRowIndex.compareTo(right.sourceRowIndex),
    );
  }

  int _compareStrings(String left, String right, {required int fallback}) {
    final normalizedLeft = left.trim().toLowerCase();
    final normalizedRight = right.trim().toLowerCase();
    if (normalizedLeft.isEmpty && normalizedRight.isEmpty) {
      return fallback;
    }
    if (normalizedLeft.isEmpty) {
      return 1;
    }
    if (normalizedRight.isEmpty) {
      return -1;
    }
    final comparison = normalizedLeft.compareTo(normalizedRight);
    return comparison == 0 ? fallback : comparison;
  }

  DateTime? _parseSortableDate(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final parsed = DateTime.tryParse(trimmed);
    if (parsed != null) {
      return parsed;
    }

    final match = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})$').firstMatch(trimmed);
    if (match == null) {
      return null;
    }

    final month = int.tryParse(match.group(1)!);
    final day = int.tryParse(match.group(2)!);
    var year = int.tryParse(match.group(3)!);
    if (month == null || day == null || year == null) {
      return null;
    }
    if (year < 100) {
      year += 2000;
    }

    return DateTime.tryParse(
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}',
    );
  }

  Future<BoardDocument> _hydrateOpenedDocument(BoardDocument document) async {
    final mapping = await _preferences.loadMapping(
      document.filePath,
      document.headerFingerprint,
    );
    final savedStatusOrder = await _preferences.loadStatusOrder(
      document.filePath,
      document.headerFingerprint,
    );
    final detectedMapping = CsvColumnMapping.autoDetect(document.headers);
    final resolvedMapping =
        mapping != null && mapping.isValidForHeaders(document.headers)
            ? mapping
            : detectedMapping;
    final statusOrder = resolvedMapping == null
        ? const <String>[]
        : _csvService.deriveStatusOrder(
            document.records,
            resolvedMapping,
            preferredOrder: savedStatusOrder ?? const [],
          );

    return document.copyWith(
      mapping: resolvedMapping,
      keepExistingMapping: false,
      statusOrder: statusOrder,
      dirty: false,
    );
  }

  Future<void> _reloadFromWatcher() async {
    final document = state.document;
    if (document == null) {
      return;
    }

    try {
      final fingerprint = await _csvService.readFileFingerprintFromDisk(document.filePath);
      if (_selfSaveFingerprints.remove(fingerprint)) {
        state = state.copyWith(lastSeenFileFingerprint: fingerprint);
        return;
      }
      if (fingerprint == document.fileFingerprint ||
          fingerprint == state.lastSeenFileFingerprint) {
        return;
      }
      await _reloadDocumentFromDisk(externalChange: true);
    } catch (error) {
      state = state.copyWith(
        syncStatus: BoardSyncStatus.error,
        errorMessage: error.toString(),
      );
    }
  }

  Future<void> _reloadDocumentFromDisk({required bool externalChange}) async {
    final current = state.document;
    if (current == null) {
      return;
    }

    _queuedSaveDocument = null;
    state = state.copyWith(
      syncStatus: BoardSyncStatus.reloading,
      isSaving: false,
      clearError: true,
    );

    try {
      final reloaded = await _csvService.reloadDocumentFromDisk(current.filePath);
      final hydrated = await _hydrateReloadedDocument(reloaded, current);
      final selectedRowKey = _selectedRowKey(current, state.selectedRecordId);
      final selectedRecordId = _selectedRecordIdForRowKey(hydrated, selectedRowKey);
      final headersChanged = current.headerFingerprint != hydrated.headerFingerprint;
      final message = headersChanged && hydrated.mapping == null
          ? 'CSV headers changed. Review the field mapping.'
          : 'CSV updated from disk.';

      state = state.copyWith(
        document: hydrated,
        selectedRecordId: selectedRecordId,
        clearSelectedRecord: selectedRecordId == null,
        isSaving: false,
        syncStatus: externalChange ? BoardSyncStatus.externalUpdate : BoardSyncStatus.idle,
        syncMessage: externalChange ? message : null,
        lastSeenFileFingerprint: hydrated.fileFingerprint,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        syncStatus: BoardSyncStatus.error,
        isSaving: false,
        errorMessage: error.toString(),
      );
    }
  }

  Future<BoardDocument> _hydrateReloadedDocument(
    BoardDocument reloaded,
    BoardDocument previous,
  ) async {
    final savedMapping = await _preferences.loadMapping(
      reloaded.filePath,
      reloaded.headerFingerprint,
    );
    final savedStatusOrder = await _preferences.loadStatusOrder(
      reloaded.filePath,
      reloaded.headerFingerprint,
    );

    CsvColumnMapping? resolvedMapping;
    if (previous.headerFingerprint == reloaded.headerFingerprint &&
        previous.mapping != null &&
        previous.mapping!.isValidForHeaders(reloaded.headers)) {
      resolvedMapping = previous.mapping;
    } else if (savedMapping != null && savedMapping.isValidForHeaders(reloaded.headers)) {
      resolvedMapping = savedMapping;
    } else if (previous.mapping != null && previous.mapping!.isValidForHeaders(reloaded.headers)) {
      resolvedMapping = previous.mapping;
      await _preferences.saveMapping(
        reloaded.filePath,
        reloaded.headerFingerprint,
        resolvedMapping!,
      );
    }

    final statusOrder = resolvedMapping == null
        ? const <String>[]
        : _csvService.deriveStatusOrder(
            reloaded.records,
            resolvedMapping,
            preferredOrder: savedStatusOrder ?? previous.statusOrder,
          );
    if (resolvedMapping != null) {
      await _preferences.saveStatusOrder(
        reloaded.filePath,
        reloaded.headerFingerprint,
        statusOrder,
      );
    }

    return reloaded.copyWith(
      mapping: resolvedMapping,
      keepExistingMapping: false,
      statusOrder: statusOrder,
      dirty: false,
      lastSavedAt: previous.lastSavedAt,
    );
  }

  BoardDocument _buildDirtyDocument(
    BoardDocument document,
    List<BoardRecord> nextRecords, {
    required List<String> statusOrder,
  }) {
    final rekeyedRecords = _csvService.rekeyRecords(nextRecords, document.headers);
    return document.copyWith(
      records: rekeyedRecords,
      dirty: true,
      clearLastSavedAt: true,
      statusOrder: statusOrder,
    );
  }

  String? _selectedRowKey(BoardDocument document, String? recordId) {
    if (recordId == null) {
      return null;
    }
    for (final record in document.records) {
      if (record.id == recordId) {
        return record.rowKey;
      }
    }
    return null;
  }

  String? _selectedRecordIdForRowKey(BoardDocument document, String? rowKey) {
    if (rowKey == null) {
      return null;
    }
    for (final record in document.records) {
      if (record.rowKey == rowKey) {
        return record.id;
      }
    }
    return null;
  }

  void _startWatching(String filePath) {
    _watchSubscription = _csvService.watchDocument(filePath).listen((_) {
      _reloadTimer?.cancel();
      _reloadTimer = Timer(_reloadDebounce, () {
        unawaited(_reloadFromWatcher());
      });
    });
  }

  void _stopWatching() {
    _reloadTimer?.cancel();
    _reloadTimer = null;
    _watchSubscription?.cancel();
    _watchSubscription = null;
    _queuedSaveDocument = null;
    _selfSaveFingerprints.clear();
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

  void _enqueueAutoSave(BoardDocument document) {
    _queuedSaveDocument = document;
    if (_saveInProgress) {
      return;
    }
    unawaited(_drainAutoSaveQueue());
  }

  Future<void> _drainAutoSaveQueue() async {
    if (_saveInProgress) {
      return;
    }

    _saveInProgress = true;
    try {
      while (_queuedSaveDocument != null) {
        final document = _queuedSaveDocument!;
        _queuedSaveDocument = null;

        try {
          final currentFingerprint = await _csvService.readFileFingerprintFromDisk(
            document.filePath,
          );
          if (currentFingerprint != document.fileFingerprint &&
              !_selfSaveFingerprints.contains(currentFingerprint)) {
            await _reloadDocumentFromDisk(externalChange: true);
            continue;
          }
        } catch (_) {
          // Ignore preflight read failures and rely on save/reload handling below.
        }

        try {
          final result = await _csvService.saveDocument(document);
          _selfSaveFingerprints.add(result.fileFingerprint);

          if (identical(state.document, document)) {
            state = state.copyWith(
              document: document.copyWith(
                dirty: false,
                lastSavedAt: result.savedAt,
                fileFingerprint: result.fileFingerprint,
              ),
              isSaving: false,
              syncStatus: BoardSyncStatus.idle,
              lastSeenFileFingerprint: result.fileFingerprint,
              clearError: true,
            );
          } else if (state.syncStatus == BoardSyncStatus.saving) {
            state = state.copyWith(
              isSaving: _queuedSaveDocument != null,
              syncStatus:
                  _queuedSaveDocument != null ? BoardSyncStatus.saving : BoardSyncStatus.idle,
              clearError: true,
            );
          }
        } catch (error) {
          if (identical(state.document, document)) {
            state = state.copyWith(
              isSaving: false,
              syncStatus: BoardSyncStatus.error,
              errorMessage: error.toString(),
            );
          }
        }
      }
    } finally {
      _saveInProgress = false;
    }
  }
}




