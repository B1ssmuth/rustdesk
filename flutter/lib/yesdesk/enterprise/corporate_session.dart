import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../storage/windows_credentials.dart';

final corporateSession = CorporateSession();

typedef CorporateRequest = Future<dynamic> Function(
    Uri uri, String method, String? bearer, Map<String, dynamic>? body);

class CorporateSession extends ChangeNotifier {
  CorporateSession({
    String managementUrl =
        const String.fromEnvironment('YESDESK_MANAGEMENT_URL'),
    CredentialStore vault = const WindowsCredentialStore('Enterprise'),
    CorporateRequest? request,
  })  : _base = Uri.tryParse(managementUrl),
        _vault = vault,
        _transport = request ?? _sendRequest;

  final Uri? _base;
  final CredentialStore _vault;
  final CorporateRequest _transport;
  String? _token;
  String? _refreshToken;
  DateTime? _accessExpiry;
  DateTime? _sessionExpiry;
  Timer? _revalidate;
  Timer? _expiry;
  Future<void>? _refreshFlight;
  Map<String, dynamic>? _profile;
  bool signingIn = false;
  var _generation = 0;

  bool _persistenceFailed = false;

  Map<String, dynamic>? get profile => _validAccess == null ? null : _profile;
  bool get persistenceFailed => _persistenceFailed;
  bool get configured {
    final uri = _base;
    return !kIsWeb &&
        uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }

  String get _vaultKey => 'Session ${_base!}';
  bool get isAdmin => profile?['role'] == 'admin';
  bool get canReadDirectory => isAdmin || profile?['role'] == 'support';

  String? get _validAccess {
    if (_accessExpiry?.isAfter(DateTime.now()) != true) return null;
    return _token;
  }

  ({String operator, String token, String managementUrl})
      get connectionCredentials {
    final token = _validAccess;
    final operator = _profile?['username'];
    if (!configured || token == null || operator is! String) {
      throw StateError('Corporate sign-in required');
    }
    return (operator: operator, token: token, managementUrl: _base.toString());
  }

  Future<void> restore() async {
    if (!configured ||
        !_vault.canPersist ||
        signingIn ||
        _refreshToken != null) {
      return;
    }
    try {
      _refreshToken = _vault.read(_vaultKey);
    } on FormatException {
      _vault.delete(_vaultKey);
      return;
    }
    if (_refreshToken == null) return;
    signingIn = true;
    _startRevalidation();
    notifyListeners();
    try {
      await _renew();
    } finally {
      signingIn = false;
      notifyListeners();
    }
  }

  Future<void> signIn(String username, String password, String code) async {
    if (!configured || signingIn || _validAccess != null) return;
    signingIn = true;
    notifyListeners();
    try {
      if (_refreshToken != null) await signOut();
      final credentials = <String, dynamic>{
        'username': username.trim().toLowerCase(),
        'password': password,
        if (code.isNotEmpty) 'code': code.trim(),
      };
      Map<String, dynamic> result;
      try {
        result = await _request('/v2/auth/session',
            method: 'POST', body: credentials) as Map<String, dynamic>;
      } on CorporateApiError catch (error) {
        if (error.statusCode != 404) rethrow;
        result =
            await _request('/v2/auth/login', method: 'POST', body: credentials)
                as Map<String, dynamic>;
      }
      _refreshToken = result['refresh_token'] as String?;
      final refresh = _refreshToken;
      _applySession(result);
      if (refresh != null && _vault.canPersist) {
        _persistenceFailed = !_vault.write(_vaultKey, refresh);
      }
      _startRevalidation();
    } catch (_) {
      _clear();
      rethrow;
    } finally {
      signingIn = false;
      notifyListeners();
    }
  }

