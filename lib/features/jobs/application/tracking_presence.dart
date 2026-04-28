class TrackingSnapshot {
  const TrackingSnapshot({
    required this.updatedAt,
    required this.isFresh,
    required this.isTerminal,
    required this.isFromCache,
    required this.hasCoordinates,
    required this.hasTrackingSignal,
  });

  final DateTime? updatedAt;
  final bool isFresh;
  final bool isTerminal;
  final bool isFromCache;
  final bool hasCoordinates;
  final bool hasTrackingSignal;

  bool get isLive =>
      hasCoordinates &&
      hasTrackingSignal &&
      !isTerminal &&
      !isFromCache &&
      isFresh;

  bool get isOffline =>
      hasCoordinates && hasTrackingSignal && !isTerminal && !isLive;

  bool get shouldAppearInFeed =>
      hasCoordinates && hasTrackingSignal && !isTerminal;
}

class TrackingPresence {
  const TrackingPresence._();

  static const Duration freshnessWindow = Duration(minutes: 2);

  static const Set<String> _activeStatuses = <String>{
    'accepted',
    'in_progress',
    'active',
    'ongoing',
    'enroute',
    'on_the_way',
    'working',
    'started',
  };

  static const Set<String> _terminalStatuses = <String>{
    'ended',
    'stopped',
    'completed',
    'finished',
    'inactive',
    'off',
    'closed',
    '0',
    'false',
    'deleted',
    'archived',
    'removed',
  };

  static TrackingSnapshot evaluate(
    Map<String, dynamic> row, {
    DateTime? now,
    Duration freshness = freshnessWindow,
  }) {
    final updatedAt = parseDateTime(row['updated_at']);
    final hasCoordinates =
        asDouble(row['latitude']) != null && asDouble(row['longitude']) != null;
    final status = row['status']?.toString();
    final trackingStatus = row['tracking_status']?.toString();

    return TrackingSnapshot(
      updatedAt: updatedAt,
      isFresh: updatedAt != null &&
          (now ?? DateTime.now()).difference(updatedAt.toLocal()) <= freshness,
      isTerminal:
          isTerminalStatus(status) || isTerminalStatus(trackingStatus),
      isFromCache: asBool(row['is_from_cache']),
      hasCoordinates: hasCoordinates,
      hasTrackingSignal:
          isActiveStatus(status) ||
          isActiveStatus(trackingStatus) ||
          asBool(row['is_tracking']),
    );
  }

  static bool isActiveStatus(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return false;
    return _activeStatuses.contains(normalized);
  }

  static bool isTerminalStatus(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return false;
    return _terminalStatuses.contains(normalized);
  }

  static bool asBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value?.toString().trim().toLowerCase();
    if (text == null || text.isEmpty) return false;
    return text == '1' ||
        text == 'true' ||
        text == 'yes' ||
        text == 'y' ||
        text == 'on' ||
        text == 'active';
  }

  static double? asDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  static DateTime? parseDateTime(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text) ??
        DateTime.tryParse(text.replaceFirst(' ', 'T'));
  }
}
