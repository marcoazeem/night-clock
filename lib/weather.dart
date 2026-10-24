// Current weather from Open-Meteo (free, no key). The one thing the app
// fetches from the internet — the devices are all local. No Flutter imports,
// so it runs under plain `dart` on the Mac too.

import 'dart:convert';
import 'dart:io';

/// What it's doing outside. The user's climate has two kinds of weather, so
/// that's all this tells apart: raining or not.
class Weather {
  const Weather({
    required this.raining,
    required this.temp,
    required this.low,
    required this.high,
  });
  final bool raining;

  /// Now, and today's low and high — °C, rounded.
  final int temp;
  final int low;
  final int high;
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
        'current': 'temperature_2m,precipitation,weather_code',
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
    );
  } finally {
    client.close(force: true);
  }
}
