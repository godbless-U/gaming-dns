import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'dns_manager.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GamingDnsApp());
}

class DnsServer {
  final String ip;
  int ping;
  bool isGaming;
  String category;
  String source;
  String country;
  String countryCode;
  String organization;

  DnsServer({
    required this.ip,
    this.ping = 9999,
    this.isGaming = false,
    this.category = 'Public DNS',
    this.source = 'Unknown source',
    this.country = 'Unknown',
    this.countryCode = '',
    this.organization = '',
  });
}

class GamingDnsApp extends StatelessWidget {
  const GamingDnsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.deepPurpleAccent,
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.deepPurpleAccent,
          centerTitle: true,
        ),
      ),
      home: const DnsScreen(),
    );
  }
}

class DnsScreen extends StatefulWidget {
  const DnsScreen({super.key});

  @override
  State<DnsScreen> createState() => _DnsScreenState();
}

class _DnsScreenState extends State<DnsScreen> {
  static const platform = MethodChannel('com.example.gaming_dns/vpn');
  final DnsManager _dnsManager = DnsManager();

  List<DnsServer> displayList = [];
  bool isLoading = false;
  bool isTestingPing = false;
  String huntStatus = 'آماده';
  String? connectedDns;
  int selectedBatchSize = 25;
  int totalPoolSize = 0;
  int lastNewCount = 0;
  int lastSourceCount = 0;
  int lastGithubCount = 0;

  @override
  void initState() {
    super.initState();
    _loadSavedData();
  }

  Future<void> _loadSavedData() async {
    if (mounted) setState(() => isLoading = true);

    final savedIps = await _dnsManager.loadDisplayList();
    final pool = await _dnsManager.loadMasterPool();
    final metadata = await _dnsManager.loadMetadata();
    final initialList = <DnsServer>[];

    for (final ip in _dnsManager.premiumGamingDns) {
      initialList.add(_serverFromMetadata(
        ip,
        metadata[ip],
        isGaming: true,
        category: 'Gaming seed',
      ));
    }

    for (final ip in savedIps) {
      if (!_dnsManager.premiumGamingDns.contains(ip)) {
        initialList.add(_serverFromMetadata(ip, metadata[ip]));
      }
    }

    if (!mounted) return;
    setState(() {
      displayList = initialList;
      totalPoolSize = pool.length;
      isLoading = false;
    });

    if (displayList.isNotEmpty) {
      await testAllPingsAndSort();
    }
  }

  DnsServer _serverFromMetadata(
    String ip,
    Map<String, dynamic>? metadata, {
    bool isGaming = false,
    String? category,
  }) {
    return DnsServer(
      ip: ip,
      isGaming: isGaming || metadata?['gamingTagged'] == true,
      category: category ?? metadata?['category']?.toString() ?? 'Public DNS',
      source: metadata?['source']?.toString() ?? 'Discovered source',
    );
  }

