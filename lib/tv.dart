// Local-network power control for a Hisense VIDAA TV. Like lights.dart and
// gree.dart: no cloud, no Flutter imports, so it runs under plain `dart`.
//
// VIDAA's remote (the RemoteNOW app's) is an MQTT broker on the TV at port
// 36669, over TLS with a self-signed Hisense cert, logging in with a fixed
// user/password every RemoteNOW client uses. The TV pairs a client id once
// with a 4-digit code on screen; after that the power key is one PUBLISH.
// The broker only runs while the TV is on, so "can we connect" is the state,
// and waking it is Wake-on-LAN (the TV's "Wake on LAN/Wireless" setting).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'adb.dart';
import 'lights.dart' show LightException;

/// TVs from the build's dart-defines: `HISENSE_TV="TV=192.168.1.50/aabbccddeeff"`.
List<HisenseTv> configuredTvs() {
  const spec = String.fromEnvironment('HISENSE_TV');
  return [
    for (final part in spec.split(','))
      if (part.contains('=') && part.contains('/'))
        HisenseTv(
          part.substring(0, part.indexOf('=')).trim(),
          part.substring(part.indexOf('=') + 1, part.indexOf('/')).trim(),
          part.substring(part.indexOf('/') + 1).trim(),
        ),
  ];
}

const _port = 36669;

/// The client id the TV was paired with. Pairing is per id, so changing it
/// means pairing again (the TV shows a new code).
const tvClientId = 'nightclock';

class HisenseTv {
  HisenseTv(this.name, this.host, this.mac);
  final String name;
  final String host;

  /// 12 hex digits, for the Wake-on-LAN packet.
  final String mac;

  /// Whether the TV is on: its remote broker only listens while it is.
  Future<bool> isOn() async {
    try {
      final s = await Socket.connect(
        host,
        _port,
        timeout: const Duration(seconds: 2),
      );
      s.destroy();
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  Future<void> setPower(bool on) async {
    if (on) {
      await _wake();
    } else if (await isOn()) {
      await sendKey('KEY_POWER');
    }
  }

  /// One remote-control key press, e.g. `KEY_POWER`.
  Future<void> sendKey(String key) => _session((socket, _) async {
    socket.add(
      _publish('/remoteapp/tv/remote_service/$tvClientId/actions/sendkey', key),
    );
  });

  /// What's on screen — an input like "HDMI1", or an app's name — or null
  /// if the TV doesn't say. It answers `gettvstate` with a state broadcast.
  Future<String?> source() => _session((socket, packets) async {
    socket.add(_subscribe('/remoteapp/mobile/broadcast/ui_service/state'));
    socket.add(
      _publish('/remoteapp/tv/ui_service/$tvClientId/actions/gettvstate', ''),
    );
    await socket.flush();
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (true) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      final packet = await packets.next(left);
      if (packet == null) return null;
      final (type, flags, body) = packet;
      if (type != 3) continue; // Only PUBLISHes carry state.
      final topicLength = body[0] << 8 | body[1];
      final topic = utf8.decode(body.sublist(2, 2 + topicLength));
      if (!topic.endsWith('/ui_service/state')) continue;
      // QoS 1/2 put a packet id between the topic and the payload.
      final start = 2 + topicLength + ((flags & 0x06) != 0 ? 2 : 0);
      try {
        final state =
            jsonDecode(utf8.decode(body.sublist(start)))
                as Map<String, dynamic>;
        final label =
            state['displayname'] ?? state['name'] ?? state['sourcename'];
        return label is String && label.isNotEmpty ? label : null;
      } on FormatException {
        return null;
      }
    }
  });

  /// Connects and logs in, runs [body], then disconnects.
  Future<T> _session<T>(
    Future<T> Function(SecureSocket socket, _Packets packets) body,
  ) async {
    final SecureSocket socket;
    try {
      socket = await SecureSocket.connect(
        host,
        _port,
        timeout: const Duration(seconds: 3),
        onBadCertificate: (_) => true, // Hisense's own self-signed CA.
      );
    } on Object catch (e) {
      throw LightException('$name: TV unreachable ($e)');
    }
    try {
      final packets = _Packets(socket);
      socket.add(_connect(tvClientId, 'hisenseservice', 'multimqttservice'));
      await socket.flush();
      // CONNACK: type 2, body [flags, rc] — rc 0 is accepted.
      final ack = await packets.next(const Duration(seconds: 3));
      if (ack == null || ack.$1 != 2 || ack.$3.length < 2 || ack.$3[1] != 0) {
        throw LightException('$name: TV refused the login');
      }
      final result = await body(socket, packets);
      socket.add(const [0xE0, 0x00]); // DISCONNECT
      await socket.flush();
      return result;
    } finally {
      socket.destroy();
    }
  }

  Future<void> _wake() => wakeOnLan(name, host, mac);
}

/// The Wake-on-LAN magic packet — six 0xFF then the [mac] (12 hex digits)
/// sixteen times — broadcast on [host]'s subnet and sent to it directly.
Future<void> wakeOnLan(String name, String host, String mac) async {
  final bytes = [
    for (var i = 0; i + 2 <= mac.length; i += 2)
      int.parse(mac.substring(i, i + 2), radix: 16),
  ];
  if (bytes.length != 6) throw LightException('$name: bad MAC');
  final packet = [
    ...List.filled(6, 0xFF),
    for (var i = 0; i < 16; i++) ...bytes,
  ];
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  try {
    socket.broadcastEnabled = true;
    final subnet = host.substring(0, host.lastIndexOf('.'));
    for (final dst in ['$subnet.255', '255.255.255.255', host]) {
      for (final port in [9, 7]) {
        socket.send(packet, InternetAddress(dst), port);
      }
    }
  } finally {
    socket.close();
  }
}

/// Whole MQTT packets off the socket — TCP may split or join them.
class _Packets {
  _Packets(Stream<List<int>> stream) : _chunks = StreamIterator(stream);
  final StreamIterator<List<int>> _chunks;
  final _buffer = <int>[];

