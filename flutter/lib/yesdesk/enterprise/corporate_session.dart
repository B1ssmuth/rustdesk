import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

final corporateSession = CorporateSession();

class CorporateSession extends ChangeNotifier {
  static const _api = String.fromEnvironment('YESDESK_MANAGEMENT_URL');
  static const _authorize = String.fromEnvironment('YESDESK_OIDC_AUTHORIZE');
  static const _tokenEndpoint = String.fromEnvironment('YESDESK_OIDC_TOKEN');
  static const _clientId = String.fromEnvironment('YESDESK_OIDC_CLIENT_ID');
  static const _scope = String.fromEnvironment('YESDESK_OIDC_SCOPE',
      defaultValue: 'openid yesdesk.management');

  final _random = Random.secure();
  String? _accessToken;
  Timer? _revalidate;
  Timer? _expiry;
  bool _refreshing = false;
  Map<String, dynamic>? profile;
  bool signingIn = false;

  bool get configured =>
      !kIsWeb &&
      [_api, _authorize, _tokenEndpoint].every(_isHttps) &&
      _clientId.isNotEmpty;
  bool get isAdmin => profile?['role'] == 'admin';
  bool get canReadDirectory => isAdmin || profile?['role'] == 'support';

  static bool _isHttps(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment &&
        !uri.hasQuery;
  }

  String _secret() => base64Url
      .encode(List.generate(32, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  Future<void> signIn() async {
    if (!configured || signingIn) return;
    signOut();
    signingIn = true;
    notifyListeners();
    HttpServer? server;
    try {
      final state = _secret();
      final verifier = _secret();
      final challenge = base64Url
          .encode(sha256.convert(ascii.encode(verifier)).bytes)
          .replaceAll('=', '');
      final listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server = listener;
      final callback = Uri.parse('http://127.0.0.1:${listener.port}/callback');
      final result = Completer<String>();
      listener.listen((request) async {
        final query = request.uri.queryParametersAll;
        final valid = request.method == 'GET' &&
            request.uri.path == callback.path &&
            query['state']?.length == 1 &&
            query['state']!.single == state &&
            !result.isCompleted;
        final response = request.response;
        response.headers.set('Cache-Control', 'no-store');
        response.headers.contentType = ContentType.text;
        response.statusCode = valid ? 200 : 400;
        response.write(valid ? 'Return to YES Desk.' : 'Invalid callback.');
        if (valid) {
          if (query['code']?.length == 1 && query['code']!.single.isNotEmpty) {
            result.complete(query['code']!.single);
          } else {
            result.complete('');
          }
        }
        await response.close();
      });
      final opened = await launchUrl(
        Uri.parse(_authorize).replace(queryParameters: {
          'response_type': 'code',
          'client_id': _clientId,
          'scope': _scope,
          'redirect_uri': callback.toString(),
          'state': state,
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
        }),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) throw StateError('Could not open browser');
      final code = await result.future.timeout(const Duration(minutes: 3));
      if (code.isEmpty) throw StateError('Sign-in denied');
      final token = await _request(Uri.parse(_tokenEndpoint), form: {
        'grant_type': 'authorization_code',
        'client_id': _clientId,
        'code': code,
        'code_verifier': verifier,
        'redirect_uri': callback.toString(),
      }) as Map<String, dynamic>;
      final accessToken = token['access_token'];
      if (accessToken is! String ||
          (token['token_type'] as String?)?.toLowerCase() != 'bearer') {
        throw StateError('Missing access token');
      }
      _accessToken = accessToken;
      await refresh();
      _revalidate = Timer.periodic(const Duration(seconds: 30), (_) {
        unawaited(refresh().catchError((Object _) {}));
      });
    } catch (_) {
      signOut();
      rethrow;
    } finally {
      await server?.close(force: true);
      signingIn = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    final token = _accessToken;
    if (token == null || _refreshing) return;
    _refreshing = true;
    try {
      final current = await api('/v1/me') as Map<String, dynamic>;
      if (_accessToken != token) return;
      final validUntil = DateTime.fromMillisecondsSinceEpoch(
          (current['expires_at'] as int) * 1000);
      final remaining = validUntil.difference(DateTime.now());
      if (remaining <= Duration.zero) throw StateError('Session expired');
      _expiry?.cancel();
      _expiry = Timer(remaining, signOut);
      profile = current;
      notifyListeners();
    } catch (_) {
      if (_accessToken == token) signOut();
      rethrow;
    } finally {
      _refreshing = false;
    }
  }

  void signOut() {
    _accessToken = null;
    _revalidate?.cancel();
    _expiry?.cancel();
    profile = null;
    notifyListeners();
  }

  Future<dynamic> api(String path,
      {Map<String, String>? query, bool post = false}) async {
    final token = _accessToken;
    if (token == null) throw StateError('Corporate sign-in required');
    final base = Uri.parse(_api);
    final prefix = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return _request(base.replace(path: '$prefix$path', queryParameters: query),
        bearer: token, post: post);
  }

  Future<dynamic> _request(Uri uri,
      {String? bearer, Map<String, String>? form, bool post = false}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request =
          await client.openUrl(form != null || post ? 'POST' : 'GET', uri);
      request.followRedirects = false;
      if (bearer != null)
        request.headers.set('Authorization', 'Bearer $bearer');
      if (form != null) {
        request.headers.contentType =
            ContentType('application', 'x-www-form-urlencoded');
        request.write(form.entries
            .map((entry) => '${Uri.encodeQueryComponent(entry.key)}='
                '${Uri.encodeQueryComponent(entry.value)}')
            .join('&'));
      }
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode != 200)
        throw CorporateApiError(response.statusCode);
      final body = BytesBuilder();
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        if (body.length + chunk.length > 2 * 1024 * 1024) {
          throw StateError('Corporate response too large');
        }
        body.add(chunk);
      }
      return jsonDecode(utf8.decode(body.takeBytes()));
    } finally {
      client.close(force: true);
    }
  }
}

class CorporateApiError implements Exception {
  const CorporateApiError(this.statusCode);
  final int statusCode;
}
