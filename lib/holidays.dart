// The Maldives' public holidays, from Google's public "Holidays in
// Maldives" calendar (no key; it follows the moon-sighted Islamic dates) —
// the same source as the iPad's NCHolidays. No Flutter imports, so it runs
// under plain `dart` on the Mac too.

import 'dart:convert';
import 'dart:io';

const _icsUrl =
    'https://calendar.google.com/calendar/ical/'
    'en.mv%23holiday%40group.v.calendar.google.com/public/basic.ics';

/// How far ahead the face shows a holiday (the user asked, 10 Nov 2026).
const holidayDays = 15;

/// The calendar as "yyyyMMdd=Name" entries, sorted by date — the form
/// they're kept in (SharedPreferences 'holidays').
Future<List<String>> fetchHolidays() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.getUrl(Uri.parse(_icsUrl));
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    final ics = await res.transform(utf8.decoder).join();
    return parseHolidays(ics);
  } finally {
    client.close(force: true);
  }
}

List<String> parseHolidays(String ics) {
  // Unfold: a line starting with a space continues the one before.
  final lines = ics
      .replaceAll('\r\n', '\n')
      .replaceAll('\n ', '')
      .split('\n');
  final out = <String>[];
  String? date, name;
  for (final line in lines) {
    if (line.startsWith('BEGIN:VEVENT')) {
      date = name = null;
    } else if (line.startsWith('DTSTART')) {
      final v = line.split(':').last;
      if (v.length >= 8) date = v.substring(0, 8);
    } else if (line.startsWith('SUMMARY:')) {
      name = line
          .substring(8)
          .replaceAll(r'\,', ',')
          .replaceAll(r'\;', ';')
          .replaceAll(' (tentative)', '');
    } else if (line.startsWith('END:VEVENT') &&
        date != null &&
        (name ?? '').isNotEmpty) {
      out.add('$date=$name');
    }
  }
  return out..sort();
}

/// The next holiday within [holidayDays] of [now] as "REPUBLIC DAY  ·
/// TOMORROW" (or TODAY / IN 5 DAYS), null when there's none.
String? holidayLine(List<String> entries, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  String ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}'
      '${d.month.toString().padLeft(2, '0')}'
      '${d.day.toString().padLeft(2, '0')}';
  final key = ymd(today);
  for (final e in entries) {
    if (e.length < 10 || e.compareTo(key) < 0) continue;
    final y = int.tryParse(e.substring(0, 4)),
        m = int.tryParse(e.substring(4, 6)),
        d = int.tryParse(e.substring(6, 8));
    if (y == null || m == null || d == null) continue;
    // Calendar days (UTC dates dodge any daylight-saving hour).
    final n = DateTime.utc(y, m, d)
        .difference(DateTime.utc(today.year, today.month, today.day))
        .inDays;
    if (n > holidayDays) return null;
    final when = n == 0 ? 'today' : n == 1 ? 'tomorrow' : 'in $n days';
    return '${e.substring(9)}  ·  $when'.toUpperCase();
  }
  return null;
}
