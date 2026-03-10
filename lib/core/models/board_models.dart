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

  static CsvColumnMapping? autoDetect(List<String> headers) {
    if (headers.length < 2) {
      return null;
    }

    final status = _bestHeader(headers, const [
      'status',
      'state',
      'stage',
      'column',
      'lane',
      'workflow',
      'phase',
    ]);
    if (status == null) {
      return null;
    }

    final title = _bestHeader(
          headers,
          const [
            'title',
            'task',
            'name',
            'summary',
            'subject',
            'item',
            'card',
          ],
          exclude: {status},
        ) ??
        headers.firstWhere(
          (header) => header != status,
          orElse: () => status,
        );
    if (title == status) {
      return null;
    }

    final description = _bestHeader(
      headers,
      const ['description', 'details', 'detail', 'notes', 'body'],
      exclude: {status, title},
    );

    final assigneeExclude = <String>{status, title};
    if (description != null) {
      assigneeExclude.add(description);
    }
    final assignee = _bestHeader(
      headers,
      const ['assignee', 'assigned', 'owner', 'responsible', 'person'],
      exclude: assigneeExclude,
    );

    final dueDateExclude = <String>{status, title};
    if (description != null) {
      dueDateExclude.add(description);
    }
    if (assignee != null) {
      dueDateExclude.add(assignee);
    }
    final dueDate = _bestHeader(
      headers,
      const ['due date', 'due', 'deadline', 'target date', 'eta'],
      exclude: dueDateExclude,
    );

    return CsvColumnMapping(
      titleColumn: title,
      statusColumn: status,
      descriptionColumn: description,
      assigneeColumn: assignee,
      dueDateColumn: dueDate,
    );
  }

  static String? _bestHeader(
    List<String> headers,
    List<String> keywords, {
    Set<String> exclude = const {},
  }) {
    var bestScore = 0;
    String? bestHeader;

    for (final header in headers) {
      if (exclude.contains(header)) {
        continue;
      }
      final normalized = _normalizeHeader(header);
      for (final keyword in keywords) {
        final normalizedKeyword = _normalizeHeader(keyword);
        final score = _keywordScore(normalized, normalizedKeyword);
        if (score > bestScore) {
          bestScore = score;
          bestHeader = header;
        }
      }
    }

    return bestScore >= 60 ? bestHeader : null;
  }

  static int _keywordScore(String header, String keyword) {
    if (header == keyword) {
      return 100;
    }
    if (header.replaceAll(' ', '') == keyword.replaceAll(' ', '')) {
      return 95;
    }
    if (header.startsWith('$keyword ') ||
        header.endsWith(' $keyword') ||
        header.contains(' $keyword ')) {
      return 85;
    }
    if (header.contains(keyword)) {
      return 60;
    }
    return 0;
  }

  static String _normalizeHeader(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
  }

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
    required this.rowKey,
    required this.sourceRowIndex,
    required Map<String, String> values,
  }) : values = Map<String, String>.unmodifiable(values);

  final String id;
  final String rowKey;
  final int sourceRowIndex;
  final Map<String, String> values;

  String read(String header) => values[header] ?? '';

  BoardRecord copyWith({
    String? id,
    String? rowKey,
    int? sourceRowIndex,
    Map<String, String>? values,
  }) {
    return BoardRecord(
      id: id ?? this.id,
      rowKey: rowKey ?? this.rowKey,
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
    required this.fileFingerprint,
    required this.headers,
    required this.records,
    required this.headerFingerprint,
    this.mapping,
    this.dirty = false,
    this.lastSavedAt,
    this.statusOrder = const [],
  });

  final String filePath;
  final String fileFingerprint;
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
    String? fileFingerprint,
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
      fileFingerprint: fileFingerprint ?? this.fileFingerprint,
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
