// Local-network control for the bedroom lights: TP-Link Tapo bulbs over
// KLAP (HTTP) and Xiaomi Mi/Mijia bulbs over miIO (UDP). No cloud, no
// Flutter imports — this file runs under plain `dart` too, which is how it
// gets tried against the real bulbs from the Mac.
//
// Config comes from `--dart-define-from-file=lights.json` (gitignored; see
// lights.example.json). The repo is public, so addresses and keys never live
// in source, and Tapo is given a hash of the account login, not the password.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

const _timeout = Duration(seconds: 3);
final _random = Random.secure();

class LightException implements Exception {
  LightException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What a bulb last reported. [brightness] is null when it can't dim, or
/// when it didn't say.
class LightState {
  const LightState(this.on, [this.brightness]);
  final bool on;
  final int? brightness;
}

abstract class Light {
  Light(this.name, {this.dimmable = false});
  final String name;

  /// Whether the dashboard offers 1% / 100% for this light. Both kinds of
  /// bulb can dim; this is which ones the user wants dimming on, named in
  /// DIMMABLE_LIGHTS.
  final bool dimmable;

  Future<LightState> state();
  Future<void> setPower(bool on);

  /// Sets [percent] and turns the light on with it.
  Future<void> setBrightness(int percent);
}

/// Lights from the build's dart-defines, in the order given. Empty when the
/// app was built without a lights.json, and the dashboard then hides.
List<Light> configuredLights() {
  const tapoHash = String.fromEnvironment('TAPO_HASH');
  const tapo = String.fromEnvironment('TAPO_LIGHTS');
  const mi = String.fromEnvironment('MI_LIGHTS');
  final dimmable = const String.fromEnvironment(
    'DIMMABLE_LIGHTS',
  ).split(',').map((n) => n.trim()).toSet();
  // A key that isn't the right length of hex is a config slip (an unpasted
  // placeholder, say) — skip that light rather than crash the clock.
  bool isHex(String s, int length) =>
      RegExp('^[0-9a-fA-F]{$length}\$').hasMatch(s);
  return [
    if (isHex(tapoHash, 64))
      for (final (name, value) in _entries(tapo))
        TapoLight(
          name,
          value,
          _hex(tapoHash),
          dimmable: dimmable.contains(name),
        ),
    for (final (name, value) in _entries(mi))
      if (isHex(value.split('/').last, 32))
        MiLight(
          name,
          value.split('/').first,
          _hex(value.split('/').last),
          dimmable: dimmable.contains(name),
        ),
  ];
}

/// "Bed=192.168.1.20, Desk=192.168.1.21" → (name, value) pairs.
Iterable<(String, String)> _entries(String spec) sync* {
  for (final part in spec.split(',')) {
    final i = part.indexOf('=');
    if (i <= 0) continue;
    yield (part.substring(0, i).trim(), part.substring(i + 1).trim());
  }
}

Uint8List _hex(String s) => Uint8List.fromList([
  for (var i = 0; i + 1 < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

Uint8List _bytes(List<List<int>> parts) =>
    Uint8List.fromList([for (final p in parts) ...p]);

Uint8List _randomBytes(int n) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) _random.nextInt(256)]);

/// AES-128-CBC with PKCS#7 padding — what both protocols wrap payloads in.
Uint8List _aes(bool encrypt, List<int> key, List<int> iv, List<int> data) {
  final cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))..init(
        encrypt,
        PaddedBlockCipherParameters(
          ParametersWithIV(
            KeyParameter(Uint8List.fromList(key)),
            Uint8List.fromList(iv),
          ),
          null,
        ),
      );
  return cipher.process(Uint8List.fromList(data));
}

// ---------------------------------------------------------------- Tapo (KLAP)

/// A Tapo bulb on current firmware, which speaks KLAP v2. [authHash] is
/// sha256(sha1(email) + sha1(password)) — tool/tapo_hash.py prints it.
class TapoLight extends Light {
  TapoLight(super.name, this.host, this.authHash, {super.dimmable});
  final String host;
  final Uint8List authHash;
  _KlapSession? _session;

