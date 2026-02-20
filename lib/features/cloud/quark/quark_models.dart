class QuarkAuthState {
  const QuarkAuthState({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAtEpochMs,
    this.cookie,
  });

  final String accessToken;
  final String refreshToken;
  final int expiresAtEpochMs;
  final String? cookie;

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch >= expiresAtEpochMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAtEpochMs': expiresAtEpochMs,
    'cookie': cookie,
  };

  factory QuarkAuthState.fromJson(Map<String, dynamic> json) {
    return QuarkAuthState(
      accessToken: json['accessToken']?.toString() ?? '',
      refreshToken: json['refreshToken']?.toString() ?? '',
      expiresAtEpochMs: (json['expiresAtEpochMs'] as num?)?.toInt() ?? 0,
      cookie: json['cookie']?.toString(),
    );
  }
}

class QuarkQrSession {
  const QuarkQrSession({
    required this.sessionId,
    required this.qrCodeUrl,
    required this.expiresAt,
  });

  final String sessionId;
  final String qrCodeUrl;
  final DateTime expiresAt;
}

class QuarkQrPollResult {
  const QuarkQrPollResult({required this.status, this.authState});

  final String status;
  final QuarkAuthState? authState;

  bool get isSuccess => status == 'confirmed' && authState != null;
}

class QuarkShareRef {
  const QuarkShareRef({required this.shareUrl, this.fileName});

  final String shareUrl;
  final String? fileName;
}

class QuarkSavedFile {
  const QuarkSavedFile({
    required this.fileId,
    required this.fileName,
    required this.parentDir,
    this.parentFolderId,
  });

  final String fileId;
  final String fileName;
  final String parentDir;
  final String? parentFolderId;
}

class QuarkFolderLookupResult {
  const QuarkFolderLookupResult({
    required this.folderId,
    required this.folderName,
    required this.created,
    required this.path,
  });

  final String folderId;
  final String folderName;
  final bool created;
  final String path;
}

class QuarkFileEntry {
  const QuarkFileEntry({
    required this.fileId,
    required this.fileName,
    required this.isDirectory,
    this.size,
    this.updatedAtEpochMs,
  });

  final String fileId;
  final String fileName;
  final bool isDirectory;
  final int? size;
  final int? updatedAtEpochMs;
}

class QuarkPlayableFile {
  const QuarkPlayableFile({
    required this.url,
    required this.headers,
    this.subtitle,
  });

  final String url;
  final Map<String, String> headers;
  final String? subtitle;
}

class QuarkShareFileEntry {
  const QuarkShareFileEntry({
    required this.fid,
    required this.fileName,
    required this.pdirFid,
    required this.shareFidToken,
    required this.isDirectory,
    this.updatedAtEpochMs,
  });

  final String fid;
  final String fileName;
  final String pdirFid;
  final String shareFidToken;
  final bool isDirectory;
  final int? updatedAtEpochMs;
}

class QuarkException implements Exception {
  QuarkException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'QuarkException($code): $message';
}