  DateTime _deadline(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

  void _applySession(Map<String, dynamic> result) {
    final profile = result['profile'] as Map<String, dynamic>;
    _token = result['token'] as String;
    _setProfile(profile);
  }

  void _setProfile(Map<String, dynamic> profile) {
    final accessExpiry = _deadline(profile['expires_at'] as int);
    final sessionExpiry = _deadline(
        (profile['session_expires_at'] ?? profile['expires_at']) as int);
    final now = DateTime.now();
    if (!accessExpiry.isAfter(now) || !sessionExpiry.isAfter(now)) {
      throw StateError('Session expired');
    }
    _accessExpiry = accessExpiry;
    _sessionExpiry = sessionExpiry;
    _expiry?.cancel();
    _expiry = Timer(accessExpiry.difference(now), () {
      if (_sessionExpiry?.isAfter(DateTime.now()) != true ||
          _refreshToken == null) {
        _endSession();
      } else {
        _hideProfile();
        unawaited(_renew());
      }
    });
    if (!mapEquals(_profile, profile)) {
      _profile = Map.unmodifiable(profile);
      notifyListeners();
    }
  }

  void _startRevalidation() {
    _revalidate?.cancel();
    _revalidate = Timer.periodic(const Duration(seconds: 25), (_) {
      unawaited(_checkSession());
    });
  }

  bool get _needsRenewal =>
      _accessExpiry?.isAfter(DateTime.now().add(const Duration(minutes: 1))) !=
      true;

  Future<void> _checkSession() async {
    if (_sessionExpiry?.isAfter(DateTime.now()) == false) {
      _endSession();
      return;
    }
    final token = _validAccess;
    if (_refreshToken != null && _needsRenewal) {
      await _renew();
    } else if (token != null) {
      final generation = _generation;
      try {
        final profile = await _request('/v2/auth/me', bearer: token)
            as Map<String, dynamic>;
        if (generation == _generation && token == _token) _setProfile(profile);
      } on CorporateApiError catch (error) {
        if (error.statusCode != 401 ||
            generation != _generation ||
            token != _token) return;
        if (_refreshToken == null) {
          _endSession();
        } else {
          _hideProfile();
          await _renew();
        }
      } catch (_) {
        // Existing authorization expires on its own during a network outage.
      }
    }
  }

  Future<void> _renew() {
    final token = _refreshToken;
    if (token == null) return Future.value();
    return _refreshFlight ??= _refreshAccess(token, _generation);
  }

  Future<void> _refreshAccess(String token, int generation) async {
    try {
      final result =
          await _request('/v2/auth/refresh', method: 'POST', bearer: token)
              as Map<String, dynamic>;
      if (generation == _generation) _applySession(result);
    } on CorporateApiError catch (error) {
      if ((error.statusCode == 401 || error.statusCode == 404) &&
          generation == _generation) _endSession();
    } catch (_) {
      // A temporarily unreachable API must not erase the saved refresh token.
    } finally {
      if (generation == _generation) _refreshFlight = null;
    }
  }

  void _hideProfile() {
    _token = null;
    _accessExpiry = null;
    if (_profile == null) return;
    _profile = null;
    notifyListeners();
  }

  void _clear() {
    _generation++;
    _refreshToken = null;
    _persistenceFailed = false;
    _sessionExpiry = null;
    _refreshFlight = null;
    _expiry?.cancel();
    _revalidate?.cancel();
    _hideProfile();
  }

  void _endSession() {
    if (_refreshToken != null && _vault.canPersist) _vault.delete(_vaultKey);
    _clear();
  }

  Future<void> signOut() async {
    final refresh = _refreshToken;
    final token = refresh ?? _token;
    _clear();
    final cleared =
        refresh == null || !_vault.canPersist || _vault.delete(_vaultKey);
    if (token != null) {
      await _request('/v2/auth/logout', method: 'POST', bearer: token);
    }
    if (!cleared) throw StateError('Could not clear stored session');
  }

  @override
  void dispose() {
    _generation++;
    _expiry?.cancel();
    _revalidate?.cancel();
    super.dispose();
  }

  Future<dynamic> api(String path,
      {Map<String, String>? query,
      String method = 'GET',
      Map<String, dynamic>? body}) async {
    final generation = _generation;
    if (_refreshToken != null && _needsRenewal) await _renew();
    final token = _validAccess;
    if (token == null || generation != _generation) {
      throw StateError('Corporate sign-in required');
    }
    final result = await _request(path,
        bearer: token, query: query, method: method, body: body);
    if (generation != _generation) throw StateError('Corporate session ended');
    return result;
  }

  Future<dynamic> _request(String path,
      {String? bearer,
      Map<String, String>? query,
      String method = 'GET',
      Map<String, dynamic>? body}) async {
    final base = _base!;
    final prefix = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final uri = base.replace(path: '$prefix$path', queryParameters: query);
    return _transport(uri, method, bearer, body);
  }

  static Future<dynamic> _sendRequest(Uri uri, String method, String? bearer,
      Map<String, dynamic>? body) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.openUrl(method, uri);
      request.followRedirects = false;
      if (bearer != null)
        request.headers.set('Authorization', 'Bearer $bearer');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CorporateApiError(response.statusCode);
      }
      final result = BytesBuilder();
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        if (result.length + chunk.length > 2 * 1024 * 1024) {
          throw StateError('Corporate response too large');
        }
        result.add(chunk);
      }
      return jsonDecode(utf8.decode(result.takeBytes()));
    } finally {
      client.close(force: true);
    }
  }
}

class CorporateApiError implements Exception {
  const CorporateApiError(this.statusCode);
  final int statusCode;
}