  @override
  Future<LightState> state() async {
    final info = await _call('get_device_info');
    return LightState(info['device_on'] == true, info['brightness'] as int?);
  }

  @override
  Future<void> setPower(bool on) => _call('set_device_info', {'device_on': on});

  @override
  Future<void> setBrightness(int percent) => _call('set_device_info', {
    'device_on': true,
    'brightness': percent.clamp(1, 100),
  });

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    // A session lasts about a day and a bulb reboot drops it — on any
    // failure, handshake again once before giving up.
    for (var attempt = 0; ; attempt++) {
      try {
        _session ??= await _KlapSession.open(host, authHash);
        final res = await _session!.request({
          'method': method,
          'params': ?params,
          'requestTimeMils': DateTime.now().millisecondsSinceEpoch,
        });
        final code = res['error_code'];
        if (code != 0) throw LightException('$name: Tapo error $code');
        return (res['result'] as Map<String, dynamic>?) ?? const {};
      } catch (_) {
        _session = null;
        if (attempt >= 1) rethrow;
      }
    }
  }
}

class _KlapSession {
  _KlapSession(
    this.host,
    this.cookie,
    List<int> local,
    List<int> remote,
    List<int> auth,
  ) {
    List<int> derive(String label) =>
        sha256.convert(_bytes([utf8.encode(label), local, remote, auth])).bytes;
    key = derive('lsk').sublist(0, 16);
    final iv = derive('iv');
    ivBase = iv.sublist(0, 12);
    seq = ByteData.sublistView(Uint8List.fromList(iv.sublist(28))).getInt32(0);
    sig = derive('ldk').sublist(0, 28);
  }

  final String host;
  final String cookie;
  late final List<int> key, ivBase, sig;
  late int seq;

  static Future<_KlapSession> open(String host, Uint8List auth) async {
    final local = _randomBytes(16);
    final (body, cookie) = await _post(host, '/app/handshake1', local);
    if (body.length < 48 || cookie == null) {
      throw LightException('$host: unexpected Tapo handshake');
    }
    final remote = body.sublist(0, 16);
    final expected = sha256.convert(_bytes([local, remote, auth])).bytes;
    if (!_equal(expected, body.sublist(16, 48))) {
      throw LightException('$host: Tapo login rejected — check TAPO_HASH');
    }
    await _post(
      host,
      '/app/handshake2',
      sha256.convert(_bytes([remote, local, auth])).bytes,
      cookie: cookie,
    );
    return _KlapSession(host, cookie, local, remote, auth);
  }

  static bool _equal(List<int> a, List<int> b) =>
      a.length == b.length &&
      Iterable.generate(a.length).every((i) => a[i] == b[i]);

  Future<Map<String, dynamic>> request(Map<String, dynamic> body) async {
    seq = (seq + 1).toSigned(32);
    final seqBytes = (ByteData(4)..setInt32(0, seq)).buffer.asUint8List();
    final iv = _bytes([ivBase, seqBytes]);
    final cipher = _aes(true, key, iv, utf8.encode(jsonEncode(body)));
    final signature = sha256.convert(_bytes([sig, seqBytes, cipher])).bytes;
    final (res, _) = await _post(
      host,
      '/app/request?seq=$seq',
      _bytes([signature, cipher]),
      cookie: cookie,
    );
    if (res.length <= 32) throw LightException('$host: empty Tapo reply');
    final plain = _aes(false, key, iv, res.sublist(32));
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }

