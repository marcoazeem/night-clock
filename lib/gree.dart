// Local-network control for a Gree Wi-Fi air conditioner (the units the
// Gree+ app drives). Like lights.dart: no cloud, no Flutter imports, so it
// runs under plain `dart` on the Mac too.
//
// The protocol is JSON over UDP port 7000. A scan returns the unit's MAC; a
// bind, encrypted with a key every Gree unit shares, returns that unit's own
// key; status and commands then use the unit's key. Older firmware wraps
// everything in AES-ECB, newer firmware in AES-GCM — bind tries ECB first
// and remembers whichever answered. Nothing secret goes in lights.json: the
// key comes from the unit itself on first use.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'lights.dart' show LightException;

/// The setpoint range Gree units accept, in °C.
const acMinTemp = 16;
const acMaxTemp = 30;

/// What the unit last reported.
class AcState {
  const AcState({
    required this.on,
    required this.setTemp,
    required this.mode,
    this.roomTemp,
  });
  final bool on;
  final int setTemp;

  /// 0 auto, 1 cool, 2 dry, 3 fan, 4 heat.
  final int mode;

  /// The unit's own room-temperature sensor, when it has one.
  final int? roomTemp;

  AcState copyWith({bool? on, int? setTemp}) => AcState(
    on: on ?? this.on,
    setTemp: setTemp ?? this.setTemp,
    mode: mode,
    roomTemp: roomTemp,
  );
}

/// ACs from the build's dart-defines: `GREE_AC="Bedroom=192.168.1.40"`.
List<GreeAc> configuredAcs() {
  const spec = String.fromEnvironment('GREE_AC');
  return [
    for (final part in spec.split(','))
      if (part.contains('='))
        GreeAc(
          part.substring(0, part.indexOf('=')).trim(),
          part.substring(part.indexOf('=') + 1).trim(),
        ),
  ];
}

const _port = 7000;
final _genericEcbKey = utf8.encode('a3K8Bx%2r8Y7#xDh');
final _genericGcmKey = utf8.encode('{yxAHAY_Lm6pbC/<');
final _gcmNonce = Uint8List.fromList([
  0x54, 0x40, 0x78, 0x44, 0x49, 0x67, 0x5a, 0x51, //
  0x6c, 0x5e, 0x63, 0x13,
]);
final _gcmAad = utf8.encode('qualcomm-test');

class GreeAc {
  GreeAc(this.name, this.host);
  final String name;
  final String host;

  String? _mac;
  List<int>? _key;
  bool _gcm = false;

  Future<AcState> state() async {
    const cols = ['Pow', 'SetTem', 'Mod', 'TemSen'];
    final res = await _call({'cols': cols, 't': 'status'});
    final dat = (res['dat'] as List).cast<num>();
    final v = {for (var i = 0; i < cols.length; i++) cols[i]: dat[i].toInt()};
    // TemSen carries a +40 offset on most firmware; 0 means no sensor.
    final sensor = v['TemSen'] ?? 0;
    return AcState(
      on: v['Pow'] == 1,
      setTemp: v['SetTem']!,
      mode: v['Mod']!,
      roomTemp: sensor == 0 ? null : (sensor >= 40 ? sensor - 40 : sensor),
    );
  }

  Future<void> setPower(bool on) => _command({'Pow': on ? 1 : 0});

  /// Sets the target in °C (TemUn 0 is Celsius).
  Future<void> setTemp(int celsius) =>
      _command({'TemUn': 0, 'SetTem': celsius.clamp(acMinTemp, acMaxTemp)});

  Future<void> _command(Map<String, int> values) => _call({
    'opt': values.keys.toList(),
    'p': values.values.toList(),
    't': 'cmd',
  });

  /// One request with the unit's own key, binding first if needed. A unit
  /// that rebooted may have a new key, so a failure re-binds once.
  Future<Map<String, dynamic>> _call(Map<String, dynamic> pack) async {
    for (var attempt = 0; ; attempt++) {
      try {
        if (_key == null) await _bind();
        return await _exchange(pack, _key!, _gcm, i: 0);
      } catch (_) {
        _key = null;
        if (attempt >= 1) rethrow;
      }
    }
  }

  Future<void> _bind() async {
    _mac ??= await _scan();
    for (final gcm in [false, true]) {
      try {
        final res = await _exchange(
          {'t': 'bind', 'uid': 0},
          gcm ? _genericGcmKey : _genericEcbKey,
          gcm,
          i: 1,
        );
        if (res['t'] == 'bindok' && res['key'] is String) {
          _key = utf8.encode(res['key'] as String);
          _gcm = gcm;
          return;
        }
      } on LightException {
        // No answer in this dialect — try the other.
      }
    }
    throw LightException('$name: AC refused to bind');
  }

