// Current weather from Open-Meteo (free, no key). The one thing the app
// fetches from the internet — the devices are all local. No Flutter imports,
// so it runs under plain `dart` on the Mac too.

import 'dart:convert';
import 'dart:io';

/// What it's doing outside: raining or not (the sky and the clock's colour
/// follow that), plus the WMO weather code and day / night for the icon.
class Weather {
  const Weather({
    required this.raining,
    required this.temp,
    required this.low,
    required this.high,
    this.code = 0,
    this.isDay = true,
  });
  final bool raining;

  /// WMO weather code (Open-Meteo's `weather_code`).
  final int code;

  /// Whether the sun is up there (Open-Meteo's `is_day`, sunrise to sunset).
  final bool isDay;

  /// The Meteocons icon for it (`assets/weather/<name>.svg`).
  String get icon => weatherIcon(code, isDay, raining: raining);

  /// Now, and today's low and high — °C, rounded.
  final int temp;
  final int low;
  final int high;
}

/// A WMO weather code as a Meteocons icon name: clear, partly cloudy,
/// overcast, fog, drizzle, rain, showers, thunderstorms or snow, with day
/// and night versions where they differ. [raining] (rain measured under a
/// dry code) shows rain.
String weatherIcon(int code, bool day, {bool raining = false}) {
  final dn = day ? 'day' : 'night';
  if (code >= 95) return 'thunderstorms-rain';
  if (code >= 85 || (code >= 71 && code <= 77)) return 'snow';
  if (code >= 80) return 'partly-cloudy-$dn-rain'; // showers
  if (code >= 61) return 'rain';
  if (code >= 51) return 'drizzle';
  if (raining) return 'rain';
  if (code >= 45) return 'fog-$dn';
  if (code == 3) return 'overcast';
  if (code == 2) return 'partly-cloudy-$dn';
  return 'clear-$dn'; // 0 clear, 1 mainly clear
}

/// Where to ask about: `WEATHER_AT="4.1755,73.5093"` (lat,lon), or null if
/// the build has none.
(double, double)? configuredPlace() {
  const spec = String.fromEnvironment('WEATHER_AT');
  final parts = spec.split(',');
  if (parts.length != 2) return null;
  final lat = double.tryParse(parts[0].trim());
  final lon = double.tryParse(parts[1].trim());
  return lat == null || lon == null ? null : (lat, lon);
}

Future<Weather> fetchWeather((double, double) place) async {
  final (lat, lon) = place;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(
      Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': '$lat',
        'longitude': '$lon',
        'current': 'temperature_2m,precipitation,weather_code,is_day',
        'daily': 'temperature_2m_min,temperature_2m_max',
        'forecast_days': '1',
        'timezone': 'auto',
      }),
    );
    final res = await req.close().timeout(const Duration(seconds: 10));
    final body = await res.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final current = json['current'] as Map<String, dynamic>;
    final daily = json['daily'] as Map<String, dynamic>;
    int today(String key) => ((daily[key] as List).first as num).round();
    final code = (current['weather_code'] as num).toInt();
    final rain = (current['precipitation'] as num?)?.toDouble() ?? 0;
    return Weather(
      // WMO codes 51 and up are drizzle, rain, showers and thunderstorms.
      raining: code >= 51 || rain > 0.1,
      temp: (current['temperature_2m'] as num).round(),
      low: today('temperature_2m_min'),
      high: today('temperature_2m_max'),
      code: code,
      isDay: (current['is_day'] as num?)?.toInt() != 0,
    );
  } finally {
    client.close(force: true);
  }
}