  Future<void> huntNewDns() async {
    if (isLoading || isTestingPing) return;

    setState(() {
      isLoading = true;
      huntStatus = 'در حال جستجوی منابع عمومی اینترنت...';
    });

    try {
      final result = await _dnsManager.fetchFromNetwork();
      final pool = await _dnsManager.loadMasterPool();
      final metadata = await _dnsManager.loadMetadata();

      final gaming = <DnsServer>[];
      final general = <DnsServer>[];
      final existing = displayList.map((e) => e.ip).toSet();

      for (final ip in pool) {
        if (existing.contains(ip) && !_dnsManager.premiumGamingDns.contains(ip)) {
          continue;
        }
        final server = _serverFromMetadata(ip, metadata[ip]);
        if (server.isGaming) {
          gaming.add(server);
        } else {
          general.add(server);
        }
      }

      // Always put gaming-labelled candidates first, then sample the global pool.
      gaming.shuffle(Random());
      general.shuffle(Random());

      final selected = <DnsServer>[];
      for (final ip in _dnsManager.premiumGamingDns) {
        selected.add(_serverFromMetadata(
          ip,
          metadata[ip],
          isGaming: true,
          category: 'Gaming seed',
        ));
      }

      for (final server in gaming) {
        if (selected.length >= selectedBatchSize + _dnsManager.premiumGamingDns.length) break;
        if (!selected.any((e) => e.ip == server.ip)) selected.add(server);
      }
      for (final server in general) {
        if (selected.length >= selectedBatchSize + _dnsManager.premiumGamingDns.length) break;
        if (!selected.any((e) => e.ip == server.ip)) selected.add(server);
      }

      if (selected.isEmpty) {
        throw Exception('No DNS candidates were found');
      }

      final selectedIps = selected.map((e) => e.ip).toList();
      await _dnsManager.saveDisplayList(selectedIps);

      if (!mounted) return;
      setState(() {
        displayList = selected;
        totalPoolSize = pool.length;
        lastNewCount = result.newCount;
        lastSourceCount = result.sourceSuccesses;
        lastGithubCount = result.githubRepositories;
        huntStatus =
            'پیدا شد: ${result.newCount} جدید | منابع موفق: ${result.sourceSuccesses} | GitHub: ${result.githubRepositories}';
        isLoading = false;
      });

      await _enrichVisibleServers();
      await testAllPingsAndSort();
    } catch (e) {
      debugPrint('Hunt error: $e');
      if (!mounted) return;
      setState(() {
        isLoading = false;
        huntStatus = 'شکار ناموفق بود؛ اتصال اینترنت یا منابع را بررسی کنید.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('جستجوی DNS انجام نشد. دوباره تلاش کنید.'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _enrichVisibleServers() async {
    if (displayList.isEmpty) return;

    if (mounted) {
      setState(() => huntStatus = 'در حال تشخیص کشور و اپراتور DNSها...');
    }

    final geo = await _dnsManager.enrichCountries(
      displayList.map((e) => e.ip).toList(),
    );

    if (!mounted) return;
    setState(() {
      for (final server in displayList) {
        final info = geo[server.ip];
        if (info == null) continue;
        server.country = info.country;
        server.countryCode = info.countryCode;
        server.organization = info.org;
      }
      huntStatus = 'کشور تشخیص داده شد؛ در حال تست تأخیر DNS برای بازی‌ها...';
    });
  }

  Future<void> testAllPingsAndSort() async {
    if (displayList.isEmpty || isTestingPing) return;
    if (mounted) setState(() => isTestingPing = true);

    const chunkSize = 10;
    for (int i = 0; i < displayList.length; i += chunkSize) {
      final end = min(i + chunkSize, displayList.length);
      final chunk = displayList.sublist(i, end);

      await Future.wait(chunk.map((server) async {
        server.ping = await _dnsManager.measureGamingLatency(server.ip);
      }));

      if (mounted) {
        setState(() {});
      }
    }

    if (!mounted) return;
    setState(() {
      displayList.sort((a, b) {
        final aGaming = a.isGaming ? 0 : 1;
        final bGaming = b.isGaming ? 0 : 1;
        if (aGaming != bGaming) return aGaming.compareTo(bGaming);
        return a.ping.compareTo(b.ping);
      });
      isTestingPing = false;
      huntStatus = 'تست DNS تمام شد؛ لیست بر اساس تمرکز گیمینگ و RTT مرتب شد.';
    });
  }

  Future<void> pickAndImportFile() async {
    final pickedFile = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['txt', 'csv', 'md', 'json'],
    );
    if (pickedFile == null || pickedFile.path == null) return;

    try {
      final file = File(pickedFile.path!);
      final contents = await file.readAsString();
      final newIps = _dnsManager.extractIpsFromText(contents);
      final masterPool = await _dnsManager.loadMasterPool();
      masterPool.addAll(newIps);
      await _dnsManager.saveMasterPool(masterPool);

      if (!mounted) return;
      setState(() => totalPoolSize = masterPool.toSet().length);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${newIps.length} DNS استخراج شد.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      debugPrint('Import error: $e');
    }
  }

  Future<void> exportDnsDatabase() async {
    if (mounted) setState(() => isLoading = true);
    final exportFile = await _dnsManager.generateExportFile();
    if (!mounted) return;
    setState(() => isLoading = false);

    if (exportFile != null) {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(exportFile.path)],
          text: 'Gaming DNS Hunter backup',
        ),
      );
    }
  }

  void _showAddOptionsModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.dns, color: Colors.greenAccent),
              title: const Text('افزودن DNS تکی'),
              onTap: () {
                Navigator.pop(sheetContext);
                _showAddSingleDnsDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link, color: Colors.orangeAccent),
              title: const Text('افزودن لینک منبع'),
              onTap: () {
                Navigator.pop(sheetContext);
                _showAddSourceDialog();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAddSingleDnsDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('افزودن DNS'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '8.8.8.8'),
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('لغو'),
          ),
          ElevatedButton(
            onPressed: () async {
              final ip = controller.text.trim();
              if (!_dnsManager.isValidIp(ip)) return;

              final ips = displayList.map((e) => e.ip).toList();
              if (!ips.contains(ip)) {
                ips.add(ip);
                await _dnsManager.saveDisplayList(ips);
              }

              if (!dialogContext.mounted) return;
              Navigator.pop(dialogContext);
              await _loadSavedData();
            },
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
  }

  void _showAddSourceDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('افزودن لینک منبع'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'https://...'),
          keyboardType: TextInputType.url,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('لغو'),
          ),
          ElevatedButton(
            onPressed: () async {
              final url = controller.text.trim();
              if (!url.startsWith('https://')) {
                return;
              }
              final sources = await _dnsManager.loadSources();
              if (!sources.contains(url)) {
                sources.add(url);
                await _dnsManager.saveSources(sources);
              }
              if (!dialogContext.mounted) return;
              Navigator.pop(dialogContext);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('منبع اضافه شد؛ اکنون شکار را اجرا کنید.'),
                  backgroundColor: Colors.green,
                ),
              );
            },
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
  }

  Future<void> connectDns(String dns) async {
    try {
      await platform.invokeMethod('startVpn', {'dns_ip': dns});
      if (!mounted) return;
      setState(() => connectedDns = dns);
    } on PlatformException catch (e) {
      debugPrint("VPN error: '${e.message}'.");
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطای اتصال VPN: ${e.message ?? 'نامشخص'}')),
      );
    }
  }

  Future<void> disconnectDns() async {
    try {
      await platform.invokeMethod('stopVpn');
      if (!mounted) return;
      setState(() => connectedDns = null);
    } on PlatformException catch (e) {
      debugPrint("VPN error: '${e.message}'.");
    }
  }

  String countryFlag(String code) {
    final normalized = code.trim().toUpperCase();
    if (normalized.length != 2) return '🌐';
    return String.fromCharCodes(
      normalized.codeUnits.map((c) => 0x1F1E6 + c - 65),
    );
  }

  Color pingColor(int ping) {
    if (ping == 9999) return Colors.redAccent;
    if (ping <= 60) return Colors.greenAccent;
    if (ping <= 100) return Colors.lightGreenAccent;
    if (ping <= 160) return Colors.amberAccent;
    return Colors.orangeAccent;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'DNS Hunter PRO',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: 'Import',
            onPressed: isLoading ? null : pickAndImportFile,
          ),
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Export',
            onPressed: isLoading ? null : exportDnsDatabase,
          ),
          if (displayList.isNotEmpty)
            IconButton(
              icon: isTestingPing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.speed),
              onPressed: isTestingPing ? null : testAllPingsAndSort,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.deepPurpleAccent,
        onPressed: _showAddOptionsModal,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: const Color(0xFF1E1E1E),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'استخر: $totalPoolSize  |  جدید: $lastNewCount',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                    DropdownButton<int>(
                      value: selectedBatchSize,
                      dropdownColor: const Color(0xFF2C2C2C),
                      underline: const SizedBox.shrink(),
                      items: [25, 50, 100]
                          .map((value) => DropdownMenuItem<int>(
                                value: value,
                                child: Text('$value'),
                              ))
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => selectedBatchSize = value);
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orangeAccent,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: isLoading || isTestingPing ? null : huntNewDns,
                      icon: const Icon(Icons.radar),
                      label: const Text(
                        'شکار آنلاین',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    huntStatus,
                    textDirection: TextDirection.rtl,
                    style: const TextStyle(fontSize: 11, color: Colors.white60),
                  ),
                ),
              ],
            ),
          ),
          if (isLoading)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: displayList.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'برای جستجوی DNSهای عمومی و منابع GitHub روی «شکار آنلاین» بزنید.\n\nDNSهای دارای برچسب Gaming ابتدا بررسی می‌شوند و سپس RTT واقعی پاسخ DNS برای دامنه‌های مرتبط با بازی اندازه‌گیری می‌شود.',
                        textAlign: TextAlign.center,
                        textDirection: TextDirection.rtl,
                        style: TextStyle(color: Colors.grey.shade400),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: displayList.length,
                    itemBuilder: (context, index) {
                      final server = displayList[index];
                      final isConnected = server.ip == connectedDns;
                      final flag = countryFlag(server.countryCode);

                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        color: isConnected
                            ? Colors.deepPurple.withValues(alpha: 0.3)
                            : const Color(0xFF252525),
                        shape: RoundedRectangleBorder(
                          side: BorderSide(
                            color: isConnected
                                ? Colors.deepPurpleAccent
                                : Colors.transparent,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: ListTile(
                          title: Row(
                            children: [
                              Text(
                                flag,
                                style: const TextStyle(fontSize: 18),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  server.ip,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              if (server.isGaming)
                                const Text(
                                  '🎮 GAMING',
                                  style: TextStyle(
                                    color: Colors.orangeAccent,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                            ],
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      server.ping == 9999
                                          ? 'Timeout'
                                          : '${server.ping} ms',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: pingColor(server.ping),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Flexible(
                                      child: Text(
                                        server.country == 'Unknown'
                                            ? 'کشور نامشخص'
                                            : '${server.country} • ${server.organization}',
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${server.category} • ${server.source}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 9,
                                    color: Colors.white38,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          trailing: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isConnected
                                  ? Colors.redAccent
                                  : Colors.deepPurpleAccent,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            onPressed: () => isConnected
                                ? disconnectDns()
                                : connectDns(server.ip),
                            child: Text(
                              isConnected ? 'قطع' : 'اتصال',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
