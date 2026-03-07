class CsvColumnMapping {
  const CsvColumnMapping({
    required this.titleColumn,
    required this.statusColumn,
    this.descriptionColumn,
    this.assigneeColumn,
    this.dueDateColumn,
    this.extraVisibleColumns = const [],
  });

  final String titleColumn;
  final String statusColumn;
  final String? descriptionColumn;
  final String? assigneeColumn;
  final String? dueDateColumn;
  final List<String> extraVisibleColumns;

  Set<String> get mappedColumns => <String>{
    titleColumn,
    statusColumn,
    ...<String?>[
      descriptionColumn,
      assigneeColumn,
      dueDateColumn,
    ].whereType<String>(),
    ...extraVisibleColumns,
  };

  bool isValidForHeaders(List<String> headers) {
    return mappedColumns.every(headers.contains);
  }

  String? labelForHeader(String header) {
    if (header == titleColumn) {
      return 'Title';
    }
    if (header == statusColumn) {
      return 'Status';
    }
    if (header == descriptionColumn) {
      return 'Description';
    }
    if (header == assigneeColumn) {
      return 'Assignee';
    }
    if (header == dueDateColumn) {
      return 'Due date';
    }
    if (extraVisibleColumns.contains(header)) {
      return 'Visible field';
    }
    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'titleColumn': titleColumn,
      'statusColumn': statusColumn,
      'descriptionColumn': descriptionColumn,
      'assigneeColumn': assigneeColumn,
      'dueDateColumn': dueDateColumn,
      'extraVisibleColumns': extraVisibleColumns,
    };
  }

  factory CsvColumnMapping.fromJson(Map<String, dynamic> json) {
    return CsvColumnMapping(
      titleColumn: json['titleColumn'] as String,
      statusColumn: json['statusColumn'] as String,
      descriptionColumn: json['descriptionColumn'] as String?,
      assigneeColumn: json['assigneeColumn'] as String?,
      dueDateColumn: json['dueDateColumn'] as String?,
      extraVisibleColumns:
          (json['extraVisibleColumns'] as List<dynamic>? ?? const []).cast<String>(),
    );
  }
}

class BoardRecord {
  BoardRecord({
    required this.id,
    required this.sourceRowIndex,
    required Map<String, String> values,
  }) : values = Map<String, String>.unmodifiable(values);

  final String id;
  final int sourceRowIndex;
  final Map<String, String> values;

  String read(String header) => values[header] ?? '';

  BoardRecord copyWith({
    String? id,
    int? sourceRowIndex,
    Map<String, String>? values,
  }) {
    return BoardRecord(
      id: id ?? this.id,
      sourceRowIndex: sourceRowIndex ?? this.sourceRowIndex,
      values: values ?? this.values,
    );
  }
}

class BoardColumn {
  const BoardColumn({required this.name, required this.records});

  final String name;
  final List<BoardRecord> records;
}

class BoardDocument {
  const BoardDocument({
    required this.filePath,
    required this.headers,
    required this.records,
    required this.headerFingerprint,
    this.mapping,
    this.dirty = false,
    this.lastSavedAt,
    this.statusOrder = const [],
  });

  final String filePath;
  final List<String> headers;
  final List<BoardRecord> records;
  final String headerFingerprint;
  final CsvColumnMapping? mapping;
  final bool dirty;
  final DateTime? lastSavedAt;
  final List<String> statusOrder;

  String get fileName {
    final normalized = filePath.replaceAll('\\', '/');
    return normalized.split('/').last;
  }

  BoardDocument copyWith({
    List<String>? headers,
    List<BoardRecord>? records,
    CsvColumnMapping? mapping,
    bool keepExistingMapping = true,
    bool? dirty,
    DateTime? lastSavedAt,
    bool clearLastSavedAt = false,
    List<String>? statusOrder,
  }) {
    return BoardDocument(
      filePath: filePath,
      headers: headers ?? this.headers,
      records: records ?? this.records,
      headerFingerprint: headerFingerprint,
      mapping: keepExistingMapping ? (mapping ?? this.mapping) : mapping,
      dirty: dirty ?? this.dirty,
      lastSavedAt: clearLastSavedAt ? null : (lastSavedAt ?? this.lastSavedAt),
      statusOrder: statusOrder ?? this.statusOrder,
    );
  }
}
