import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, SystemChrome, DeviceOrientation;
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _donateUrl = 'https://ko-fi.com/weddingfund';
const String _appVersion = '1.0.0';
const String _contactEmail = 'marksjones73@gmail.com';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RoofProfileFinderApp());
}

class RoofProfileFinderApp extends StatelessWidget {
  const RoofProfileFinderApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Roof Profile Finder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        scaffoldBackgroundColor: const Color(0xFFF6F2E9),
        useMaterial3: true,
      ),
      home: const ProfileSearchScreen(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// History Entry — wraps a profile with date + location
// ═══════════════════════════════════════════════════════════════

class HistoryEntry {
  final ProfileRecord profile;
  final DateTime savedAt;
  final String? location;

  const HistoryEntry({required this.profile, required this.savedAt, this.location});

  Map<String, dynamic> toJson() => {
    'profile': profile.toJson(),
    'savedAt': savedAt.toIso8601String(),
    'location': location,
  };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    return HistoryEntry(
      profile: ProfileRecord.fromJson(json['profile'] as Map<String, dynamic>),
      savedAt: DateTime.tryParse(json['savedAt']?.toString() ?? '') ?? DateTime.now(),
      location: json['location']?.toString(),
    );
  }

  String get formattedDate {
    final d = savedAt;
    return '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}/${d.year}  ${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
  }
}

// ═══════════════════════════════════════════════════════════════
// History Service
// ═══════════════════════════════════════════════════════════════

class HistoryService {
  static const String _key = 'profile_history_v2';
  static const int _maxItems = 20;

  static Future<void> saveEntry(HistoryEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> history = prefs.getStringList(_key) ?? [];
    history.insert(0, jsonEncode(entry.toJson()));
    if (history.length > _maxItems) history.removeRange(_maxItems, history.length);
    await prefs.setStringList(_key, history);
  }

  static Future<List<HistoryEntry>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> history = prefs.getStringList(_key) ?? [];
    final List<HistoryEntry> results = [];
    for (final item in history) {
      try {
        results.add(HistoryEntry.fromJson(jsonDecode(item) as Map<String, dynamic>));
      } catch (_) {}
    }
    return results;
  }

  static Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

// ═══════════════════════════════════════════════════════════════
// ProfileRecord
// ═══════════════════════════════════════════════════════════════

class ProfileRecord {
  final String code;
  final String profileName;
  final String manufacturer;
  final String shape;
  final double? pitch;
  final double? depth;
  final double? crown;
  final double? trough;
  final double? coverWidth;
  final double? overallWidth;
  final String category;
  final String? brand;
  final String? material;
  final String? materialGroup;
  final String? tileType;
  final String? profile;
  final String? profileGroup;
  final String? fixingType;
  final List<String> aliases;
  final double? nominalLengthMm;
  final double? nominalWidthMm;
  final double? gaugeMinMm;
  final double? gaugeMaxMm;
  final double? minimumPitchDegMin;
  final double? coveragePerSqm;
  final double? weightKgPerSqm;
  final String? overallSizeText;
  final String? coverWidthText;
  final String? gaugeText;
  final String? minimumPitchText;
  final String? coverageText;
  final String? weightText;
  final String? sourceUrl;
  final String? notes;
  final String? imageFile;

  const ProfileRecord({
    required this.code, required this.profileName, required this.manufacturer,
    required this.shape, required this.pitch, required this.depth,
    required this.crown, required this.trough, required this.coverWidth,
    required this.overallWidth, required this.category, required this.brand,
    required this.material, required this.materialGroup, required this.tileType,
    required this.profile, required this.profileGroup, required this.fixingType,
    required this.aliases, required this.nominalLengthMm, required this.nominalWidthMm,
    required this.gaugeMinMm, required this.gaugeMaxMm, required this.minimumPitchDegMin,
    required this.coveragePerSqm, required this.weightKgPerSqm, required this.overallSizeText,
    required this.coverWidthText, required this.gaugeText, required this.minimumPitchText,
    required this.coverageText, required this.weightText, required this.sourceUrl,
    required this.notes, required this.imageFile,
  });

  Map<String, dynamic> toJson() => {
    'code': code, 'profileName': profileName, 'manufacturer': manufacturer,
    'shape': shape, 'pitch': pitch, 'depth': depth, 'crown': crown,
    'trough': trough, 'coverWidth': coverWidth, 'overallWidth': overallWidth,
    'category': category, 'brand': brand, 'material': material,
    'materialGroup': materialGroup, 'tileType': tileType, 'profile': profile,
    'profileGroup': profileGroup, 'fixingType': fixingType, 'aliases': aliases,
    'nominalLengthMm': nominalLengthMm, 'nominalWidthMm': nominalWidthMm,
    'gaugeMinMm': gaugeMinMm, 'gaugeMaxMm': gaugeMaxMm,
    'minimumPitchDegMin': minimumPitchDegMin, 'coveragePerSqm': coveragePerSqm,
    'weightKgPerSqm': weightKgPerSqm, 'overallSizeText': overallSizeText,
    'coverWidthText': coverWidthText, 'gaugeText': gaugeText,
    'minimumPitchText': minimumPitchText, 'coverageText': coverageText,
    'weightText': weightText, 'sourceUrl': sourceUrl, 'notes': notes,
    'imageFile': imageFile,
  };

