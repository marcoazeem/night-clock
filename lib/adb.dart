// A minimal ADB-over-network client — just enough to run one shell command
// on an Android TV box: connect, authenticate with our own RSA key, open a
// `shell:` stream, read the output. No Flutter imports, so it runs under
// plain `dart` on the Mac too.
//
// The first time a new key connects, the box shows "Allow debugging?" on
// the TV; once the user accepts (with "Always allow"), later connections
// sign the box's challenge with the same key and go straight through.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'lights.dart' show LightException;

/// An RSA key pair for ADB, as hex so it can be stored as text.
class AdbKey {
  AdbKey(this.n, this.d);
  final BigInt n;
  final BigInt d;

  static final _e = BigInt.from(65537);

  /// A new 2048-bit key. Takes a few seconds on a phone — do it once and
  /// keep it ([toJson]).
  static AdbKey generate() {
    final seed = Random.secure();
    final rnd = FortunaRandom()
      ..seed(
        KeyParameter(
          Uint8List.fromList(List.generate(32, (_) => seed.nextInt(256))),
        ),
      );
    final gen = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(RSAKeyGeneratorParameters(_e, 2048, 64), rnd),
      );
    final pair = gen.generateKeyPair();
    final priv = pair.privateKey;
    return AdbKey(priv.modulus!, priv.privateExponent!);
  }

  String toJson() =>
      jsonEncode({'n': n.toRadixString(16), 'd': d.toRadixString(16)});

  static AdbKey fromJson(String s) {
    final m = jsonDecode(s) as Map<String, dynamic>;
    return AdbKey(
      BigInt.parse(m['n'] as String, radix: 16),
      BigInt.parse(m['d'] as String, radix: 16),
    );
  }

  /// PKCS#1 v1.5 signature of [token], treated as a SHA-1 digest (that's
  /// what adbd verifies).
  Uint8List sign(List<int> token) {
    const sha1Info = [
      0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, //
      0x05, 0x00, 0x04, 0x14,
    ];
    const k = 256;
    final t = [...sha1Info, ...token];
    final em = [0x00, 0x01, ...List.filled(k - t.length - 3, 0xFF), 0x00, ...t];
    final s = _toBig(em).modPow(d, n);
    return _fromBig(s, k);
  }

  /// The public key in adbd's own format (Android's RSAPublicKey struct,
  /// base64) followed by a name, as the box shows it in its prompt.
  Uint8List publicKey(String name) {
    const words = 64;
    final b = ByteData(4 + 4 + words * 4 + words * 4 + 4);
    final r32 = BigInt.one << 32;
    final n0 = (n % r32).toInt();
    // n0inv = -1 / n[0] mod 2^32.
    final n0inv = (r32 - BigInt.from(n0).modInverse(r32)).toInt();
    final rr = (BigInt.one << (2048 * 2)) % n;
    var o = 0;
    b.setUint32(o, words, Endian.little);
    o += 4;
    b.setUint32(o, n0inv, Endian.little);
    o += 4;
    for (var i = 0; i < words; i++, o += 4) {
      b.setUint32(o, ((n >> (32 * i)) % r32).toInt(), Endian.little);
    }
    for (var i = 0; i < words; i++, o += 4) {
      b.setUint32(o, ((rr >> (32 * i)) % r32).toInt(), Endian.little);
    }
    b.setUint32(o, 65537, Endian.little);
    return Uint8List.fromList([
      ...ascii.encode(base64.encode(b.buffer.asUint8List())),
      ...ascii.encode(' $name'),
      0,
    ]);
  }
}

BigInt _toBig(List<int> bytes) {
  var r = BigInt.zero;
  for (final x in bytes) {
    r = (r << 8) | BigInt.from(x);
  }
  return r;
}

Uint8List _fromBig(BigInt v, int length) {
  final out = Uint8List(length);
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xFF)).toInt();
    v >>= 8;
  }
  return out;
}

const _cnxn = 0x4e584e43;
const _auth = 0x48545541;
const _open = 0x4e45504f;
const _okay = 0x59414b4f;
const _clse = 0x45534c43;
const _wrte = 0x45545257;