  /// The next packet as (type, flags, body), or null on timeout or close.
  Future<(int, int, List<int>)?> next(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final packet = _take();
      if (packet != null) return packet;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      try {
        if (!await _chunks.moveNext().timeout(left)) return null;
      } on TimeoutException {
        return null;
      }
      _buffer.addAll(_chunks.current);
    }
  }

  (int, int, List<int>)? _take() {
    if (_buffer.length < 2) return null;
    var length = 0, shift = 0, i = 1;
    while (true) {
      if (i >= _buffer.length) return null;
      final byte = _buffer[i++];
      length |= (byte & 0x7F) << shift;
      shift += 7;
      if (byte & 0x80 == 0) break;
    }
    if (_buffer.length < i + length) return null;
    final header = _buffer[0];
    final body = _buffer.sublist(i, i + length);
    _buffer.removeRange(0, i + length);
    return (header >> 4, header & 0x0F, body);
  }
}

/// MQTT 3.1.1 CONNECT with a clean session and user/password.
List<int> _connect(String clientId, String user, String password) {
  final body = [
    ..._str('MQTT'),
    4, // protocol level 3.1.1
    0xC2, // username + password + clean session
    0x00, 60, // keepalive, s
    ..._str(clientId),
    ..._str(user),
    ..._str(password),
  ];
  return [0x10, ..._length(body.length), ...body];
}

/// MQTT SUBSCRIBE to one topic at QoS 0.
List<int> _subscribe(String topic) {
  final body = [0x00, 0x01, ..._str(topic), 0x00];
  return [0x82, ..._length(body.length), ...body];
}

/// MQTT PUBLISH at QoS 0.
List<int> _publish(String topic, String payload) {
  final body = [..._str(topic), ...utf8.encode(payload)];
  return [0x30, ..._length(body.length), ...body];
}

List<int> _str(String s) {
  final b = utf8.encode(s);
  return [b.length >> 8, b.length & 0xFF, ...b];
}

