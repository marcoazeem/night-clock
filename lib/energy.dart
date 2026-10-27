// An estimate of the house's electricity use and bill (Oct 2026), shown on
// the home page. Nothing here is measured: the devices only report what's
// on, so each gets a typical draw (an AC by its size and how hard it's
// working), and everything the dashboard can't see — fridge, water heater,
// pumps, other lights — is a fixed baseline. The past bills (BILLS in
// lights.json, gitignored: they're the user's real meter) give the
// history and the pace for the part of a billing period not yet tracked.
//
// No Flutter imports, so it runs under plain `dart` (the tariff is checked
// against the real bills that way).

import 'dart:convert';
import 'dart:math';

import 'gree.dart';

// ── Tariff (STELCO domestic) ─────────────────────────────────────────────

/// The bands per 30 days: 100 units each, then the rest. A longer or
/// shorter period stretches every band by days / 30.
const _bands = [1.25, 1.50, 1.50, 1.50, 2.66, 3.20];
const _topRate = 3.83;

/// Fuel discount per unit, and WAMCO's flat waste charge per bill.
const fuelDiscount = 0.12;
const wamco = 150.0;

/// What a bill for [kwh] over [days] comes to, in MVR — as STELCO works it.
double billMvr(double kwh, int days) {
  final width = 100 * days / 30;
  var left = kwh, total = 0.0;
  for (final rate in _bands) {
    final q = min(left, width);
    total += q * rate;
    left -= q;
  }
  total += max(0, left) * _topRate;
  return total - fuelDiscount * kwh + wamco;
}

// ── Config ───────────────────────────────────────────────────────────────

/// A past bill: the reading date, the units and the days it covered.
class Bill {
  const Bill(this.date, this.kwh, this.days);
  final DateTime date;
  final int kwh;
  final int days;
  double get perDay => kwh / days;
}

/// BILLS: "2025-06-03=914/30, 2025-06-29=851/30, …", oldest first.
List<Bill> configuredBills() {
  final bills = <Bill>[];
  for (final part in const String.fromEnvironment('BILLS').split(',')) {
    final m = RegExp(
      r'^\s*(\d{4}-\d\d-\d\d)\s*=\s*(\d+)\s*/\s*(\d+)\s*$',
    ).firstMatch(part);
    if (m == null) continue;
    bills.add(Bill(DateTime.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)));
  }
  return bills..sort((a, b) => a.date.compareTo(b.date));
}

/// AC_BTU: "Bedroom=12000, AC 2=24000" — 12000 if not given.
Map<String, int> configuredAcBtu() => {
  for (final part in const String.fromEnvironment('AC_BTU').split(','))
    if (part.contains('='))
      part.split('=')[0].trim().toLowerCase():
          int.tryParse(part.split('=')[1].trim()) ?? 12000,
};

/// The day of the month a billing period starts (BILL_DAY, default 20 —
/// the user's bills mostly come around the 20th).
int configuredBillDay() =>
    int.tryParse(const String.fromEnvironment('BILL_DAY')) ?? 20;

/// Everything the dashboard can't see, as a steady draw (ENERGY_BASELINE_W,
/// default 400 W ≈ 9.6 kWh a day: fridge, water heater, pumps, the rest).
double configuredBaseline() =>
    double.tryParse(const String.fromEnvironment('ENERGY_BASELINE_W')) ?? 400;

// ── Draw ─────────────────────────────────────────────────────────────────

/// A typical draw while cooling hard: about 1.1 kW per 12,000 BTU (an
/// inverter split's rated input).
double acWatts(int btu, AcState s) {
  if (!s.on) return 0;
  if (s.mode == 3) return 45; // fan only
  final rated = btu / 12000 * 1100;
  // An inverter works harder the further the room is from the setpoint:
  // ~45% holding it, up to full power 5° off.
  final room = s.roomTemp;
  final off = room == null
      ? 2
      : (s.mode == 4 ? s.setTemp - room : room - s.setTemp);
  return rated * (0.45 + 0.11 * off).clamp(0.3, 1.0);
}

/// A 9 W LED bulb at [level] percent (it never goes below ~1.5 W lit).
double lightWatts(bool on, int? level) =>
    on ? max(1.5, 9 * (level ?? 100) / 100) : 0;

const tvWatts = 100.0;
const boxWatts = 12.0;

/// The draw right now, by kind.
class Draw {
  const Draw({
    this.acs = 0,
    this.lights = 0,
    this.screens = 0,
    required this.other,
  });
  final double acs, lights, screens, other;
  double get total => acs + lights + screens + other;
}

// ── The running count ────────────────────────────────────────────────────