  /// One POST; returns the body and the TP_SESSIONID cookie, if one was set.
  static Future<(Uint8List, String?)> _post(
    String host,
    String path,
    List<int> body, {
    String? cookie,
  }) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.postUrl(Uri.parse('http://$host$path'));
      // The bulb's HTTP server wants a fixed Content-Length, not a chunked
      // body, and matches header names case-sensitively — dart:io's default
      // lowercase "content-length" gets a 400.
      void header(String name, Object value) =>
          req.headers.set(name, value, preserveHeaderCase: true);
      header('Content-Type', 'application/octet-stream');
      header('Content-Length', body.length);
      if (cookie != null) header('Cookie', cookie);
      req.add(body);
      final res = await req.close().timeout(_timeout);
      final data = await res
          .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
          .timeout(_timeout);
      if (res.statusCode != 200) {
        throw LightException('$host$path: HTTP ${res.statusCode}');
      }
      // Read the raw header: the bulb's "TP_SESSIONID=…;TIMEOUT=86400" isn't
      // a cookie dart:io parses reliably.
      final setCookie = res.headers[HttpHeaders.setCookieHeader]?.join(';');
      final id = setCookie == null
          ? null
          : RegExp(r'TP_SESSIONID=([^;]+)').firstMatch(setCookie)?.group(1);
      return (data.takeBytes(), id == null ? null : 'TP_SESSIONID=$id');
    } finally {
      client.close(force: true);
    }
  }
}

// ------------------------------------------------------------- Xiaomi (miIO)

/// A Mi/Mijia bulb. [token] is the device's 32-hex-digit token, pulled once
/// from the Xiaomi cloud with a token extractor. Newer bulbs speak MIoT
/// (`set_properties`, light service siid 2); older Yeelight-made ones the
/// legacy `set_power`/`set_bright` — which one is found on first use.
class MiLight extends Light {
  MiLight(super.name, this.host, this.token, {super.dimmable})
    : _key = md5.convert(token).bytes {
    _iv = md5.convert(_bytes([_key, token])).bytes;
  }

  final String host;
  final Uint8List token;
  final List<int> _key;
  late final List<int> _iv;
  int _id = 1 + _random.nextInt(9000);
  bool? _miot;

  @override
  Future<LightState> state() => _either(
    miot: () async {
      final r = await _properties('get_properties', [
        {'did': 'on', 'siid': 2, 'piid': 1},
        {'did': 'bright', 'siid': 2, 'piid': 2},
      ]);
      return LightState(r[0] == true, (r[1] as num?)?.toInt());
    },
    legacy: () async {
      final r = await _send('get_prop', ['power', 'bright']) as List;
      return LightState(r[0] == 'on', int.tryParse('${r[1]}'));
    },
  );

  @override
  Future<void> setPower(bool on) => _either(
    miot: () => _properties('set_properties', [
      {'did': 'on', 'siid': 2, 'piid': 1, 'value': on},
    ]),
    legacy: () => _send('set_power', [on ? 'on' : 'off']),
  );

  @override
  Future<void> setBrightness(int percent) {
    final p = percent.clamp(1, 100);
    return _either(
      miot: () => _properties('set_properties', [
        {'did': 'on', 'siid': 2, 'piid': 1, 'value': true},
        {'did': 'bright', 'siid': 2, 'piid': 2, 'value': p},
      ]),
      // Legacy bulbs refuse set_bright while off.
      legacy: () async {
        await _send('set_power', ['on']);
        await _send('set_bright', [p]);
      },
    );
  }

  /// Runs [miot], falling back to [legacy] if the bulb doesn't speak MIoT,
  /// and remembers which worked.
  Future<T> _either<T>({
    required Future<T> Function() miot,
    required Future<T> Function() legacy,
  }) async {
    if (_miot == false) return legacy();
    try {
      final r = await miot();
      _miot = true;
      return r;
    } on _MiError {
      if (_miot == true) rethrow;
      final r = await legacy();
      _miot = false;
      return r;
    }
  }

  /// A MIoT property call; returns each property's value, failing if any
  /// property reports a non-zero code.
  Future<List<Object?>> _properties(
    String method,
    List<Map<String, Object>> props,
  ) async {
    final r = await _send(method, props) as List;
    return [
      for (final p in r.cast<Map<String, dynamic>>())
        if (p['code'] != 0)
          throw _MiError('$name: property ${p['piid']} code ${p['code']}')
        else
          p['value'],
    ];
  }