/// MQTT's variable-length "remaining length".
List<int> _length(int n) {
  final out = <int>[];
  do {
    var byte = n % 128;
    n ~/= 128;
    if (n > 0) byte |= 0x80;
    out.add(byte);
  } while (n > 0);
  return out;
}

/// Android TV boxes from the build's dart-defines:
/// `BEYOND_TV="Beyond TV=192.168.1.60"`, or `…=192.168.1.60/aabbccddeeff`
/// with the box's MAC to switch it on by Wake-on-LAN.
List<AndroidTvBox> configuredBoxes() {
  const spec = String.fromEnvironment('BEYOND_TV');
  return [
    for (final part in spec.split(','))
      if (part.contains('='))
        AndroidTvBox(
          part.substring(0, part.indexOf('=')).trim(),
          part.substring(part.indexOf('=') + 1).split('/').first.trim(),
          part.contains('/')
              ? part.substring(part.indexOf('/') + 1).trim()
              : null,
        ),
  ];
}

/// An Android TV set-top box (the user's Medianet "Beyond TV" box),
/// switched over network ADB: a sleep key event to turn it off, and
/// `dumpsys power` for the state. The box must have network debugging on
/// (port 5555) and accept [key] once in its "Allow debugging?" prompt.
///
/// Asleep, the box drops off the network entirely — so "unreachable" reads
/// as off, and switching it on needs Wake-on-LAN to its [mac] (if the box
/// supports it at all); without a MAC it can only be turned off from here.
class AndroidTvBox {
  AndroidTvBox(this.name, this.host, [this.mac]);
  final String name;
  final String host;
  final String? mac;

  bool get canWake => mac != null;

  /// True while the box's "Allow debugging?" prompt is waiting for the
  /// user, so the panel can say so at once rather than after the timeout.
  /// [onWaiting] hears when it changes.
  bool waiting = false;
  void Function()? onWaiting;

  void _setWaiting(bool value) {
    if (waiting == value) return;
    waiting = value;
    onWaiting?.call();
  }

  /// One command at a time — while the box's approval prompt is up, a
  /// second connection would raise a second prompt.
  Future<String>? _inFlight;

  Future<String> _shell(AdbKey key, String command) async {
    while (_inFlight != null) {
      try {
        await _inFlight;
      } on Object {
        // The other caller handles its own failure.
      }
    }
    final run = adbShell(
      host,
      key,
      command,
      // Long enough to walk to the TV and accept the prompt.
      approval: const Duration(seconds: 60),
      onOffered: () => _setWaiting(true),
    );
    _inFlight = run;
    try {
      final out = await run;
      _setWaiting(false);
      return out;
    } on LightException catch (e) {
      // Gone from the network: no prompt is waiting any more. (A timed-out
      // prompt keeps saying so until the box lets us in.)
      if (e.message.contains('unreachable')) _setWaiting(false);
      rethrow;
    } finally {
      _inFlight = null;
    }
  }

  Future<bool> isOn(AdbKey key) async {
    try {
      return (await _shell(
        key,
        'dumpsys power | grep mWakefulness=',
      )).contains('Awake');
    } on LightException catch (e) {
      if (e.message.contains('unreachable')) return false; // asleep
      rethrow;
    }
  }

  /// Off: the sleep key. On: Wake-on-LAN when there's a MAC; otherwise the
  /// wake key — which works on TVs that keep their network up in standby
  /// (a TCL does), and throws for a box that dropped off the network.
  Future<void> setPower(AdbKey key, bool on) async {
    if (!on) {
      await _shell(key, 'input keyevent KEYCODE_SLEEP');
    } else if (mac != null) {
      await wakeOnLan(name, host, mac!);
    } else {
      await _shell(key, 'input keyevent KEYCODE_WAKEUP');
    }
  }

  /// One remote key, e.g. KEYCODE_VOLUME_UP.
  Future<void> sendKey(AdbKey key, String code) =>
      _shell(key, 'input keyevent $code');
}
