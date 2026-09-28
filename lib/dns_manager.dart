import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DnsCandidate {
  final String ip;
  final String source;
  final String category;
  final bool gamingTagged;

  const DnsCandidate({
    required this.ip,
    required this.source,
    required this.category,
    this.gamingTagged = false,
  });
}

class GeoInfo {
  final String country;
  final String countryCode;
  final String city;
  final String org;

  const GeoInfo({
    this.country = 'Unknown',
    this.countryCode = '',
    this.city = '',
    this.org = '',
  });

  Map<String, dynamic> toJson() => {
        'country': country,
        'countryCode': countryCode,
        'city': city,
        'org': org,
      };

  factory GeoInfo.fromJson(Map<String, dynamic> json) => GeoInfo(
        country: json['country']?.toString() ?? 'Unknown',
        countryCode: json['countryCode']?.toString() ?? '',
        city: json['city']?.toString() ?? '',
        org: json['org']?.toString() ?? '',
      );
}

class HuntResult {
  final int newCount;
  final int totalCount;
  final int sourceSuccesses;
  final int githubRepositories;

  const HuntResult({
    required this.newCount,
    required this.totalCount,
    required this.sourceSuccesses,
    required this.githubRepositories,
  });
}

class DnsManager {
  static const _sourcesKey = 'dns_sources';
  static const _masterPoolKey = 'master_dns_pool';
  static const _displayListKey = 'display_dns_list';
  static const _geoCacheKey = 'dns_geo_cache';
  static const _githubCacheKey = 'github_hunt_cache';
  static const _metadataKey = 'dns_metadata';

  /// These are community-labelled gaming/public DNS examples. They are not
  /// guaranteed to improve in-game ping; the app still measures resolver RTT.
  final List<String> premiumGamingDns = const [
    '94.103.125.157',
    '94.103.125.158',
    '78.157.42.100',
    '78.157.42.101',
    '1.1.1.1',
    '1.0.0.1',
    '8.8.8.8',
    '8.8.4.4',
    '9.9.9.9',
    '149.112.112.112',
  ];

  /// Public sources used by the Hunt button. This is intentionally a finite,
  /// transparent list: no app can literally crawl the entire Internet.
  static const List<String> defaultSources = [
    'https://raw.githubusercontent.com/pingproxies/public-dns-directory/main/resolvers/global/trusted.txt',
    'https://raw.githubusercontent.com/pingproxies/public-dns-directory/main/resolvers/global/all.txt',
    'https://public-dns.info/nameservers.txt',
    'https://gist.githubusercontent.com/farbod-s/9f543fb71286b75b95248ade18caea4e/raw/dns.md',
    'https://raw.githubusercontent.com/AsTheySayMehrab/Luna-Dns/main/README.md',
  ];

  /// The GitHub Actions workflow injects this URL at build time.
  /// The app therefore reads one generated database instead of repeatedly
  /// calling the GitHub Search API from every device.
  static const String remoteDatabaseUrl =
      String.fromEnvironment('DNS_DATABASE_URL', defaultValue: '');

  static const List<String> githubQueries = [
    'gaming dns',
    'cod mobile dns',
    'pubg mobile dns',
    'mobile legends dns',
  ];

  static const List<String> gamingKeywords = [
    'gaming',
    'game',
    'cod',
    'call of duty',
    'pubg',
    'mobile legends',
    'radar',
    'shelter',
    'electro',
    'luna-dns',
  ];

  bool isValidIp(String ip) {
    final value = ip.trim();
    final address = InternetAddress.tryParse(value);
    if (address == null || address.type != InternetAddressType.IPv4) return false;

    final octets = value.split('.').map(int.tryParse).toList();
    if (octets.length != 4 || octets.any((e) => e == null || e < 0 || e > 255)) {
      return false;
    }

    final a = octets[0]!;
    final b = octets[1]!;
    final isPrivate = a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        a == 127 ||
        (a == 169 && b == 254) ||
        a == 0;
    return !isPrivate;
  }

