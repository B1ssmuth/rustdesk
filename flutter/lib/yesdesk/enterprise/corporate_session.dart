import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

final corporateSession = CorporateSession();

class CorporateSession extends ChangeNotifier {
  static const _api = String.fromEnvironment('YESDESK_MANAGEMENT_URL');

  String? _token;
  Timer? _revalidate;
  Timer? _expiry;
  Map<String, dynamic>? _profile;
  bool signingIn = false;
  var _generation = 0;

  Map<String, dynamic>? get profile => _profile;
  bool get configured {
    final uri = Uri.tryParse(_api);
    return !kIsWeb &&
        uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }

  bool get isAdmin => _profile?['role'] == 'admin';
  bool get canReadDirectory => isAdmin || _profile?['role'] == 'support';

  Future<void> signIn(String username, String password, String code) async {
    if (!configured || signingIn) return;
    signingIn = true;
    notifyListeners();
    try {
      final result = await _request('/v2/auth/login', method: 'POST', body: {
        'username': username.trim().toLowerCase(),
        'password': password,
        if (code.isNotEmpty) 'code': code.trim(),
      }) as Map<String, dynamic>;
      _token = result['token'] as String;
      _setProfile(result['profile'] as Map<String, dynamic>);
      _revalidate = Timer.periodic(const Duration(seconds: 25), (_) {
        unawaited(_refresh());
      });
    } catch (_) {
      _clear();
      rethrow;
    } finally {
      signingIn = false;
      notifyListeners();
    }
  }

  void _setProfile(Map<String, dynamic> profile) {
    final limit = DateTime.fromMillisecondsSinceEpoch(
        (profile['expires_at'] as int) * 1000);
    final remaining = limit.difference(DateTime.now());
    if (remaining <= Duration.zero) throw StateError('Session expired');
    _expiry?.cancel();
    _expiry = Timer(remaining, _clear);
    _profile = Map.unmodifiable(profile);
    notifyListeners();
  }

  Future<void> _refresh() async {
    final generation = _generation;
    try {
      final result = await api('/v2/auth/me') as Map<String, dynamic>;
      if (generation == _generation) _setProfile(result);
    } catch (_) {
      if (generation == _generation) _clear();
    }
  }

  void _clear() {
    _generation++;
    _token = null;
    _profile = null;
    _expiry?.cancel();
    _revalidate?.cancel();
    notifyListeners();
  }

  Future<void> signOut() async {
    final token = _token;
    _clear();
    if (token == null) return;
    await _request('/v2/auth/logout', method: 'POST', bearer: token);
  }

  Future<dynamic> api(String path,
      {Map<String, String>? query,
      String method = 'GET',
      Map<String, dynamic>? body}) async {
    final token = _token;
    if (token == null) throw StateError('Corporate sign-in required');
    return _request(path,
        bearer: token, query: query, method: method, body: body);
  }

  Future<dynamic> _request(String path,
      {String? bearer,
      Map<String, String>? query,
      String method = 'GET',
      Map<String, dynamic>? body}) async {
    final base = Uri.parse(_api);
    final prefix = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final uri = base.replace(path: '$prefix$path', queryParameters: query);
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