  factory ProfileRecord.fromJson(Map<String, dynamic> json) {
    double? toD(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString().trim());
    }
    List<String> toList(dynamic v) {
      if (v is List) return v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
      return [];
    }
    final String cat = json['category']?.toString().trim().isNotEmpty == true
        ? json['category'].toString().trim().toLowerCase() : 'sheet';
    String? rawImg = json['image_file']?.toString() ?? json['imageFile']?.toString();
    String? imgFile = json['imageFile']?.toString();
    if (imgFile == null && rawImg != null && rawImg.isNotEmpty) {
      imgFile = rawImg.startsWith('assets/') ? rawImg : 'assets/$rawImg';
    }
    return ProfileRecord(
      code: json['code']?.toString() ?? json['id']?.toString() ?? '',
      profileName: json['profileName']?.toString() ?? '',
      manufacturer: json['manufacturer']?.toString() ?? '',
      shape: json['shape']?.toString() ?? json['profile']?.toString() ?? 'unknown',
      pitch: toD(json['pitch']), depth: toD(json['depth']),
      crown: toD(json['crown']), trough: toD(json['trough']),
      coverWidth: toD(json['coverWidth']) ?? toD(json['coverWidthMm']),
      overallWidth: toD(json['overallWidth']), category: cat,
      brand: json['brand']?.toString(), material: json['material']?.toString(),
      materialGroup: json['materialGroup']?.toString(), tileType: json['tileType']?.toString(),
      profile: json['profile']?.toString(), profileGroup: json['profileGroup']?.toString(),
      fixingType: json['fixingType']?.toString(), aliases: toList(json['aliases']),
      nominalLengthMm: toD(json['nominalLengthMm']), nominalWidthMm: toD(json['nominalWidthMm']),
      gaugeMinMm: toD(json['gaugeMinMm']), gaugeMaxMm: toD(json['gaugeMaxMm']),
      minimumPitchDegMin: toD(json['minimumPitchDegMin']), coveragePerSqm: toD(json['coveragePerSqm']),
      weightKgPerSqm: toD(json['weightKgPerSqm']), overallSizeText: json['overallSizeText']?.toString(),
      coverWidthText: json['coverWidthText']?.toString(), gaugeText: json['gaugeText']?.toString(),
      minimumPitchText: json['minimumPitchText']?.toString(), coverageText: json['coverageText']?.toString(),
      weightText: json['weightText']?.toString(), sourceUrl: json['sourceUrl']?.toString(),
      notes: json['notes']?.toString(), imageFile: imgFile,
    );
  }

  bool get isTileCategory => category == 'tile';
  String get displayTitle => code.isNotEmpty && !isTileCategory ? '$code - $profileName' : profileName;
  String get materialLabel => materialGroup ?? material ?? '-';
  String get tileTypeLabel => tileType ?? profile ?? '-';
  String get profileFamilyLabel => profileGroup ?? profile ?? '-';
}

class SearchResult {
  final ProfileRecord profile;
  final double score;
  const SearchResult({required this.profile, required this.score});
}

// ═══════════════════════════════════════════════════════════════
// Profile Search Screen
// ═══════════════════════════════════════════════════════════════

class ProfileSearchScreen extends StatefulWidget {
  const ProfileSearchScreen({super.key});
  @override
  State<ProfileSearchScreen> createState() => _ProfileSearchScreenState();
}

class _ProfileSearchScreenState extends State<ProfileSearchScreen> {
  final TextEditingController _profileSearchController = TextEditingController();
  final TextEditingController _pitchController = TextEditingController();
  final TextEditingController _depthController = TextEditingController();
  final TextEditingController _crownController = TextEditingController();
  final TextEditingController _troughController = TextEditingController();
  final TextEditingController _coverWidthController = TextEditingController();
  final TextEditingController _overallWidthController = TextEditingController();
  final TextEditingController _tileLengthController = TextEditingController();
  final TextEditingController _tileWidthController = TextEditingController();
  final TextEditingController _tileGaugeController = TextEditingController();
  final TextEditingController _tileMinPitchController = TextEditingController();
  final TextEditingController _tileCoverageController = TextEditingController();

  List<ProfileRecord> _profiles = [];
  List<ProfileRecord> _nameSuggestions = [];
  bool _loading = true;
  String _selectedCategory = 'steel';
  double _toleranceMultiplier = 1.0;
  String? _selectedTileMaterial;
  String? _selectedTileType;
  String? _selectedTileProfileFamily;
  List<String> _tileMaterials = [];
  List<String> _tileTypes = [];
  List<String> _tileProfileFamilies = [];

  static const Map<String, String> _fileMap = {
    'steel':  'assets/data/steel_profiles.json',
    'cement': 'assets/data/cement_profiles.json',
    'tile':   'assets/data/tile_profiles_uk_phase2.json',
  };

  static const double _basePitchTolerance = 5;
  static const double _baseDepthTolerance = 5;
  static const double _baseCrownTolerance = 8;
  static const double _baseTroughTolerance = 8;
  static const double _baseCoverWidthTolerance = 40;
  static const double _baseOverallWidthTolerance = 40;
  static const double _baseTileLengthTolerance = 10;
  static const double _baseTileWidthTolerance = 10;
  static const double _baseTileGaugeTolerance = 15;
  static const double _baseTilePitchTolerance = 2;
  static const double _baseTileCoverageTolerance = 1;

  final Uri _donateUri = Uri.parse(_donateUrl);

  @override
  void initState() {
    super.initState();
    _loadProfilesForCategory(_selectedCategory);
    _profileSearchController.addListener(_updateNameSuggestions);
  }

  @override
  void dispose() {
    _profileSearchController.removeListener(_updateNameSuggestions);
    _profileSearchController.dispose();
    _pitchController.dispose(); _depthController.dispose();
    _crownController.dispose(); _troughController.dispose();
    _coverWidthController.dispose(); _overallWidthController.dispose();
    _tileLengthController.dispose(); _tileWidthController.dispose();
    _tileGaugeController.dispose(); _tileMinPitchController.dispose();
    _tileCoverageController.dispose();
    super.dispose();
  }

  bool get _isTileCategory => _selectedCategory == 'tile';

  Future<void> _openDonate() async {
    if (!await launchUrl(_donateUri, mode: LaunchMode.externalApplication) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open donation page.')));
    }
  }