  Future<void> saveSources(List<String> sources) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_sourcesKey, sources.toSet().toList());
  }

  Future<List<String>> loadSources() async {
    final prefs = await SharedPreferences.getInstance();
    final sources = prefs.getStringList(_sourcesKey);
    return sources == null || sources.isEmpty ? defaultSources : sources;
  }

  Future<void> saveMasterPool(List<String> ips) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_masterPoolKey, ips.toSet().where(isValidIp).toList());
  }

  Future<List<String>> loadMasterPool() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_masterPoolKey) ?? <String>[];
  }

  Future<void> saveDisplayList(List<String> ips) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_displayListKey, ips.toSet().where(isValidIp).toList());
  }

  Future<List<String>> loadDisplayList() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_displayListKey) ?? <String>[];
  }

  List<String> extractIpsFromText(String text) {
    final found = <String>{};
    final regex = RegExp(
      r'(?<!\d)(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?!\d)',
    );
    for (final match in regex.allMatches(text)) {
      final ip = match.group(0)!;
      if (isValidIp(ip)) found.add(ip);
    }
    return found.toList();
  }

  bool _isGamingText(String text) {
    final lower = text.toLowerCase();
    return gamingKeywords.any(lower.contains);
  }

  Future<List<DnsCandidate>> _fetchSource(String url) async {
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: const {
          'User-Agent': 'GamingDNS-Hunter/2.0',
          'Accept': 'text/plain,text/markdown,application/json,*/*',
        },
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode != 200 || response.body.isEmpty) return [];
      final gaming = _isGamingText(response.body) || _isGamingText(url);
      final ips = extractIpsFromText(response.body);
      return ips
          .map((ip) => DnsCandidate(
                ip: ip,
                source: url,
                category: gaming ? 'Gaming source' : 'Public DNS',
                gamingTagged: gaming,
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<Map<String, dynamic>?> _fetchRemoteDatabase() async {
    if (remoteDatabaseUrl.isEmpty) return null;
    try {
      final response = await http.get(
        Uri.parse(remoteDatabaseUrl),
        headers: const {
          'Accept': 'application/json',
          'User-Agent': 'GamingDNS-Hunter/3.0',
        },
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode != 200 || response.body.isEmpty) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  List<DnsCandidate> _candidatesFromRemoteDatabase(
    Map<String, dynamic> database,
  ) {
    final rawItems = database['items'];
    if (rawItems is! List) return const <DnsCandidate>[];

    final result = <DnsCandidate>[];
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final ip = raw['ip']?.toString();
      if (ip == null || !isValidIp(ip)) continue;
      final source = raw['source']?.toString() ?? 'GitHub database';
      final gaming = raw['gamingTagged'] == true;
      result.add(DnsCandidate(
        ip: ip,
        source: source,
        category: raw['category']?.toString() ??
            (gaming ? 'Gaming / GitHub' : 'Public DNS'),
        gamingTagged: gaming,
      ));
    }
    return result;
  }

  Future<List<DnsCandidate>> _fetchGitHubRepositories() async {
    final results = <DnsCandidate>[];
    final seenRepos = <String>{};

    for (final query in githubQueries) {
      try {
        final uri = Uri.https('api.github.com', '/search/repositories', {
          'q': query,
          'sort': 'updated',
          'order': 'desc',
          'per_page': '3',
        });
        final response = await http.get(uri, headers: const {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2026-03-10',
          'User-Agent': 'GamingDNS-Hunter/2.0',
        }).timeout(const Duration(seconds: 12));

        if (response.statusCode != 200) continue;
        final data = jsonDecode(response.body);
        final items = data is Map<String, dynamic> ? data['items'] : null;
        if (items is! List) continue;

        for (final item in items) {
          if (item is! Map) continue;
          final fullName = item['full_name']?.toString();
          final branch = item['default_branch']?.toString() ?? 'main';
          if (fullName == null || !seenRepos.add(fullName)) continue;

          final rawReadme = Uri.parse(
            'https://raw.githubusercontent.com/$fullName/$branch/README.md',
          );
          try {
            final readme = await http.get(rawReadme, headers: const {
              'User-Agent': 'GamingDNS-Hunter/2.0',
            }).timeout(const Duration(seconds: 10));
            if (readme.statusCode == 200) {
              final gaming = _isGamingText(readme.body) || _isGamingText(query);
              for (final ip in extractIpsFromText(readme.body)) {
                results.add(DnsCandidate(
                  ip: ip,
                  source: 'GitHub: $fullName',
                  category: gaming ? 'Gaming / GitHub' : 'GitHub',
                  gamingTagged: gaming,
                ));
              }
            }
          } catch (_) {}
        }
      } catch (_) {}
    }

    return results;
  }

  Future<HuntResult> fetchFromNetwork({bool forceGitHub = false}) async {
    final masterPool = (await loadMasterPool()).toSet();
    final sources = await loadSources();
    var successfulSources = 0;
    var githubRepoCount = 0;
    final candidates = <DnsCandidate>[];

    // Primary path: one generated JSON file in this application's GitHub
    // repository. GitHub Actions refreshes it automatically.
    final remote = await _fetchRemoteDatabase();
    if (remote != null) {
      final remoteCandidates = _candidatesFromRemoteDatabase(remote);
      candidates.addAll(remoteCandidates);
      if (remoteCandidates.isNotEmpty) successfulSources++;
      final count = remote['github_repository_count'];
      if (count is num) githubRepoCount = count.toInt();
    }

    // Supplement the database with direct public sources. This is a fallback
    // and also lets a manual Hunt discover newly published resolvers before
    // the next scheduled GitHub database refresh.
    final sourceResults = await Future.wait(sources.map(_fetchSource));
    for (final list in sourceResults) {
      if (list.isNotEmpty) successfulSources++;
      candidates.addAll(list);
    }

    // If the repository database is unavailable, use the GitHub API as a
    // last-resort fallback. It is deliberately not the normal path.
    if (remote == null && (forceGitHub || candidates.isEmpty)) {
      final githubCandidates = await _fetchGitHubRepositories();
      candidates.addAll(githubCandidates);
      githubRepoCount = githubCandidates.map((e) => e.source).toSet().length;
    }

    const gamingCommunity = <String>[
      '94.103.125.157',
      '94.103.125.158',
      '78.157.42.100',
      '78.157.42.101',
    ];
    for (final ip in gamingCommunity) {
      candidates.add(DnsCandidate(
        ip: ip,
        source: 'Gaming community seed',
        category: 'Gaming',
        gamingTagged: true,
      ));
    }

    final before = masterPool.length;
    final ordered = <String>{};
    for (final c in candidates.where((c) => c.gamingTagged)) {
      ordered.add(c.ip);
    }
    for (final c in candidates.where((c) => !c.gamingTagged)) {
      ordered.add(c.ip);
    }
    masterPool.addAll(ordered);

    final savedOrder = <String>{...ordered, ...masterPool};
    final saved = savedOrder.take(15000).toList();
    await saveMasterPool(saved);

    final metadata = await loadMetadata();
    for (final candidate in candidates) {
      final previous = metadata[candidate.ip];
      final previousGaming = previous?['gamingTagged'] == true;
      metadata[candidate.ip] = {
        'source': candidate.source,
        'category': candidate.category,
        'gamingTagged': candidate.gamingTagged || previousGaming,
      };
    }
    await saveMetadata(metadata);

    return HuntResult(
      newCount: masterPool.length - before,
      totalCount: saved.length,
      sourceSuccesses: successfulSources,
      githubRepositories: githubRepoCount,
    );
  }

  Future<Map<String, GeoInfo>> loadGeoCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_geoCacheKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map<String, GeoInfo>((key, value) => MapEntry(
            key.toString(),
            GeoInfo.fromJson(Map<String, dynamic>.from(value as Map)),
          ));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveGeoCache(Map<String, GeoInfo> cache) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonMap = cache.map((key, value) => MapEntry(key, value.toJson()));
    await prefs.setString(_geoCacheKey, jsonEncode(jsonMap));
  }

  Future<Map<String, GeoInfo>> enrichCountries(List<String> ips) async {
    final cache = await loadGeoCache();
    final missing = ips.where((ip) => !cache.containsKey(ip)).toList();

    // ipwho.is is HTTPS and requires no key; cache aggressively because country
    // information for a resolver changes much more slowly than its RTT.
    const concurrency = 6;
    for (int i = 0; i < missing.length; i += concurrency) {
      final chunk = missing.skip(i).take(concurrency).toList();
      await Future.wait(chunk.map((ip) async {
        try {
          final response = await http.get(
            Uri.parse('https://ipwho.is/$ip'),
            headers: const {'User-Agent': 'GamingDNS-Hunter/2.0'},
          ).timeout(const Duration(seconds: 8));
          if (response.statusCode != 200) return;
          final data = jsonDecode(response.body);
          if (data is! Map || data['success'] != true) return;
          cache[ip] = GeoInfo(
            country: data['country']?.toString() ?? 'Unknown',
            countryCode: data['country_code']?.toString() ?? '',
            city: data['city']?.toString() ?? '',
            org: data['connection'] is Map
                ? (data['connection']['org']?.toString() ?? '')
                : '',
          );
        } catch (_) {}
      }));
      // Be gentle with public geolocation services.
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }

    await _saveGeoCache(cache);
    return cache;
  }

  Future<Map<String, Map<String, dynamic>>> loadMetadata() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_metadataKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map<String, Map<String, dynamic>>((key, value) => MapEntry(
            key.toString(),
            Map<String, dynamic>.from(value as Map),
          ));
    } catch (_) {
      return {};
    }
  }

  Future<void> saveMetadata(Map<String, Map<String, dynamic>> metadata) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_metadataKey, jsonEncode(metadata));
  }

  bool _isDnsResponse(List<int> data, int transactionId) {
    if (data.length < 12) return false;
    final id = (data[0] << 8) | data[1];
    final flags = (data[2] << 8) | data[3];
    final response = (flags & 0x8000) != 0;
    return id == transactionId && response;
  }

  List<int> _buildDnsQuery(String domain, int transactionId) {
    final bytes = <int>[
      (transactionId >> 8) & 0xff,
      transactionId & 0xff,
      0x01, 0x00, // recursion desired
      0x00, 0x01, // one question
      0x00, 0x00,
      0x00, 0x00,
      0x00, 0x00,
    ];
    for (final label in domain.split('.')) {
      final encoded = label.codeUnits;
      bytes.add(encoded.length);
      bytes.addAll(encoded);
    }
    bytes.addAll([0x00, 0x00, 0x01, 0x00, 0x01]); // A / IN
    return bytes;
  }

  Future<int?> measureDnsLatency(String ip, String domain) async {
    if (!isValidIp(ip)) return null;
    final transactionId = Random().nextInt(65536);
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.readEventsEnabled = true;
      final started = Stopwatch()..start();
      final query = _buildDnsQuery(domain, transactionId);
      socket.send(query, InternetAddress(ip), 53);

      final completer = Completer<int?>();
      late StreamSubscription<RawSocketEvent> sub;
      sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = socket?.receive()) != null) {
          final data = packet!.data;
          if (_isDnsResponse(data, transactionId)) {
            if (!completer.isCompleted) completer.complete(started.elapsedMilliseconds);
            break;
          }
        }
      });

      final result = await completer.future.timeout(
        const Duration(milliseconds: 1500),
        onTimeout: () => null,
      );
      await sub.cancel();
      return result;
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }

  Future<int> measureGamingLatency(String ip) async {
    const domains = <String>[
      'callofduty.com',
      'pubgmobile.com',
      'mobilelegends.com',
    ];
    final results = <int>[];
    for (final domain in domains) {
      final latency = await measureDnsLatency(ip, domain);
      if (latency != null) results.add(latency);
    }
    if (results.isEmpty) return 9999;
    results.sort();
    return results.reduce((a, b) => a + b) ~/ results.length;
  }

  Future<File?> generateExportFile() async {
    try {
      final pool = await loadMasterPool();
      final allDns = <String>{...premiumGamingDns, ...pool};
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/Gaming_DNS_Backup.txt');
      await file.writeAsString('${allDns.join('\n')}\n');
      return file;
    } catch (_) {
      return null;
    }
  }
}