  /// The unit's MAC, which every later message is addressed to.
  Future<String> _scan() async {
    final reply = await _udp(utf8.encode('{"t":"scan"}'));
    final msg = jsonDecode(utf8.decode(reply)) as Map<String, dynamic>;
    final pack = _open(msg, _genericEcbKey, false);
    final mac = (pack['mac'] ?? pack['cid']) as String?;
    if (mac == null) throw LightException('$name: no MAC in scan reply');
    return mac;
  }

  Future<Map<String, dynamic>> _exchange(
    Map<String, dynamic> pack,
    List<int> key,
    bool gcm, {
    required int i,
  }) async {
    // Every pack names the unit it's for, bind included.
    final plain = utf8.encode(jsonEncode({...pack, 'mac': _mac}));
    final Map<String, dynamic> msg = {
      'cid': 'app',
      'i': i,
      't': 'pack',
      'uid': 0,
      'tcid': _mac,
    };
    if (gcm) {
      final sealed = _gcmCipher(true, key).process(Uint8List.fromList(plain));
      msg['pack'] = base64.encode(sealed.sublist(0, sealed.length - 16));
      msg['tag'] = base64.encode(sealed.sublist(sealed.length - 16));
    } else {
      msg['pack'] = base64.encode(_ecb(true, key, _pkcs7(plain)));
    }
    final reply = await _udp(utf8.encode(jsonEncode(msg)));
    return _open(
      jsonDecode(utf8.decode(reply)) as Map<String, dynamic>,
      key,
      gcm,
    );
  }

  Map<String, dynamic> _open(
    Map<String, dynamic> msg,
    List<int> key,
    bool gcm,
  ) {
    final data = base64.decode(msg['pack'] as String);
    final Uint8List plain;
    if (gcm) {
      plain = _gcmOpen(key, data);
    } else {
      plain = _ecb(false, key, data);
    }
    // Firmware pads inconsistently; the JSON ends at the last brace.
    final text = utf8.decode(plain, allowMalformed: true);
    final end = text.lastIndexOf('}');
    if (end < 0) throw LightException('$name: unreadable AC reply');
    return jsonDecode(text.substring(0, end + 1)) as Map<String, dynamic>;
  }

  /// Sends [data] and waits for one reply, resending since UDP drops.
  Future<Uint8List> _udp(List<int> data) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final reply = Completer<Uint8List>();
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d != null && !reply.isCompleted) reply.complete(d.data);
    });
    try {
      final address = InternetAddress(host);
      for (var attempt = 0; attempt < 3; attempt++) {
        socket.send(data, address, _port);
        try {
          return await reply.future.timeout(const Duration(milliseconds: 1200));
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

Uint8List _pkcs7(List<int> data) {
  final pad = 16 - data.length % 16;
  return Uint8List.fromList([...data, ...List.filled(pad, pad)]);
}

/// Raw AES-ECB over whole blocks; padding is handled by the callers.
Uint8List _ecb(bool encrypt, List<int> key, List<int> data) {
  final engine = AESEngine()
    ..init(encrypt, KeyParameter(Uint8List.fromList(key)));
  final input = Uint8List.fromList(data);
  final out = Uint8List(input.length);
  for (var off = 0; off + 16 <= input.length; off += 16) {
    engine.processBlock(input, off, out, off);
  }
  return out;
}

GCMBlockCipher _gcmCipher(bool encrypt, List<int> key) =>
    GCMBlockCipher(AESEngine())..init(
      encrypt,
      AEADParameters(
        KeyParameter(Uint8List.fromList(key)),
        128,
        _gcmNonce,
        Uint8List.fromList(_gcmAad),
      ),
    );

/// GCM decryption without checking the tag, the way greeclimate reads
/// replies — GCM's ciphertext is plain AES-CTR from counter 2, so a unit
/// with a quirky or missing tag still reads.
Uint8List _gcmOpen(List<int> key, List<int> data) {
  final ctr = CTRStreamCipher(AESEngine())
    ..init(
      false,
      ParametersWithIV(
        KeyParameter(Uint8List.fromList(key)),
        Uint8List.fromList([..._gcmNonce, 0, 0, 0, 2]),
      ),
    );
  return ctr.process(Uint8List.fromList(data));
}