  Future<Object?> _send(String method, List<Object> params) async {
    // The hello returns the device id and its clock, which every packet has
    // to carry — asking each time costs one round trip and survives reboots.
    final hello = await _exchange(
      Uint8List.fromList([0x21, 0x31, 0x00, 0x20, ...List.filled(28, 0xff)]),
    );
    final head = ByteData.sublistView(hello);
    final deviceId = head.getUint32(8);
    final stamp = head.getUint32(12);

    _id = _id >= 9999 ? 1 : _id + 1;
    final payload = _aes(
      true,
      _key,
      _iv,
      utf8.encode(jsonEncode({'id': _id, 'method': method, 'params': params})),
    );
    final header = ByteData(32)
      ..setUint16(0, 0x2131)
      ..setUint16(2, 32 + payload.length)
      ..setUint32(4, 0)
      ..setUint32(8, deviceId)
      ..setUint32(12, stamp + 1);
    final packet = header.buffer.asUint8List();
    packet.setRange(
      16,
      32,
      md5.convert(_bytes([packet.sublist(0, 16), token, payload])).bytes,
    );

    final reply = await _exchange(_bytes([packet, payload]));
    if (reply.length <= 32) throw LightException('$name: empty Mi reply');
    final text = utf8
        .decode(_aes(false, _key, _iv, reply.sublist(32)))
        .replaceAll('\u0000', '');
    final res = jsonDecode(text) as Map<String, dynamic>;
    if (res['error'] != null) throw _MiError('$name: ${res['error']}');
    return res['result'];
  }

  /// Sends [packet] to the bulb and waits for one reply. UDP drops packets,
  /// so it's resent a couple of times before giving up.
  Future<Uint8List> _exchange(Uint8List packet) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final reply = Completer<Uint8List>();
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d != null && !reply.isCompleted) reply.complete(d.data);
    });
    try {
      final address = InternetAddress(host);
      for (var i = 0; i < 3; i++) {
        socket.send(packet, address, 54321);
        try {
          return await reply.future.timeout(const Duration(seconds: 1));
        } on TimeoutException {
          // Resend.
        }
      }
      throw LightException('$name: no reply from $host');
    } finally {
      socket.close();
    }
  }
}

/// The bulb answered but refused the call — the cue to try the other dialect.
class _MiError extends LightException {
  _MiError(super.message);
}

// ---------------------------------------------------------------- Sonoff

/// A Sonoff wall switch driving a fan or a light (SONOFF_SWITCHES). The
/// switches aren't installed yet, so this is a placeholder: the dashboard
/// shows a button for each, marked "Not set up". When they arrive, give
/// each entry its address (`Name=IP`) and fill in [isOn] / [setPower]
/// (eWeLink LAN mode, or DIY mode's HTTP API on port 8081).
class SonoffSwitch {
  SonoffSwitch(this.name, this.host);
  final String name;

  /// The switch's IP, once it has one.
  final String? host;

  /// "Fan 1", "Kitchen Fan" — anything with "fan" in its name.
  bool get isFan => name.toLowerCase().contains('fan');

  /// False until the protocol is written.
  bool get isSetUp => false;

  Future<bool> isOn() async => throw LightException('Not set up yet');
  Future<void> setPower(bool on) async =>
      throw LightException('Not set up yet');
}

/// "Fan 1, Ceiling 1, Hanging Light=192.168.1.70" — names, each with an
/// optional address.
List<SonoffSwitch> configuredSwitches() => [
  for (final part in const String.fromEnvironment(
    'SONOFF_SWITCHES',
  ).split(','))
    if (part.split('=').first.trim().isNotEmpty)
      SonoffSwitch(
        part.split('=').first.trim(),
        part.contains('=') && part.split('=')[1].trim().isNotEmpty
            ? part.split('=')[1].trim()
            : null,
      ),
];