  Future<void> _openSuggestEmail() async {
    final Uri emailUri = Uri(scheme: 'mailto', path: _contactEmail,
      queryParameters: <String, String>{
        'subject': 'Roof Profile Finder - Missing Profile Suggestion',
        'body': 'Hi,\n\nI would like to suggest a missing roof profile.\n\nType: \nManufacturer: \nProfile name/code: \nMeasurements: \nNotes: \n\nThank you.',
      });
    if (!await launchUrl(emailUri, mode: LaunchMode.externalApplication) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open email app.')));
    }
  }

  Future<void> _showAboutDialogBox() async {
    await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('About Roof Profile Finder'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Roof Profile Finder was created to help identify roof profile sheets, tiles and slates more quickly and accurately.'),
        const SizedBox(height: 8),
        const Text('This is my first app and my first experience of coding. I work as a roofer, and I built it to help solve a real problem on site.'),
        const SizedBox(height: 8),
        const Text('Use the search fields, filters and measurements to narrow down likely matches, then review them on the dedicated results screen.'),
        const SizedBox(height: 8),
        const Text('I will continue improving the database over time. If you notice a missing profile, please use the suggest option in the menu.'),
        const SizedBox(height: 12),
        Text('Version: $_appVersion', style: const TextStyle(fontWeight: FontWeight.w600)),
      ])),
      actions: [
        TextButton(onPressed: () async { Navigator.of(ctx).pop(); await _openSuggestEmail(); }, child: const Text('Suggest Profile')),
        TextButton(onPressed: () async { Navigator.of(ctx).pop(); await _openDonate(); }, child: const Text('Donate')),
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
      ],
    ));
  }

  Future<void> _showSuggestProfileDialog() async {
    await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Suggest a Missing Profile'),
      content: const SingleChildScrollView(child: Text('If you cannot find a roof sheet, tile or slate, tap Email below and include as much detail as possible.')),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
        TextButton(onPressed: () async { Navigator.of(ctx).pop(); await _openSuggestEmail(); }, child: const Text('Email')),
      ],
    ));
  }

  void _handleTopMenu(String value) {
    switch (value) {
      case 'help': Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HowToUseScreen())); break;
      case 'about': _showAboutDialogBox(); break;
      case 'suggest': _showSuggestProfileDialog(); break;
    }
  }

  Future<void> _loadProfilesForCategory(String category) async {
    setState(() { _loading = true; _nameSuggestions = []; });
    _clearSearchInputs(silent: true);
    try {
      final String jsonString = await rootBundle.loadString(_fileMap[category]!);
      final List<dynamic> decoded = json.decode(jsonString) as List<dynamic>;
      final List<ProfileRecord> loaded = decoded.map((e) => ProfileRecord.fromJson(e as Map<String, dynamic>)).toList();
      setState(() {
        _selectedCategory = category; _profiles = loaded; _loading = false;
        _tileMaterials = _uniqueSorted(loaded.map((p) => p.materialGroup ?? p.material ?? '').where((v) => v.isNotEmpty));
        _tileTypes = _uniqueSorted(loaded.map((p) => p.tileType ?? p.profile ?? '').where((v) => v.isNotEmpty));
        _tileProfileFamilies = _uniqueSorted(loaded.map((p) => p.profileGroup ?? p.profile ?? '').where((v) => v.isNotEmpty));
      });
    } catch (e) {
      setState(() { _profiles = []; _loading = false; });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load profile data: $e')));
    }
  }

  List<String> _uniqueSorted(Iterable<String> values) {
    final Set<String> unique = {};
    for (final v in values) { final t = v.trim(); if (t.isNotEmpty) unique.add(t); }
    final sorted = unique.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
  }

  void _updateNameSuggestions() {
    final String query = _profileSearchController.text.trim().toLowerCase();
    if (query.isEmpty) { setState(() { _nameSuggestions = []; }); return; }
    final matches = _profiles.where((p) => _matchesQuery(p, query)).toList();
    matches.sort((a, b) {
      final aS = a.profileName.toLowerCase().startsWith(query);
      final bS = b.profileName.toLowerCase().startsWith(query);
      if (aS && !bS) return -1; if (!aS && bS) return 1;
      return a.profileName.toLowerCase().compareTo(b.profileName.toLowerCase());
    });
    setState(() { _nameSuggestions = matches.take(12).toList(); });
  }

  bool _matchesQuery(ProfileRecord p, String query) {
    return [p.profileName, p.code, p.manufacturer, p.brand ?? '', p.shape,
            p.material ?? '', p.materialGroup ?? '', p.tileType ?? '',
            p.profile ?? '', p.profileGroup ?? '', ...p.aliases]
        .any((v) => v.toLowerCase().contains(query));
  }

  void _selectProfileFromNameSearch(ProfileRecord profile) {
    _profileSearchController.text = profile.profileName;
    if (profile.isTileCategory) {
      _tileLengthController.text = profile.nominalLengthMm == null ? '' : _formatNumber(profile.nominalLengthMm);
      _tileWidthController.text = profile.nominalWidthMm == null ? '' : _formatNumber(profile.nominalWidthMm);
      _coverWidthController.text = profile.coverWidth == null ? '' : _formatNumber(profile.coverWidth);
      _tileGaugeController.text = _formatGaugeForInput(profile);
      _tileMinPitchController.text = profile.minimumPitchDegMin == null ? '' : _formatNumber(profile.minimumPitchDegMin);
      _tileCoverageController.text = profile.coveragePerSqm == null ? '' : _formatNumber(profile.coveragePerSqm);
      _selectedTileMaterial = profile.materialGroup ?? profile.material;
      _selectedTileType = profile.tileType ?? profile.profile;
      _selectedTileProfileFamily = profile.profileGroup ?? profile.profile;
    } else {
      _pitchController.text = profile.pitch == null ? '' : _formatNumber(profile.pitch);
      _depthController.text = profile.depth == null ? '' : _formatNumber(profile.depth);
      _crownController.text = profile.crown == null ? '' : _formatNumber(profile.crown);
      _troughController.text = profile.trough == null ? '' : _formatNumber(profile.trough);
      _coverWidthController.text = profile.coverWidth == null ? '' : _formatNumber(profile.coverWidth);
      _overallWidthController.text = profile.overallWidth == null ? '' : _formatNumber(profile.overallWidth);
    }
    setState(() { _nameSuggestions = []; });
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ResultsScreen(title: 'Results', results: [SearchResult(profile: profile, score: 0)])));
  }

  String _formatGaugeForInput(ProfileRecord p) {
    if (p.gaugeMinMm != null && p.gaugeMaxMm != null) return _formatNumber((p.gaugeMinMm! + p.gaugeMaxMm!) / 2);
    if (p.gaugeMinMm != null) return _formatNumber(p.gaugeMinMm);
    if (p.gaugeMaxMm != null) return _formatNumber(p.gaugeMaxMm);
    return '';
  }

  double? _readNumber(TextEditingController c) {
    final t = c.text.trim(); if (t.isEmpty) return null; return double.tryParse(t);
  }

  bool _withinTolerance(double pv, double iv, double t) => (pv - iv).abs() <= t;
  double get _pitchTolerance => _basePitchTolerance * _toleranceMultiplier;
  double get _depthTolerance => _baseDepthTolerance * _toleranceMultiplier;
  double get _crownTolerance => _baseCrownTolerance * _toleranceMultiplier;
  double get _troughTolerance => _baseTroughTolerance * _toleranceMultiplier;
  double get _coverWidthTolerance => _baseCoverWidthTolerance * _toleranceMultiplier;
  double get _overallWidthTolerance => _baseOverallWidthTolerance * _toleranceMultiplier;
  double get _tileLengthTolerance => _baseTileLengthTolerance * _toleranceMultiplier;
  double get _tileWidthTolerance => _baseTileWidthTolerance * _toleranceMultiplier;
  double get _tileGaugeTolerance => _baseTileGaugeTolerance * _toleranceMultiplier;
  double get _tilePitchTolerance => _baseTilePitchTolerance * _toleranceMultiplier;
  double get _tileCoverageTolerance => _baseTileCoverageTolerance * _toleranceMultiplier;

  void _searchProfiles() {
    final matches = _isTileCategory ? _findTileProfiles() : _findSheetProfiles();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ResultsScreen(title: _categoryTitle(), results: matches.take(25).toList())));
  }

  List<SearchResult> _findSheetProfiles() {
    final q = _profileSearchController.text.trim().toLowerCase();
    final pitch = _readNumber(_pitchController), depth = _readNumber(_depthController);
    final crown = _readNumber(_crownController), trough = _readNumber(_troughController);
    final coverWidth = _readNumber(_coverWidthController), overallWidth = _readNumber(_overallWidthController);
    if (q.isEmpty && [pitch, depth, crown, trough, coverWidth, overallWidth].every((v) => v == null)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a name/manufacturer or at least one measurement.')));
      return [];
    }
    final matches = <SearchResult>[];
    for (final p in _profiles) {
      bool passes = true; double score = 0;
      if (q.isNotEmpty && !_matchesQuery(p, q)) passes = false;
      if (pitch != null) { if (p.pitch == null || !_withinTolerance(p.pitch!, pitch, _pitchTolerance)) { passes = false; } else { score += (p.pitch! - pitch).abs(); } }
      if (depth != null) { if (p.depth == null || !_withinTolerance(p.depth!, depth, _depthTolerance)) { passes = false; } else { score += (p.depth! - depth).abs(); } }
      if (crown != null) { if (p.crown == null || !_withinTolerance(p.crown!, crown, _crownTolerance)) { passes = false; } else { score += (p.crown! - crown).abs(); } }
      if (trough != null) { if (p.trough == null || !_withinTolerance(p.trough!, trough, _troughTolerance)) { passes = false; } else { score += (p.trough! - trough).abs(); } }
      if (coverWidth != null) { if (p.coverWidth == null || !_withinTolerance(p.coverWidth!, coverWidth, _coverWidthTolerance)) { passes = false; } else { score += (p.coverWidth! - coverWidth).abs(); } }
      if (overallWidth != null) { if (p.overallWidth == null || !_withinTolerance(p.overallWidth!, overallWidth, _overallWidthTolerance)) { passes = false; } else { score += (p.overallWidth! - overallWidth).abs(); } }
      if (passes) matches.add(SearchResult(profile: p, score: score));
    }
    matches.sort((a, b) => a.score.compareTo(b.score));
    return matches;
  }

  List<SearchResult> _findTileProfiles() {
    final q = _profileSearchController.text.trim().toLowerCase();
    final nomLen = _readNumber(_tileLengthController), nomWid = _readNumber(_tileWidthController);
    final covWid = _readNumber(_coverWidthController), gauge = _readNumber(_tileGaugeController);
    final minPitch = _readNumber(_tileMinPitchController), coverage = _readNumber(_tileCoverageController);
    final hasFilters = _selectedTileMaterial != null || _selectedTileType != null || _selectedTileProfileFamily != null;
    if (q.isEmpty && !hasFilters && [nomLen, nomWid, covWid, gauge, minPitch, coverage].every((v) => v == null)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a name, choose a tile filter, or add a measurement.')));
      return [];
    }
    final matches = <SearchResult>[];
    for (final p in _profiles) {
      bool passes = true; double score = 0;
      if (q.isNotEmpty && !_matchesQuery(p, q)) passes = false;
      if (_selectedTileMaterial != null && (p.materialGroup ?? p.material ?? '').toLowerCase() != _selectedTileMaterial!.toLowerCase()) passes = false;
      if (_selectedTileType != null && (p.tileType ?? p.profile ?? '').toLowerCase() != _selectedTileType!.toLowerCase()) passes = false;
      if (_selectedTileProfileFamily != null && (p.profileGroup ?? p.profile ?? '').toLowerCase() != _selectedTileProfileFamily!.toLowerCase()) passes = false;
      if (nomLen != null) { if (p.nominalLengthMm == null || !_withinTolerance(p.nominalLengthMm!, nomLen, _tileLengthTolerance)) { passes = false; } else { score += (p.nominalLengthMm! - nomLen).abs(); } }
      if (nomWid != null) { if (p.nominalWidthMm == null || !_withinTolerance(p.nominalWidthMm!, nomWid, _tileWidthTolerance)) { passes = false; } else { score += (p.nominalWidthMm! - nomWid).abs(); } }
      if (covWid != null) { if (p.coverWidth == null || !_withinTolerance(p.coverWidth!, covWid, _coverWidthTolerance)) { passes = false; } else { score += (p.coverWidth! - covWid).abs(); } }
      if (gauge != null) { if (!_matchesGauge(p, gauge)) { passes = false; } else { score += _gaugeScore(p, gauge); } }
      if (minPitch != null) { if (p.minimumPitchDegMin == null || !_withinTolerance(p.minimumPitchDegMin!, minPitch, _tilePitchTolerance)) { passes = false; } else { score += (p.minimumPitchDegMin! - minPitch).abs(); } }
      if (coverage != null) { if (p.coveragePerSqm == null || !_withinTolerance(p.coveragePerSqm!, coverage, _tileCoverageTolerance)) { passes = false; } else { score += (p.coveragePerSqm! - coverage).abs(); } }
      if (passes) matches.add(SearchResult(profile: p, score: score));
    }
    matches.sort((a, b) => a.score.compareTo(b.score));
    return matches;
  }

  bool _matchesGauge(ProfileRecord p, double gauge) {
    final t = _tileGaugeTolerance;
    if (p.gaugeMinMm != null && p.gaugeMaxMm != null) return gauge >= p.gaugeMinMm! - t && gauge <= p.gaugeMaxMm! + t;
    if (p.gaugeMinMm != null) return _withinTolerance(p.gaugeMinMm!, gauge, t);
    if (p.gaugeMaxMm != null) return _withinTolerance(p.gaugeMaxMm!, gauge, t);
    return false;
  }

  double _gaugeScore(ProfileRecord p, double gauge) {
    if (p.gaugeMinMm != null && p.gaugeMaxMm != null) return (((p.gaugeMinMm! + p.gaugeMaxMm!) / 2) - gauge).abs();
    if (p.gaugeMinMm != null) return (p.gaugeMinMm! - gauge).abs();
    if (p.gaugeMaxMm != null) return (p.gaugeMaxMm! - gauge).abs();
    return 9999;
  }

  void _clearSearch() { _clearSearchInputs(); setState(() { _nameSuggestions = []; }); }

  void _clearSearchInputs({bool silent = false}) {
    _profileSearchController.clear(); _pitchController.clear(); _depthController.clear();
    _crownController.clear(); _troughController.clear(); _coverWidthController.clear();
    _overallWidthController.clear(); _tileLengthController.clear(); _tileWidthController.clear();
    _tileGaugeController.clear(); _tileMinPitchController.clear(); _tileCoverageController.clear();
    _selectedTileMaterial = null; _selectedTileType = null; _selectedTileProfileFamily = null;
    if (!silent) setState(() {});
  }

  Widget _measurementField(String label, TextEditingController controller) {
    return Padding(padding: const EdgeInsets.only(bottom: 12),
      child: TextField(controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), filled: true, fillColor: Colors.white)));
  }

  Widget _categoryButton(String label, String value) {
    final bool isSelected = _selectedCategory == value;
    return SizedBox(width: 160,
      child: ElevatedButton(onPressed: () => _loadProfilesForCategory(value),
        style: ElevatedButton.styleFrom(
          backgroundColor: isSelected ? Colors.blue.shade700 : Colors.grey.shade300,
          foregroundColor: isSelected ? Colors.white : Colors.black87,
          padding: const EdgeInsets.symmetric(vertical: 14)),
        child: Text(label, textAlign: TextAlign.center)));
  }

  Widget _tileDropdownField({required String label, required String? value, required List<String> items, required ValueChanged<String?> onChanged}) {
    return Padding(padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        initialValue: value, isExpanded: true,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), filled: true, fillColor: Colors.white),
        items: [const DropdownMenuItem<String>(value: null, child: Text('Any')),
                ...items.map((item) => DropdownMenuItem<String>(value: item, child: Text(item)))],
        onChanged: onChanged));
  }

  String _formatNumber(double? value) => value == null ? '-' : (value == value.roundToDouble() ? value.toInt().toString() : value.toStringAsFixed(1));

  Widget _suggestionCard(ProfileRecord p) {
    final subtitle = p.isTileCategory ? '${p.manufacturer} • ${p.tileTypeLabel}' : '${p.manufacturer} • ${p.code}';
    return ListTile(title: Text(p.profileName), subtitle: Text(subtitle), trailing: const Icon(Icons.arrow_forward_ios, size: 16), onTap: () => _selectProfileFromNameSearch(p));
  }

  String _categoryTitle() {
    switch (_selectedCategory) {
      case 'steel': return 'Steel Profiles';
      case 'cement': return 'Fibre Cement Profiles';
      case 'tile': return 'Roof Tiles & Slates';
      default: return 'Profiles';
    }
  }

  String _sliderLabel() {
    if (_toleranceMultiplier <= 0.75) return 'Tight';
    if (_toleranceMultiplier <= 1.25) return 'Normal';
    if (_toleranceMultiplier <= 1.75) return 'Loose';
    if (_toleranceMultiplier <= 2.5) return 'Very Loose';
    return 'Max';
  }

  String _searchFieldLabel() => _isTileCategory ? 'Search tile name, manufacturer, brand, or profile' : 'Search profile name, code, or manufacturer';
  String _searchFieldHint() => _isTileCategory ? 'Start typing tile name or manufacturer...' : 'Start typing profile name...';

  Widget _buildToleranceCard() {
    return Card(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Tolerance: ${_sliderLabel()} (${_toleranceMultiplier.toStringAsFixed(1)}x)', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          Slider(value: _toleranceMultiplier, min: 0.5, max: 3.0, divisions: 10, label: _toleranceMultiplier.toStringAsFixed(1), onChanged: (v) { setState(() { _toleranceMultiplier = v; }); }),
          Text(_isTileCategory
              ? 'Length ±${_tileLengthTolerance.toInt()} | Width ±${_tileWidthTolerance.toInt()} | Cover ±${_coverWidthTolerance.toInt()} | Gauge ±${_tileGaugeTolerance.toInt()} | Min pitch ±${_tilePitchTolerance.toStringAsFixed(1)}° | Coverage ±${_tileCoverageTolerance.toStringAsFixed(1)}'
              : 'Pitch ±${_pitchTolerance.toInt()} | Depth ±${_depthTolerance.toInt()} | Crown ±${_crownTolerance.toInt()} | Trough ±${_troughTolerance.toInt()} | Cover ±${_coverWidthTolerance.toInt()} | Overall ±${_overallWidthTolerance.toInt()}',
            style: const TextStyle(fontSize: 12)),
        ])));
  }

  Widget _buildTileFields() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _tileDropdownField(label: 'Material', value: _selectedTileMaterial, items: _tileMaterials, onChanged: (v) { setState(() { _selectedTileMaterial = v; }); }),
      _tileDropdownField(label: 'Type', value: _selectedTileType, items: _tileTypes, onChanged: (v) { setState(() { _selectedTileType = v; }); }),
      _tileDropdownField(label: 'Profile family', value: _selectedTileProfileFamily, items: _tileProfileFamilies, onChanged: (v) { setState(() { _selectedTileProfileFamily = v; }); }),
      _measurementField('Nominal Length (mm)', _tileLengthController),
      _measurementField('Nominal Width (mm)', _tileWidthController),
      _measurementField('Cover Width (mm)', _coverWidthController),
      _measurementField('Gauge / Batten Spacing (mm)', _tileGaugeController),
      _measurementField('Minimum Roof Pitch (°)', _tileMinPitchController),
      _measurementField('Coverage per m²', _tileCoverageController),
    ]);
  }

  Widget _buildSheetFields() {
    return Column(children: [
      _measurementField('Pitch (mm)', _pitchController),
      _measurementField('Depth (mm)', _depthController),
      _measurementField('Crown (mm)', _crownController),
      _measurementField('Trough (mm)', _troughController),
      _measurementField('Cover Width (mm)', _coverWidthController),
      _measurementField('Overall Width (mm)', _overallWidthController),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(56),
        child: Container(
          color: Colors.blue.shade700,
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: 56,
              child: Row(children: [
                // Logo on the left
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4),
                    child: Image.asset(
                      'assets/images/logo.png',
                      fit: BoxFit.contain,
                      alignment: Alignment.centerLeft,
                      filterQuality: FilterQuality.high,
                      errorBuilder: (context, error, stackTrace) => const Text(
                        'Roof Profile Finder',
                        style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
                // Icons on the right
                IconButton(
                  tooltip: 'Recent History',
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HistoryScreen())),
                  icon: const Icon(Icons.history, size: 26, color: Colors.white),
                ),
                IconButton(
                  tooltip: 'Donate',
                  onPressed: _openDonate,
                  icon: const Icon(Icons.volunteer_activism, size: 26, color: Colors.white),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Menu',
                  onSelected: _handleTopMenu,
                  icon: const Icon(Icons.more_vert, color: Colors.white),
                  itemBuilder: (context) => const [
                    PopupMenuItem<String>(value: 'help', child: Text('How to use')),
                    PopupMenuItem<String>(value: 'about', child: Text('About')),
                    PopupMenuItem<String>(value: 'suggest', child: Text('Suggest missing profile')),
                  ],
                ),
              ]),
            ),
          ),
        ),
      ),
      body: _loading ? const Center(child: CircularProgressIndicator()) : Column(children: [
        Expanded(child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          children: [
            const Text('Choose profile type', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _categoryButton('Steel', 'steel'),
              _categoryButton('Cement', 'cement'),
              _categoryButton('Tiles / Slates', 'tile'),
            ]),
            const SizedBox(height: 18),
            Text(_categoryTitle(), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            TextField(
              controller: _profileSearchController,
              decoration: InputDecoration(
                labelText: _searchFieldLabel(), hintText: _searchFieldHint(),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _profileSearchController.text.isNotEmpty
                    ? IconButton(icon: const Icon(Icons.clear), onPressed: () { _profileSearchController.clear(); setState(() { _nameSuggestions = []; }); })
                    : null,
                border: const OutlineInputBorder(), filled: true, fillColor: Colors.white),
            ),
            if (_nameSuggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Card(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), child: Column(children: _nameSuggestions.map(_suggestionCard).toList())),
            ],
            const SizedBox(height: 16),
            _buildToleranceCard(),
            const SizedBox(height: 12),
            _isTileCategory ? _buildTileFields() : _buildSheetFields(),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: ElevatedButton.icon(onPressed: _searchProfiles, icon: const Icon(Icons.search), label: const Text('Show Results'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)))),
              const SizedBox(width: 12),
              Expanded(child: OutlinedButton.icon(onPressed: _clearSearch, icon: const Icon(Icons.clear), label: const Text('Clear'),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)))),
            ]),
            const SizedBox(height: 20),
            Text('Loaded Profiles: ${_profiles.length}', style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 10),
            Text(_isTileCategory ? 'Enter a name, apply filters, or add measurements to view results on a separate screen.' : 'Enter a name or measurements to view results on a separate screen.'),
          ],
        )),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// History Screen