/// Accumulates kWh from successive [Draw]s, per day and per billing
/// period, and projects the bill. Its state round-trips through [toJson]
/// so it survives restarts.
class EnergyMeter {
  EnergyMeter({required this.bills, required this.billDay});

  final List<Bill> bills;
  final int billDay;

  DateTime? _periodStart, _lastAt;
  String _dayKey = '';
  double periodKwh = 0, dayKwh = 0, _lastWatts = 0;

  /// Whether the start of this period (before tracking began) was filled
  /// in from the bills' pace rather than tracked.
  bool seeded = false;

  void load(String? json) {
    if (json == null) return;
    try {
      final j = jsonDecode(json) as Map<String, dynamic>;
      _periodStart = DateTime.fromMillisecondsSinceEpoch(
        j['periodStart'] as int,
      );
      _lastAt = DateTime.fromMillisecondsSinceEpoch(j['lastAt'] as int);
      _dayKey = j['dayKey'] as String;
      periodKwh = (j['periodKwh'] as num).toDouble();
      dayKwh = (j['dayKwh'] as num).toDouble();
      _lastWatts = (j['lastWatts'] as num).toDouble();
      seeded = j['seeded'] == true;
    } catch (_) {
      // A bad save: start over.
    }
  }

  String toJson() => jsonEncode({
    'periodStart': _periodStart?.millisecondsSinceEpoch,
    'lastAt': _lastAt?.millisecondsSinceEpoch,
    'dayKey': _dayKey,
    'periodKwh': periodKwh,
    'dayKwh': dayKwh,
    'lastWatts': _lastWatts,
    'seeded': seeded,
  });

  /// The period [now] is in: from the latest bill day on or before it.
  (DateTime, DateTime) periodOf(DateTime now) {
    var start = DateTime(now.year, now.month, billDay);
    if (start.isAfter(now)) start = DateTime(now.year, now.month - 1, billDay);
    return (start, DateTime(start.year, start.month + 1, billDay));
  }

  static String _key(DateTime t) => '${t.year}-${t.month}-${t.day}';

  /// The bills' pace for this time of year: kWh a day in the bill(s) that
  /// covered the same dates a year earlier, else the average of them all.
  double historicalPerDay(DateTime at) {
    if (bills.isEmpty) return 28;
    final lastYear = DateTime(at.year - 1, at.month, at.day);
    for (final b in bills) {
      final from = b.date.subtract(Duration(days: b.days));
      if (!lastYear.isBefore(from) && !lastYear.isAfter(b.date)) {
        return b.perDay;
      }
    }
    return bills.map((b) => b.kwh).reduce((a, b) => a + b) /
        bills.map((b) => b.days).reduce((a, b) => a + b);
  }

  /// Adds the energy since the last reading and remembers [draw].
  void add(DateTime now, Draw draw) {
    final (start, _) = periodOf(now);
    if (_periodStart == null || _periodStart != start) {
      // A new period (or the first run): what came before tracking started
      // is filled in at the bills' pace.
      final first = _periodStart == null;
      _periodStart = start;
      periodKwh = 0;
      seeded = false;
      if (first) {
        final hours = now.difference(start).inMinutes / 60;
        periodKwh = hours / 24 * historicalPerDay(now);
        seeded = hours > 1;
      }
    }
    final last = _lastAt;
    if (last != null && now.isAfter(last)) {
      // A gap (app closed, phone off): the last draw for up to two hours,
      // then just the baseline, as the ACs may well have been switched off.
      final secs = now.difference(last).inSeconds.toDouble();
      final atLast = min(secs, 7200.0);
      final kwh = (_lastWatts * atLast + draw.other * (secs - atLast)) / 3.6e6;
      periodKwh += kwh;
      dayKwh += kwh;
    }
    final day = _key(now);
    if (day != _dayKey) {
      _dayKey = day;
      dayKwh = 0;
    }
    _lastAt = now;
    _lastWatts = draw.total;
  }

  DateTime? get periodStart => _periodStart;

  /// The period's units at the end, at the pace so far blended with the
  /// bills' (all bills' pace on day one, the tracked pace from a week in).
  double projectedKwh(DateTime now) {
    final (start, end) = periodOf(now);
    final days = end.difference(start).inHours / 24;
    final elapsed = max(0.25, now.difference(start).inMinutes / 1440);
    final tracked = periodKwh / elapsed;
    final w = min(1.0, elapsed / 7);
    final pace = w * tracked + (1 - w) * historicalPerDay(now);
    return periodKwh + max(0, days - elapsed) * pace;
  }

  int periodDays(DateTime now) {
    final (start, end) = periodOf(now);
    return end.difference(start).inDays;
  }
}