/// Runs `shell:[command]` on the device at [host] and returns its output.
/// [name] labels the key in the box's "Allow debugging?" prompt. Throws
/// [LightException] if the box is unreachable or hasn't accepted the key
/// within [approval] (the prompt waits on the TV for the user).
Future<String> adbShell(
  String host,
  AdbKey key,
  String command, {
  int port = 5555,
  String name = 'nightclock@dashboard',
  Duration approval = const Duration(seconds: 3),
  void Function()? onOffered,
}) async {
  final Socket socket;
  try {
    socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 3),
    );
  } on Object catch (e) {
    throw LightException('$host: unreachable ($e)');
  }
  final messages = _Messages(socket);
  void send(int cmd, int a0, int a1, [List<int> data = const []]) {
    final h = ByteData(24)
      ..setUint32(0, cmd, Endian.little)
      ..setUint32(4, a0, Endian.little)
      ..setUint32(8, a1, Endian.little)
      ..setUint32(12, data.length, Endian.little)
      ..setUint32(16, data.fold<int>(0, (s, x) => s + x), Endian.little)
      ..setUint32(20, cmd ^ 0xFFFFFFFF, Endian.little);
    socket.add(h.buffer.asUint8List());
    if (data.isNotEmpty) socket.add(data);
  }

  try {
    // Version 0x01000000: below the one that asks for TLS.
    send(_cnxn, 0x01000000, 4096, ascii.encode('host::\x00'));
    var signed = false;
    var offered = false;
    while (true) {
      final m = await messages.next(
        offered ? approval : const Duration(seconds: 5),
      );
      if (m == null) {
        throw LightException(
          offered
              ? '$host: waiting for "Allow debugging?" on the TV'
              : '$host: no answer',
        );
      }
      if (m.cmd == _cnxn) break;
      if (m.cmd != _auth || m.a0 != 1) continue; // 1: TOKEN
      if (!signed) {
        signed = true;
        send(_auth, 2, 0, key.sign(m.data)); // 2: SIGNATURE
      } else if (!offered) {
        // Our key isn't trusted yet — offer it; the TV asks the user.
        offered = true;
        send(_auth, 3, 0, key.publicKey(name)); // 3: RSAPUBLICKEY
        onOffered?.call();
      }
    }

    const local = 1;
    send(_open, local, 0, utf8.encode('shell:$command\x00'));
    final out = BytesBuilder();
    while (true) {
      final m = await messages.next(const Duration(seconds: 8));
      if (m == null || m.cmd == _clse) break;
      if (m.cmd == _wrte) {
        out.add(m.data);
        send(_okay, local, m.a0);
      }
    }
    return utf8.decode(out.takeBytes(), allowMalformed: true);
  } finally {
    socket.destroy();
  }
}

class _Message {
  _Message(this.cmd, this.a0, this.a1, this.data);
  final int cmd, a0, a1;
  final Uint8List data;
}

/// Whole ADB messages off the socket — TCP may split or join them.
class _Messages {
  _Messages(Stream<List<int>> stream) : _chunks = StreamIterator(stream);
  final StreamIterator<List<int>> _chunks;
  final _buffer = BytesBuilder(copy: false);
  var _bytes = Uint8List(0);

  Future<_Message?> next(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (_bytes.length >= 24) {
        final h = ByteData.sublistView(_bytes, 0, 24);
        final len = h.getUint32(12, Endian.little);
        if (_bytes.length >= 24 + len) {
          final m = _Message(
            h.getUint32(0, Endian.little),
            h.getUint32(4, Endian.little),
            h.getUint32(8, Endian.little),
            Uint8List.fromList(_bytes.sublist(24, 24 + len)),
          );
          _bytes = Uint8List.fromList(_bytes.sublist(24 + len));
          return m;
        }
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      try {
        if (!await _chunks.moveNext().timeout(left)) return null;
      } on TimeoutException {
        return null;
      }
      _buffer
        ..add(_bytes)
        ..add(_chunks.current);
      _bytes = _buffer.takeBytes();
    }
  }
}