// ═══════════════════════════════════════════════════════════════

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<HistoryEntry> _history = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _loadHistory(); }

  Future<void> _loadHistory() async {
    final history = await HistoryService.loadHistory();
    setState(() { _history = history; _loading = false; });
  }

  Future<void> _clearHistory() async {
    await HistoryService.clearHistory();
    setState(() { _history = []; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recent History'),
        backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white,
        actions: [
          if (_history.isNotEmpty)
            IconButton(
              tooltip: 'Clear history',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final confirm = await showDialog<bool>(context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Clear History'),
                    content: const Text('Remove all saved profiles?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
                    ]));
                if (confirm == true) _clearHistory();
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _history.isEmpty
              ? const Center(child: Padding(padding: EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.history, size: 64, color: Colors.grey),
                    SizedBox(height: 16),
                    Text('No saved profiles yet.\n\nTap "Save to History" on any result to save it here.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                  ])))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _history.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final HistoryEntry entry = _history[index];
                    final ProfileRecord p = entry.profile;
                    return ListTile(
                      leading: p.imageFile != null
                          ? ClipRRect(borderRadius: BorderRadius.circular(6),
                              child: Image.asset(p.imageFile!, width: 48, height: 48, fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) => const Icon(Icons.roofing, size: 48, color: Colors.blue)))
                          : const Icon(Icons.roofing, size: 48, color: Colors.blue),
                      title: Text(p.displayTitle, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${p.manufacturer} • ${p.isTileCategory ? p.tileTypeLabel : p.category}'),
                        const SizedBox(height: 2),
                        Row(children: [
                          const Icon(Icons.access_time, size: 12, color: Colors.grey),
                          const SizedBox(width: 4),
                          Text(entry.formattedDate, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        ]),
                        if ((entry.location ?? '').isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Row(children: [
                            const Icon(Icons.location_on, size: 12, color: Colors.blue),
                            const SizedBox(width: 4),
                            Expanded(child: Text(entry.location!, style: const TextStyle(fontSize: 11, color: Colors.blue), overflow: TextOverflow.ellipsis)),
                          ]),
                        ],
                      ]),
                      isThreeLine: true,
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => ResultsScreen(title: 'Profile', results: [SearchResult(profile: p, score: 0)]))),
                    );
                  }),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Results Screen
// ═══════════════════════════════════════════════════════════════

class ResultsScreen extends StatefulWidget {
  final String title;
  final List<SearchResult> results;
  const ResultsScreen({super.key, required this.title, required this.results});
  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  final Set<String> _savedKeys = {};

  String _profileKey(ProfileRecord p) => '${p.code}_${p.profileName}';

  Future<void> _saveToHistory(BuildContext context, ProfileRecord profile) async {
    final TextEditingController locationController = TextEditingController();
    final String? location = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Save ${profile.displayTitle}', style: const TextStyle(fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Enter a building or location name (optional):'),
          const SizedBox(height: 12),
          TextField(
            controller: locationController,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              hintText: 'e.g. 14 High Street, Garage Roof...',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.location_on),
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, locationController.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (location == null) return; // cancelled
    await HistoryService.saveEntry(HistoryEntry(
      profile: profile,
      savedAt: DateTime.now(),
      location: location.isEmpty ? null : location,
    ));
    setState(() { _savedKeys.add(_profileKey(profile)); });
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle, color: Colors.white),
          const SizedBox(width: 8),
          Text(location.isEmpty ? 'Saved to history!' : 'Saved to history: $location'),
        ]),
        backgroundColor: Colors.green.shade700,
        duration: const Duration(seconds: 2),
      ));
    }
  }

  Future<void> _openSourceUrl(BuildContext context, String url) async {
    final Uri uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open source link.')));
    }
  }

  String _formatNumber(double? value) {
    if (value == null) return '-';
    return value == value.roundToDouble() ? value.toInt().toString() : value.toStringAsFixed(1);
  }

  String _formatGaugeDisplay(ProfileRecord p) {
    if (p.gaugeText != null && p.gaugeText!.trim().isNotEmpty) return p.gaugeText!;
    if (p.gaugeMinMm != null && p.gaugeMaxMm != null) {
      if (p.gaugeMinMm == p.gaugeMaxMm) return '${_formatNumber(p.gaugeMinMm)} mm';
      return '${_formatNumber(p.gaugeMinMm)}-${_formatNumber(p.gaugeMaxMm)} mm';
    }
    if (p.gaugeMinMm != null) return '${_formatNumber(p.gaugeMinMm)} mm';
    if (p.gaugeMaxMm != null) return '${_formatNumber(p.gaugeMaxMm)} mm';
    return '-';
  }

  Widget _profileImage(BuildContext context, ProfileRecord p) {
    if (p.imageFile == null) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(borderRadius: BorderRadius.circular(6),
          child: SizedBox(height: 160, width: double.infinity,
            child: InteractiveViewer(panEnabled: true, boundaryMargin: const EdgeInsets.all(10), minScale: 0.5, maxScale: 8.0,
              child: Image.asset(p.imageFile!, fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const SizedBox.shrink())))),
        TextButton.icon(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => _FullScreenImagePage(imageFile: p.imageFile!, title: p.displayTitle))),
          icon: const Icon(Icons.fullscreen, size: 16),
          label: const Text('Full screen', style: TextStyle(fontSize: 12)),
          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4), visualDensity: VisualDensity.compact)),
      ]));
  }

  Widget _saveButton(BuildContext context, ProfileRecord p) {
    final bool saved = _savedKeys.contains(_profileKey(p));
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SizedBox(width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: saved ? null : () => _saveToHistory(context, p),
          icon: Icon(saved ? Icons.check_circle : Icons.bookmark_add_outlined),
          label: Text(saved ? 'Saved to History' : 'Save to History + Location'),
          style: ElevatedButton.styleFrom(
            backgroundColor: saved ? Colors.green.shade600 : Colors.blue.shade700,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
    );
  }

  Widget _sheetResultCard(BuildContext context, SearchResult result) {
    final ProfileRecord p = result.profile;
    return Card(margin: const EdgeInsets.only(top: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p.displayTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _profileImage(context, p),
          const SizedBox(height: 6),
          Text('Manufacturer: ${p.manufacturer}'),
          Text('Shape: ${p.shape}'),
          Text('Pitch: ${_formatNumber(p.pitch)} mm'),
          Text('Depth: ${_formatNumber(p.depth)} mm'),
          Text('Crown: ${_formatNumber(p.crown)} mm'),
          Text('Trough: ${_formatNumber(p.trough)} mm'),
          Text('Cover Width: ${_formatNumber(p.coverWidth)} mm'),
          Text('Overall Width: ${_formatNumber(p.overallWidth)} mm'),
          Text('Match Score: ${result.score.toStringAsFixed(1)}'),
          _saveButton(context, p),
        ])));
  }

  Widget _tileResultCard(BuildContext context, SearchResult result) {
    final ProfileRecord p = result.profile;
    return Card(margin: const EdgeInsets.only(top: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p.displayTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _profileImage(context, p),
          const SizedBox(height: 6),
          Text('Manufacturer: ${p.manufacturer}'),
          if ((p.brand ?? '').isNotEmpty) Text('Brand: ${p.brand}'),
          Text('Material: ${p.materialLabel}'),
          Text('Type: ${p.tileTypeLabel}'),
          Text('Profile Family: ${p.profileFamilyLabel}'),
          if ((p.fixingType ?? '').isNotEmpty) Text('Fixing: ${p.fixingType}'),
          Text('Nominal Size: ${p.overallSizeText ?? '${_formatNumber(p.nominalLengthMm)} x ${_formatNumber(p.nominalWidthMm)} mm'}'),
          Text('Cover Width: ${p.coverWidthText ?? (p.coverWidth == null ? '-' : '${_formatNumber(p.coverWidth)} mm')}'),
          Text('Gauge/Batten: ${_formatGaugeDisplay(p)}'),
          Text('Minimum Pitch: ${p.minimumPitchText ?? (p.minimumPitchDegMin == null ? '-' : '${_formatNumber(p.minimumPitchDegMin)}°')}'),
          Text('Coverage: ${p.coverageText ?? (p.coveragePerSqm == null ? '-' : '${_formatNumber(p.coveragePerSqm)} tiles/m²')}'),
          Text('Weight: ${p.weightText ?? (p.weightKgPerSqm == null ? '-' : '${_formatNumber(p.weightKgPerSqm)} kg/m²')}'),
          Text('Match Score: ${result.score.toStringAsFixed(1)}'),
          if ((p.notes ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(p.notes!, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          ],
          if ((p.sourceUrl ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            TextButton.icon(onPressed: () => _openSourceUrl(context, p.sourceUrl!), icon: const Icon(Icons.open_in_new), label: const Text('Open manufacturer source')),
          ],
          _saveButton(context, p),
        ])));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.title} Results'), backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white),
      body: widget.results.isEmpty
          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No matches found.\n\nTry widening the tolerance or changing one of the measurements.', textAlign: TextAlign.center)))
          : SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('Matches found: ${widget.results.length}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              ...widget.results.map((r) => Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
                child: r.profile.isTileCategory ? _tileResultCard(context, r) : _sheetResultCard(context, r))),
              const SizedBox(height: 20),
            ])),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Full-Screen Image Viewer
