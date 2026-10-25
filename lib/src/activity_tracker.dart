/// The app's foreground time between events, for `app_state` and `engaged_ms` (active and passive sessions).
library;

/// Active and background moments in, one stamp per event tracked now out.
class ActivityTracker {
  /// The longest engaged time one event reports: a day, as the server accepts.
  static const int maxEngagedMilliseconds = 86400000;

  /// True while the app is in front.
  bool _isInFront;

  /// When the current foreground stretch started, or the last stamp inside it.
  DateTime? _activeSince;

  /// Foreground time from stretches that ended since the last stamp.
  int _finishedActiveMilliseconds = 0;

  /// Starts in the given state, e.g. active when the app launched in front.
  ActivityTracker({required bool isActive, required DateTime at})
      : _isInFront = isActive,
        _activeSince = isActive ? at : null;

  /// The app came to the front, or left it.
  void setActive(bool isActive, DateTime at) {
    if (isActive == _isInFront) {
      return;
    }

    // Leaving keeps the stretch for the next stamp; coming back starts a new one.
    if (_isInFront) {
      _finishedActiveMilliseconds += _currentActiveMilliseconds(at);
    }

    _isInFront = isActive;
    _activeSince = isActive ? at : null;
  }

  /// The props for one event tracked now, counting afresh from it.
  Map<String, Object> stamp(DateTime at) {
    final engagedMilliseconds = _finishedActiveMilliseconds + _currentActiveMilliseconds(at);
    _finishedActiveMilliseconds = 0;
    _activeSince = _isInFront ? at : null;

    if (!_isInFront) {
      return {'app_state': 'background'};
    }

    return {
      'app_state': 'active',
      'engaged_ms': engagedMilliseconds > maxEngagedMilliseconds ? maxEngagedMilliseconds : engagedMilliseconds,
    };
  }

  // The current stretch's length up to now, never negative.
  int _currentActiveMilliseconds(DateTime at) {
    final activeSince = _activeSince;
    if (activeSince == null) {
      return 0;
    }

    final activeMilliseconds = at.difference(activeSince).inMilliseconds;
    return activeMilliseconds < 0 ? 0 : activeMilliseconds;
  }
}
