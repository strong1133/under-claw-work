enum AuthProviderStatus { pendingSelection, ready }

class RepositoryAuthGate {
  const RepositoryAuthGate({this.status = AuthProviderStatus.pendingSelection});

  final AuthProviderStatus status;

  bool get canAcceptPassword => status == AuthProviderStatus.ready;

  Never unlock(String password) {
    throw UnsupportedError(
      'Repository authentication is locked until a reviewed external '
      'provider passes the security acceptance gate.',
    );
  }
}