// ═══════════════════════════════════════════════════════════════

class _FullScreenImagePage extends StatefulWidget {
  final String imageFile;
  final String title;
  const _FullScreenImagePage({required this.imageFile, required this.title});
  @override
  State<_FullScreenImagePage> createState() => _FullScreenImagePageState();
}

class _FullScreenImagePageState extends State<_FullScreenImagePage> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }
  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(widget.title, style: const TextStyle(fontSize: 14)), backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: LayoutBuilder(builder: (context, constraints) {
        return InteractiveViewer(panEnabled: true, boundaryMargin: const EdgeInsets.all(20), minScale: 0.5, maxScale: 8.0,
          child: SizedBox(width: constraints.maxWidth, height: constraints.maxHeight,
            child: Image.asset(widget.imageFile, fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => const Center(
                child: Padding(padding: EdgeInsets.all(24),
                  child: Text('Image not available.', style: TextStyle(color: Colors.white), textAlign: TextAlign.center))))));
      }),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// How To Use Screen
// ═══════════════════════════════════════════════════════════════

class HowToUseScreen extends StatefulWidget {
  const HowToUseScreen({super.key});
  @override
  State<HowToUseScreen> createState() => _HowToUseScreenState();
}

class _HowToUseScreenState extends State<HowToUseScreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }
  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('How to use'), backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Center(child: InteractiveViewer(panEnabled: true, minScale: 0.8, maxScale: 4,
        child: Image.asset('assets/images/how_to_use.png', fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => const Padding(padding: EdgeInsets.all(24),
            child: Text('Help image not found.\n\nMake sure the file is in:\nassets/images/how_to_use.png', textAlign: TextAlign.center, style: TextStyle(color: Colors.white)))))),
    );
  }
}
