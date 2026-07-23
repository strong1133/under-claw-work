enum AuthProviderStatus { pendingSelection, accepted }

class AuthContext {
  const AuthContext({
    required this.repositoryId,
    required this.policyVersion,
    required this.environmentId,
  });

  final String repositoryId;
  final int policyVersion;
  final String environmentId;
}

class AuthGrant {
  const AuthGrant({
    required this.id,
    required this.repositoryId,
    required this.policyVersion,
    required this.environmentId,
    required this.expiresAt,
  });

  final String id;
  final String repositoryId;
  final int policyVersion;
  final String environmentId;
  final DateTime expiresAt;

  bool isValidFor(AuthContext context, DateTime now) =>
      repositoryId == context.repositoryId &&
      policyVersion == context.policyVersion &&
      environmentId == context.environmentId &&
      expiresAt.isAfter(now.toUtc());
}

abstract interface class RepositoryAuthProvider {
  String get providerId;

  /// The provider consumes [password] but must never persist, echo, or log it.
  Future<AuthGrant> authenticate(AuthContext context, String password);

  Future<AuthGrant> register(AuthContext context, String password);

  Future<AuthGrant> rotate(
    AuthContext context,
    String currentPassword,
    String newPassword,
  );
}

class AuthUnavailable implements Exception {
  const AuthUnavailable(this.message);
  final String message;
  @override
  String toString() => 'AuthUnavailable: $message';
}

class AuthRateLimited implements Exception {
  const AuthRateLimited(this.retryAfter);
  final Duration retryAfter;
  @override
  String toString() =>
      'AuthRateLimited: retry after ${retryAfter.inSeconds} seconds';
}

class RepositoryAuthGate {
  RepositoryAuthGate({
    this.status = AuthProviderStatus.pendingSelection,
    this.provider,
    DateTime Function()? clock,
    this.maximumAttempts = 5,
    this.window = const Duration(minutes: 5),
    this.lockout = const Duration(minutes: 15),
  }) : _clock = clock ?? DateTime.now;

  final AuthProviderStatus status;
  final RepositoryAuthProvider? provider;
  final DateTime Function() _clock;
  final int maximumAttempts;
  final Duration window;
  final Duration lockout;
  final Map<String, _AttemptWindow> _attempts = {};
  AuthGrant? _session;

  bool get canAcceptPassword =>
      status == AuthProviderStatus.accepted && provider != null;

  AuthGrant? sessionFor(AuthContext context) {
    final session = _session;
    return session != null && session.isValidFor(context, _clock())
        ? session
        : null;
  }

  Future<AuthGrant> unlock(AuthContext context, String password) =>
      _perform(context, password, provider?.authenticate);

  Future<AuthGrant> register(
    AuthContext context,
    String password,
    String confirmation,
  ) {
    if (password != confirmation) {
      throw const FormatException('Password confirmation does not match.');
    }
    return _perform(context, password, provider?.register);
  }

  Future<AuthGrant> changePassword(
    AuthContext context,
    String currentPassword,
    String newPassword,
    String confirmation,
  ) async {
    _requireProvider();
    if (newPassword != confirmation) {
      throw const FormatException('Password confirmation does not match.');
    }
    _checkRateLimit(context);
    try {
      final grant = await provider!.rotate(
        context,
        currentPassword,
        newPassword,
      );
      _validateGrant(context, grant);
      _attempts.remove(_key(context));
      _session = grant;
      return grant;
    } catch (_) {
      _recordFailure(context);
      rethrow;
    }
  }

  void lock() => _session = null;

  Future<AuthGrant> _perform(
    AuthContext context,
    String password,
    Future<AuthGrant> Function(AuthContext, String)? action,
  ) async {
    _requireProvider();
    _checkRateLimit(context);
    try {
      final grant = await action!(context, password);
      _validateGrant(context, grant);
      _attempts.remove(_key(context));
      _session = grant;
      return grant;
    } catch (_) {
      _recordFailure(context);
      rethrow;
    }
  }

  void _requireProvider() {
    if (!canAcceptPassword) {
      throw const AuthUnavailable(
        'Repository authentication remains locked until a reviewed provider '
        'passes the acceptance gate.',
      );
    }
  }

  void _validateGrant(AuthContext context, AuthGrant grant) {
    if (!grant.isValidFor(context, _clock())) {
      throw const AuthUnavailable(
        'Provider returned an expired or incorrectly bound grant.',
      );
    }
  }

  void _checkRateLimit(AuthContext context) {
    final now = _clock().toUtc();
    final attempts = _attempts[_key(context)];
    if (attempts == null) return;
    if (attempts.lockedUntil?.isAfter(now) ?? false) {
      throw AuthRateLimited(attempts.lockedUntil!.difference(now));
    }
    if (now.difference(attempts.startedAt) >= window) {
      _attempts.remove(_key(context));
    }
  }

  void _recordFailure(AuthContext context) {
    final now = _clock().toUtc();
    final key = _key(context);
    final previous = _attempts[key];
    final attempts =
        previous == null || now.difference(previous.startedAt) >= window
        ? _AttemptWindow(now, 1)
        : _AttemptWindow(previous.startedAt, previous.count + 1);
    if (attempts.count >= maximumAttempts) {
      attempts.lockedUntil = now.add(lockout);
    }
    _attempts[key] = attempts;
  }

  String _key(AuthContext context) =>
      '${context.repositoryId}\u0000${context.environmentId}';
}

class _AttemptWindow {
  _AttemptWindow(this.startedAt, this.count);
  final DateTime startedAt;
  final int count;
  DateTime? lockedUntil;
}
