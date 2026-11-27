import 'dart:async';
import 'dart:io';

import 'package:flutter_hbb/yesdesk/enterprise/corporate_session.dart';
import 'package:flutter_hbb/yesdesk/storage/windows_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryVault implements CredentialStore {
  final entries = <String, String>{};

  @override
  bool get canPersist => true;

  @override
  String? read(String reference) => entries[reference];

  @override
  bool write(String reference, String value) {
    entries[reference] = value;
    return true;
  }

  @override
  bool delete(String reference) {
    entries.remove(reference);
    return true;
  }
}

Map<String, dynamic> session(String access, {int accessSeconds = 300}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return {
    'token': access,
    'profile': {
      'username': 'operator',
      'role': 'admin',
      'expires_at': now + accessSeconds,
      'session_expires_at': now + 43200,
    }
  };
}

void main() {
  const management = 'https://management.example.test/pilot';
  late MemoryVault vault;

  setUp(() => vault = MemoryVault());

  CorporateSession client(CorporateRequest request, {String url = management}) {
    final client =
        CorporateSession(managementUrl: url, vault: vault, request: request);
    addTearDown(client.dispose);
    return client;
  }

  test('persists only the refresh token and restores it for the same API',
      () async {
    final signedIn = client((uri, method, bearer, body) async {
      expect(uri.path, '/pilot/v2/auth/session');
      expect(method, 'POST');
      expect(bearer, isNull);
      expect(body,
          {'username': 'operator', 'password': 'secret', 'code': '123456'});
      return {...session('first-access'), 'refresh_token': 'refresh'};
    });
    await signedIn.signIn(' Operator ', 'secret', '123456');
    expect(signedIn.isAdmin, isTrue);
    expect(vault.entries.values.single, 'refresh');

    final otherApi = client((_, __, ___, ____) async {
      fail('An unrelated API should never receive a saved credential');
    }, url: 'https://management.example.test/another');
    await otherApi.restore();
    expect(otherApi.profile, isNull);

    final restarted = client((uri, method, bearer, body) async {
      expect(uri.path, '/pilot/v2/auth/refresh');
      expect(method, 'POST');
      expect(bearer, 'refresh');
      expect(body, isNull);
      return session('new-access');
    });
    await restarted.restore();
    expect(restarted.isAdmin, isTrue);
    expect(restarted.connectionCredentials.token, 'new-access');
  });

  test('temporary outage preserves the credential, server revocation clears it',
      () async {
    vault.write('Session $management', 'refresh');
    final offline = client((_, __, ___, ____) async {
      throw const SocketException('offline');
    });
    await offline.restore();
    expect(offline.profile, isNull);
    expect(vault.entries.values.single, 'refresh');

    final revoked = client((_, __, ___, ____) async {
      throw const CorporateApiError(401);
    });
    await revoked.restore();
    expect(revoked.profile, isNull);
    expect(vault.entries, isEmpty);
  });

  test('concurrent renewals share a request and logout wins over its reply',
      () async {
    final reply = Completer<Map<String, dynamic>>();
    var renewals = 0;
    final signedIn = client((uri, _, bearer, __) async {
      switch (uri.path) {
        case '/pilot/v2/auth/session':
          return {
            ...session('old-access', accessSeconds: 30),
            'refresh_token': 'refresh',
          };
        case '/pilot/v2/auth/refresh':
          expect(bearer, 'refresh');
          renewals++;
          return reply.future;
        case '/pilot/v2/auth/logout':
          expect(bearer, 'refresh');
          expect(vault.entries, isEmpty);
          return {'status': 'ok'};
        default:
          fail('No management request should be sent after logout');
      }
    });

    await signedIn.signIn('operator', 'secret', '123456');
    final first = expectLater(signedIn.api('/v2/accounts'), throwsStateError);
    final second = expectLater(signedIn.api('/v2/accounts'), throwsStateError);
    await signedIn.signOut();
    reply.complete(session('late-access'));
    await Future.wait([first, second]);
    expect(renewals, 1);
    expect(signedIn.profile, isNull);
    expect(vault.entries, isEmpty);
  });

  test('older API falls back to memory-only login', () async {
    final signedIn = client((uri, _, bearer, __) async {
      switch (uri.path) {
        case '/pilot/v2/auth/session':
          throw const CorporateApiError(404);
        case '/pilot/v2/auth/login':
          final result = session('legacy');
          (result['profile'] as Map).remove('session_expires_at');
          return result;
        case '/pilot/v2/auth/logout':
          expect(bearer, 'legacy');
          return {'status': 'ok'};
        default:
          fail('Unexpected request');
      }
    });

    await signedIn.signIn('operator', 'secret', '123456');
    expect(signedIn.isAdmin, isTrue);
    expect(vault.entries, isEmpty);
    await signedIn.signOut();
    expect(signedIn.profile, isNull);
  });
}
