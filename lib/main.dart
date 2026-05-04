import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show rootBundle, SystemChrome, DeviceOrientation, MethodChannel, SystemUiMode, HapticFeedback, SystemSound, SystemSoundType;
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'firebase_options.dart';

const String _donateUrl = 'https://ko-fi.com/weddingfund';
const String _appVersion = '1.0.0';
const String _contactEmail = 'marksjones73@gmail.com';

Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  unawaited(FCMService.init()); // don't block startup waiting for APNs token
  // Restore Google Sign-In to Firebase Auth on cold start
  if (FirebaseAuth.instance.currentUser == null) {
    try {
      final googleSignIn = GoogleSignIn(
        clientId: Platform.isIOS
          ? '899172571973-b5lc827jfa1fr5r01hiv1v69h9gmm0jv.apps.googleusercontent.com'
          : null,
        serverClientId: '899172571973-m520kbun1o8aup8f0f1brqdbcq0i9s3c.apps.googleusercontent.com',
      );
      final googleUser = await googleSignIn.signInSilently();
      if (googleUser != null) {
        final googleAuth = await googleUser.authentication;
        final credential = GoogleAuthProvider.credential(
          accessToken: googleAuth.accessToken,
          idToken: googleAuth.idToken,
        );
        await FirebaseAuth.instance.signInWithCredential(credential);
      }
    } catch (e) {
      debugPrint('Silent sign-in restore failed: $e');
    }
  }
  final prefs = await SharedPreferences.getInstance();
  final bool seenWelcome = prefs.getBool('seen_welcome') ?? false;
  runApp(RoofProfileFinderApp(showWelcome: !seenWelcome));
}

class RoofProfileFinderApp extends StatelessWidget {
  final bool showWelcome;
  const RoofProfileFinderApp({super.key, this.showWelcome = false});
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
      home: showWelcome ? const WelcomeScreen() : const ProfileSearchScreen(homeHubMode: true),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// History Entry — wraps a profile with date + location
// ═══════════════════════════════════════════════════════════════

class HistoryEntry {
  final ProfileRecord profile;
  final DateTime savedAt;
  final String? buildingName;
  final String? location;
  final double? roofPitch;
  final double? gpsLat;
  final double? gpsLng;
  final String? notes;

  const HistoryEntry({required this.profile, required this.savedAt, this.buildingName, this.location, this.roofPitch, this.gpsLat, this.gpsLng, this.notes});

  Map<String, dynamic> toJson() => {
    'profile': profile.toJson(),
    'savedAt': savedAt.toIso8601String(),
    'buildingName': buildingName,
    'location': location,
    'roofPitch': roofPitch,
    'gpsLat': gpsLat,
    'gpsLng': gpsLng,
    'notes': notes,
  };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    double? toD(dynamic v) { if (v == null) return null; if (v is num) return v.toDouble(); return double.tryParse(v.toString()); }
    return HistoryEntry(
      profile: ProfileRecord.fromJson(json['profile'] as Map<String, dynamic>),
      savedAt: DateTime.tryParse(json['savedAt']?.toString() ?? '') ?? DateTime.now(),
      buildingName: json['buildingName']?.toString(),
      location: json['location']?.toString(),
      roofPitch: toD(json['roofPitch']),
      gpsLat: toD(json['gpsLat']),
      gpsLng: toD(json['gpsLng']),
      notes: json['notes']?.toString(),
    );
  }

  bool get hasGps => gpsLat != null && gpsLng != null;

  String get formattedDate {
    final d = savedAt;
    return '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}/${d.year}  ${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
  }
}


// ═══════════════════════════════════════════════════════════════
// FCM Service — push notifications
// ═══════════════════════════════════════════════════════════════

class FCMService {
  static Future<void> init() async {
    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission(
      alert: true, badge: true, sound: true,
    );
    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      final token = await messaging.getToken();
      if (token != null) await _saveToken(token);
      messaging.onTokenRefresh.listen(_saveToken);
    }
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final notification = message.notification;
      if (notification != null) {
        _pendingMessage = '${notification.title}: ${notification.body}';
      }
    });
  }

  static String? _pendingMessage;
  static String? consumePendingMessage() {
    final msg = _pendingMessage;
    _pendingMessage = null;
    return msg;
  }

  static Future<void> _saveToken(String token) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance
      .collection('users').doc(user.uid)
      .set({'fcmToken': token, 'updatedAt': FieldValue.serverTimestamp()},
           SetOptions(merge: true));
  }

  static Future<void> onLogin() async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await _saveToken(token);
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

  static Future<void> deleteEntry(int index) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> history = prefs.getStringList(_key) ?? [];
    if (index >= 0 && index < history.length) {
      history.removeAt(index);
      await prefs.setStringList(_key, history);
    }
  }

  static Future<String> exportBackup() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> history = prefs.getStringList(_key) ?? [];
    final Map<String, dynamic> backup = {
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'entries': history,
    };
    return jsonEncode(backup);
  }

  static Future<int> importBackup(String jsonData) async {
    try {
      final Map<String, dynamic> backup = jsonDecode(jsonData) as Map<String, dynamic>;
      final List<dynamic> entries = backup['entries'] as List<dynamic>;
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getStringList(_key) ?? [];
      // Merge — add new entries that don't already exist
      int added = 0;
      for (final entry in entries) {
        if (!existing.contains(entry.toString())) {
          existing.add(entry.toString());
          added++;
        }
      }
      existing.sort((a, b) {
        try {
          final aDate = DateTime.parse((jsonDecode(a) as Map<String, dynamic>)['savedAt'].toString());
          final bDate = DateTime.parse((jsonDecode(b) as Map<String, dynamic>)['savedAt'].toString());
          return bDate.compareTo(aDate);
        } catch (_) { return 0; }
      });
      if (existing.length > _maxItems) existing.removeRange(_maxItems, existing.length);
      await prefs.setStringList(_key, existing);
      return added;
    } catch (e) {
      throw Exception('Invalid backup file: $e');
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// PDF Service
// ═══════════════════════════════════════════════════════════════

class PdfService {

  static pw.TextStyle _heading() => pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.blue800);
  static pw.TextStyle _subheading() => pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: PdfColors.blueGrey800);
  static pw.TextStyle _body() => const pw.TextStyle(fontSize: 11);
  static pw.TextStyle _label() => pw.TextStyle(fontSize: 10, color: PdfColors.grey600);
  static pw.TextStyle _value() => pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold);

  static pw.Widget _divider() => pw.Container(height: 1, color: PdfColors.grey300, margin: const pw.EdgeInsets.symmetric(vertical: 6));

  static pw.Widget _header() => pw.Container(
    padding: const pw.EdgeInsets.all(16),
    decoration: pw.BoxDecoration(color: PdfColors.blue800, borderRadius: pw.BorderRadius.circular(8)),
    child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
      pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('ROOF PROFILE FINDER', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
        pw.Text('Professional Roofing Report', style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey300)),
      ]),
      pw.Text(_formatDate(DateTime.now()), style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey300)),
    ]),
  );

  static String _formatDate(DateTime d) =>
    '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}/${d.year}';

  static pw.Widget _infoRow(String label, String value) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 3),
    child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.SizedBox(width: 140, child: pw.Text(label, style: _label())),
      pw.Expanded(child: pw.Text(value, style: _value())),
    ]),
  );

  // Generate history PDF
  static Future<Uint8List> generateHistoryPdf(List<HistoryEntry> history) async {
    final pdf = pw.Document();
    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(24),
      header: (_) => _header(),
      footer: (ctx) => pw.Container(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey500)),
      ),
      build: (context) => [
        pw.SizedBox(height: 16),
        pw.Text('Roof Inspection History', style: _heading()),
        pw.SizedBox(height: 4),
        pw.Text('${history.length} saved ${history.length == 1 ? 'profile' : 'profiles'}',
          style: _label()),
        pw.SizedBox(height: 12),
        ...history.asMap().entries.map((entry) {
          final i = entry.key;
          final e = entry.value;
          final p = e.profile;
          return pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 12),
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey300),
              borderRadius: pw.BorderRadius.circular(6),
              color: i % 2 == 0 ? PdfColors.grey50 : PdfColors.white,
            ),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                pw.Text(p.displayTitle, style: _subheading()),
                pw.Text(e.formattedDate, style: _label()),
              ]),
              _divider(),
              if ((e.buildingName ?? '').isNotEmpty) _infoRow('Building / Job:', e.buildingName!),
              _infoRow('Manufacturer:', p.manufacturer),
              _infoRow('Category:', p.isTileCategory ? 'Tile / Slate' : p.category.toUpperCase()),
              if (!p.isTileCategory) ...[
                if (p.pitch != null) _infoRow('Pitch:', '${p.pitch!.toStringAsFixed(0)} mm'),
                if (p.depth != null) _infoRow('Depth:', '${p.depth!.toStringAsFixed(0)} mm'),
                if (p.coverWidth != null) _infoRow('Cover Width:', '${p.coverWidth!.toStringAsFixed(0)} mm'),
              ] else ...[
                if (p.nominalLengthMm != null) _infoRow('Length:', '${p.nominalLengthMm!.toStringAsFixed(0)} mm'),
                if (p.nominalWidthMm != null) _infoRow('Width:', '${p.nominalWidthMm!.toStringAsFixed(0)} mm'),
              ],
              if (e.roofPitch != null) _infoRow('Roof Pitch:', '${e.roofPitch!.toStringAsFixed(1)}°'),
              if ((e.location ?? '').isNotEmpty) _infoRow('Location:', e.location!),
              if (e.hasGps) _infoRow('GPS:', '${e.gpsLat!.toStringAsFixed(5)}, ${e.gpsLng!.toStringAsFixed(5)}'),
              if ((e.notes ?? '').isNotEmpty) ...[
                pw.SizedBox(height: 4),
                pw.Text('Notes:', style: _label()),
                pw.Text(e.notes!, style: _body()),
              ],
            ]),
          );
        }),
      ],
    ));
    return pdf.save();
  }

  // Generate material list PDF
  static Future<Uint8List> generateMaterialPdf({
    required String buildingName,
    required String date,
    required String type, // 'Industrial' or 'Domestic'
    required String content,
  }) async {
    final pdf = pw.Document();
    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(24),
      header: (_) => _header(),
      footer: (ctx) => pw.Container(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey500)),
      ),
      build: (context) => [
        pw.SizedBox(height: 16),
        pw.Text('$type Material List', style: _heading()),
        if (buildingName.isNotEmpty) ...[
          pw.SizedBox(height: 4),
          pw.Text(buildingName, style: _subheading()),
        ],
        pw.SizedBox(height: 4),
        pw.Text('Date: $date', style: _label()),
        _divider(),
        pw.SizedBox(height: 8),
        pw.Text(content, style: _body()),
      ],
    ));
    return pdf.save();
  }
}


// ═══════════════════════════════════════════════════════════════
// Favourites Service
// ═══════════════════════════════════════════════════════════════

class FavouritesService {
  static const String _key = 'favourite_profiles';

  static String _profileKey(ProfileRecord p) => '${p.code}_${p.profileName}_${p.manufacturer}';

  static Future<Set<String>> loadKeys() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? []).toSet();
  }

  static Future<List<ProfileRecord>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> raw = prefs.getStringList('favourite_profiles_data') ?? [];
    return raw.map((s) {
      try { return ProfileRecord.fromJson(json.decode(s) as Map<String, dynamic>); } catch (_) { return null; }
    }).whereType<ProfileRecord>().toList();
  }

  static Future<bool> isFavourite(ProfileRecord p) async {
    final keys = await loadKeys();
    return keys.contains(_profileKey(p));
  }

  static Future<void> add(ProfileRecord p) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = (prefs.getStringList(_key) ?? []).toSet();
    keys.add(_profileKey(p));
    await prefs.setStringList(_key, keys.toList());
    final data = prefs.getStringList('favourite_profiles_data') ?? [];
    if (!data.any((s) => s.contains(p.profileName))) {
      data.add(json.encode(p.toJson()));
      await prefs.setStringList('favourite_profiles_data', data);
    }
  }

  static Future<void> remove(ProfileRecord p) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = (prefs.getStringList(_key) ?? []).toSet();
    keys.remove(_profileKey(p));
    await prefs.setStringList(_key, keys.toList());
    final data = prefs.getStringList('favourite_profiles_data') ?? [];
    data.removeWhere((s) => s.contains(p.profileName) && s.contains(p.manufacturer));
    await prefs.setStringList('favourite_profiles_data', data);
  }

  static Future<int> count() async {
    final keys = await loadKeys();
    return keys.length;
  }
}


// ═══════════════════════════════════════════════════════════════
// Rafter Save Service
// ═══════════════════════════════════════════════════════════════

class RafterSaveService {
  static const String _key = 'saved_rafter_calculations';

  static Future<List<Map<String, dynamic>>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    return raw.map((s) {
      try { return json.decode(s) as Map<String, dynamic>; } catch (_) { return null; }
    }).whereType<Map<String, dynamic>>().toList();
  }

  static Future<void> save(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    raw.insert(0, json.encode(data));
    await prefs.setStringList(_key, raw);
  }

  static Future<void> delete(int index) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    if (index >= 0 && index < raw.length) raw.removeAt(index);
    await prefs.setStringList(_key, raw);
  }

  static Future<String> exportBackup() async {
    final all = await loadAll();
    return json.encode({'version': 1, 'exportedAt': DateTime.now().toIso8601String(), 'rafterCalculations': all});
  }

  static Future<int> importBackup(String jsonStr) async {
    final Map<String, dynamic> data = json.decode(jsonStr) as Map<String, dynamic>;
    final List<dynamic> calcs = data['rafterCalculations'] as List<dynamic>? ?? [];
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_key) ?? [];
    int count = 0;
    for (final c in calcs) {
      existing.add(json.encode(c));
      count++;
    }
    await prefs.setStringList(_key, existing);
    return count;
  }
}

// ═══════════════════════════════════════════════════════════════
// Auth Service
// ═══════════════════════════════════════════════════════════════

class AuthService {
  static FirebaseAuth get _auth => FirebaseAuth.instance;
  static FirebaseFirestore get _db => FirebaseFirestore.instance;

  static User? get currentUser => _auth.currentUser;
  static Stream<User?> get authStateChanges => _auth.authStateChanges();
  static bool get isLoggedIn => _auth.currentUser != null;
  static String? get userEmail => _auth.currentUser?.email;
  static String? get displayName => _auth.currentUser?.displayName;

  // Email/password register
  static Future<UserCredential> registerWithEmail(String email, String password, String name) async {
    final cred = await _auth.createUserWithEmailAndPassword(email: email, password: password);
    await cred.user?.updateDisplayName(name);
    // Fire and forget - don't block on Firestore write
    unawaited(_saveUserProfile(cred.user!, name, email));
    return cred;
  }

  // Email/password login
  static Future<UserCredential> loginWithEmail(String email, String password) async {
    return await _auth.signInWithEmailAndPassword(email: email, password: password);
  }

  // Google sign in
  static Future<UserCredential?> signInWithGoogle() async {
    final googleUser = await GoogleSignIn(
      clientId: Platform.isIOS
        ? '899172571973-b5lc827jfa1fr5r01hiv1v69h9gmm0jv.apps.googleusercontent.com'
        : null,
      serverClientId: '899172571973-m520kbun1o8aup8f0f1brqdbcq0i9s3c.apps.googleusercontent.com',
    ).signIn();
    if (googleUser == null) return null;
    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    final cred = await _auth.signInWithCredential(credential);
    // Fire and forget - don't block on Firestore write
    unawaited(_saveUserProfile(cred.user!, cred.user!.displayName ?? '', cred.user!.email ?? ''));
    return cred;
  }

  // Apple sign in
  static Future<UserCredential?> signInWithApple() async {
    final appleCredential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );
    final oauthCredential = OAuthProvider('apple.com').credential(
      idToken: appleCredential.identityToken,
      accessToken: appleCredential.authorizationCode,
    );
    final cred = await _auth.signInWithCredential(oauthCredential);
    // Apple only sends name on first sign in — save it if we got it
    final fullName = [
      appleCredential.givenName,
      appleCredential.familyName,
    ].where((s) => s != null && s.isNotEmpty).join(' ');
    if (fullName.isNotEmpty) {
      await cred.user?.updateDisplayName(fullName);
    }
    unawaited(_saveUserProfile(
      cred.user!,
      cred.user!.displayName ?? fullName,
      cred.user!.email ?? appleCredential.email ?? '',
    ));
    return cred;
  }

  // Save user profile to Firestore
  static Future<void> _saveUserProfile(User user, String name, String email) async {
    await _db.collection('users').doc(user.uid).set({
      'name': name,
      'email': email,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // Sign out
  static Future<void> signOut() async {
    await GoogleSignIn().signOut();
    await _auth.signOut();
  }

  // Sync history to cloud
  static Future<void> syncHistoryToCloud(List<HistoryEntry> history) async {
    if (!isLoggedIn) return;
    final uid = currentUser!.uid;
    final batch = _db.batch();
    final col = _db.collection('users').doc(uid).collection('history');
    for (int i = 0; i < history.length; i++) {
      final data = history[i].toJson();
      // Add a numeric sort key so we can order correctly on restore
      data['sortIndex'] = i;
      final ref = col.doc('entry_$i');
      batch.set(ref, data);
    }
    await batch.commit();
  }

  // Load history from cloud
  static Future<List<HistoryEntry>> loadHistoryFromCloud() async {
    if (!isLoggedIn) return [];
    final uid = currentUser!.uid;
    // Order by sortIndex so we get them back in the right order
    final snap = await _db.collection('users').doc(uid).collection('history').orderBy('sortIndex').get();
    final List<HistoryEntry> results = [];
    for (final doc in snap.docs) {
      try { results.add(HistoryEntry.fromJson(doc.data())); } catch (_) {}
    }
    return results;
  }
}

// ═══════════════════════════════════════════════════════════════
// Tool Usage Service — tracks most used tools
// ═══════════════════════════════════════════════════════════════

class ToolUsageService {
  static const String _key = 'tool_usage_counts';

  // Tool IDs and their display info
  static const Map<String, Map<String, dynamic>> toolInfo = {
    'pitch':     {'label': 'Pitch Finder',  'icon': Icons.architecture,  'color': 0xFF1565C0},
    'material':  {'label': 'Material List', 'icon': Icons.list_alt,       'color': 0xFF2E7D32},
    'area':      {'label': 'Area Calc',     'icon': Icons.calculate,      'color': 0xFF00695C},
    'rafter':    {'label': 'Rafter Calc',   'icon': Icons.straighten,     'color': 0xFF4E342E},
    'perimeter': {'label': 'Perimeter',     'icon': Icons.crop_free,      'color': 0xFF283593},
    'siteStops': {'label': 'Site Stops',    'icon': Icons.storefront,     'color': 0xFF6D4C41},
    'torch':     {'label': 'Torch',         'icon': Icons.flashlight_on,  'color': 0xFFF57F17},
  };

  static Future<void> recordUsage(String toolId) async {
    final prefs = await SharedPreferences.getInstance();
    final Map<String, dynamic> counts = jsonDecode(prefs.getString(_key) ?? '{}') as Map<String, dynamic>;
    counts[toolId] = (counts[toolId] as int? ?? 0) + 1;
    await prefs.setString(_key, jsonEncode(counts));
  }

  static Future<List<String>> getMostUsed({int limit = 3}) async {
    final prefs = await SharedPreferences.getInstance();
    final Map<String, dynamic> counts = jsonDecode(prefs.getString(_key) ?? '{}') as Map<String, dynamic>;
    final sorted = counts.entries.toList()..sort((a, b) => (b.value as int).compareTo(a.value as int));
    return sorted.take(limit).map((e) => e.key).toList();
  }
}

// ═══════════════════════════════════════════════════════════════
// Material List Service — save/load/delete material lists
// ═══════════════════════════════════════════════════════════════

class MaterialListService {
  static const String _key = 'saved_material_lists';

  static Future<List<Map<String, dynamic>>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> raw = prefs.getStringList(_key) ?? [];
    return raw.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
  }

  static Future<void> save(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> raw = prefs.getStringList(_key) ?? [];
    raw.insert(0, jsonEncode(data));
    await prefs.setStringList(_key, raw);
  }

  static Future<void> delete(int index) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> raw = prefs.getStringList(_key) ?? [];
    if (index >= 0 && index < raw.length) {
      raw.removeAt(index);
      await prefs.setStringList(_key, raw);
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// Profile Photo Service — Firestore-backed approved photo URLs
// ═══════════════════════════════════════════════════════════════

class ProfilePhotoService {
  // In-memory cache so we only hit Firestore once per app session.
  static Map<String, String>? _cache; // docKey → photoUrl

  /// Normalise profileName + manufacturer to the same key the Cloud Function
  /// writes. Both sides must use identical logic.
  static String keyFor(String profileName, String manufacturer) =>
    '${profileName.trim()}_${manufacturer.trim()}'
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  /// Fetch all approved photo URLs from Firestore (cached for the session).
  static Future<Map<String, String>> fetchAll() async {
    if (_cache != null) return _cache!;
    try {
      final snap = await FirebaseFirestore.instance
        .collection('profile_photos')
        .get();
      _cache = {
        for (final doc in snap.docs)
          if (doc.data()['photoUrl'] is String)
            doc.id: doc.data()['photoUrl'] as String,
      };
    } catch (e) {
      debugPrint('ProfilePhotoService: fetch failed – $e');
      _cache = {};
    }
    return _cache!;
  }

  /// Call after approving a correction so the next category load picks up
  /// the new photo without requiring an app restart.
  static void invalidate() => _cache = null;

  /// Overlay Firestore-approved photoUrls onto a list of ProfileRecords.
  /// Profiles that already have a photoUrl (baked into JSON) are left unchanged.
  static Future<List<ProfileRecord>> applyTo(List<ProfileRecord> profiles) async {
    final photoMap = await fetchAll();
    if (photoMap.isEmpty) return profiles;
    return profiles.map((p) {
      if (p.photoUrl != null) return p;
      final url = photoMap[keyFor(p.profileName, p.manufacturer)];
      return url != null ? p.copyWith(photoUrl: url) : p;
    }).toList();
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
  final String? photoUrl;

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
    required this.notes, required this.imageFile, this.photoUrl,
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
    'imageFile': imageFile, 'photoUrl': photoUrl,
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
      photoUrl: json['photo_url']?.toString() ?? json['photoUrl']?.toString(),
    );
  }

  ProfileRecord copyWith({String? photoUrl}) => ProfileRecord(
    code: code, profileName: profileName, manufacturer: manufacturer,
    shape: shape, pitch: pitch, depth: depth, crown: crown, trough: trough,
    coverWidth: coverWidth, overallWidth: overallWidth, category: category,
    brand: brand, material: material, materialGroup: materialGroup,
    tileType: tileType, profile: profile, profileGroup: profileGroup,
    fixingType: fixingType, aliases: aliases, nominalLengthMm: nominalLengthMm,
    nominalWidthMm: nominalWidthMm, gaugeMinMm: gaugeMinMm, gaugeMaxMm: gaugeMaxMm,
    minimumPitchDegMin: minimumPitchDegMin, coveragePerSqm: coveragePerSqm,
    weightKgPerSqm: weightKgPerSqm, overallSizeText: overallSizeText,
    coverWidthText: coverWidthText, gaugeText: gaugeText,
    minimumPitchText: minimumPitchText, coverageText: coverageText,
    weightText: weightText, sourceUrl: sourceUrl, notes: notes, imageFile: imageFile,
    photoUrl: photoUrl ?? this.photoUrl,
  );

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

class _HomeHubEntry {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _HomeHubEntry({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
}

// ═══════════════════════════════════════════════════════════════
// Profile Search Screen
// ═══════════════════════════════════════════════════════════════

class ProfileSearchScreen extends StatefulWidget {
  final bool homeHubMode;
  final String initialCategory;
  final List<String> allowedCategories;
  final String screenTitle;

  const ProfileSearchScreen({
    super.key,
    this.homeHubMode = false,
    this.initialCategory = 'steel',
    this.allowedCategories = const ['steel', 'cement', 'composite', 'tile'],
    this.screenTitle = 'Profile Finder',
  });

  @override
  State<ProfileSearchScreen> createState() => _ProfileSearchScreenState();
}

class _ProfileSearchScreenState extends State<ProfileSearchScreen> {
  int _logoTapCount = 0;
  DateTime? _lastLogoTap;
  final TextEditingController _profileSearchController = TextEditingController();
  List<String> _mostUsedTools = [];
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
  final Set<String> _activeSheetFilters = {'steel', 'cement', 'composite'};
  double _toleranceMultiplier = 1.0;
  String? _selectedTileMaterial;
  String? _selectedTileType;
  String? _selectedTileProfileFamily;
  List<String> _tileMaterials = [];
  List<String> _tileTypes = [];
  List<String> _tileProfileFamilies = [];

  static const Map<String, String> _fileMap = {
    'steel':     'assets/data/steel_profiles.json',
    'cement':    'assets/data/cement_profiles.json',
    'composite': 'assets/data/steel_profiles.json',
    'tile':      'assets/data/tile_profiles_uk_phase2.json',
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
  StreamSubscription<dynamic>? _authSub;
  final ScrollController _homeHubScrollController = ScrollController();
  DateTime? _lastHubHapticAt;
  double? _lastHubFeedbackOffset;
  AudioPool? _hubClickPool;

  @override
  void initState() {
    super.initState();
    _selectedCategory = widget.allowedCategories.contains(widget.initialCategory)
        ? widget.initialCategory
        : (widget.allowedCategories.isNotEmpty ? widget.allowedCategories.first : 'steel');
    if (_selectedCategory == 'tile') {
      _loadProfilesForCategory('tile');
    } else {
      unawaited(_reloadSheetProfiles());
    }
    _profileSearchController.addListener(_updateNameSuggestions);
    _loadMostUsed();
    unawaited(_prepareHubFeedback());
    _authSub = AuthService.authStateChanges.listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadMostUsed() async {
    final tools = await ToolUsageService.getMostUsed();
    if (mounted) setState(() { _mostUsedTools = tools; });
  }

  Future<void> _prepareHubFeedback() async {
    try {
      _hubClickPool = await AudioPool.createFromAsset(
        path: 'audio/scroll_tick.wav',
        maxPlayers: 2,
        minPlayers: 1,
        playerMode: PlayerMode.lowLatency,
      );
    } catch (_) {
      _hubClickPool = null;
    }
  }

  Future<void> _playTapClick() async {
    try {
      await _hubClickPool?.start(volume: 0.28);
      return;
    } catch (_) {}
    try {
      await SystemSound.play(SystemSoundType.click);
    } catch (_) {}
  }

  Future<void> _playHubScrollFeedback() async {
    try {
      final hasVibrator = await Vibration.hasVibrator() ?? false;
      if (hasVibrator) {
        final hasAmplitude = await Vibration.hasAmplitudeControl() ?? false;
        await Vibration.vibrate(duration: 10, amplitude: hasAmplitude ? 35 : -1);
        return;
      }
    } catch (_) {}

    try {
      HapticFeedback.selectionClick();
    } catch (_) {}
  }

  Future<void> _openTool(String toolId) async {
    await ToolUsageService.recordUsage(toolId);
    if (!mounted) return;
    final Widget screen;
    switch (toolId) {
      case 'pitch':     screen = const PitchAngleScreen(); break;
      case 'material':  screen = const MaterialListScreen(); break;
      case 'area':      screen = const RoofAreaCalculator(); break;
      case 'rafter':    screen = const RafterCalculator(); break;
      case 'perimeter': screen = const PerimeterAreaTool(); break;
      case 'siteStops': screen = const SiteStopsScreen(); break;
      case 'torch':     screen = const TorchScreen(); break;
      default: return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    _loadMostUsed(); // refresh after returning
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _profileSearchController.removeListener(_updateNameSuggestions);
    _profileSearchController.dispose();
    _pitchController.dispose(); _depthController.dispose();
    _crownController.dispose(); _troughController.dispose();
    _coverWidthController.dispose(); _overallWidthController.dispose();
    _tileLengthController.dispose(); _tileWidthController.dispose();
    _tileGaugeController.dispose(); _tileMinPitchController.dispose();
    _tileCoverageController.dispose();
    _homeHubScrollController.dispose();
    unawaited(_hubClickPool?.dispose() ?? Future<void>.value());
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
        'subject': 'Roof Profile Finder - Suggest / Add Profile',
        'body': 'Hi,\n\nI would like to suggest a missing roof profile.\n\nType: \nManufacturer: \nProfile name/code: \nMeasurements: \nNotes: \n\nThank you.',
      });
    if (!await launchUrl(emailUri, mode: LaunchMode.externalApplication) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open email app.')));
    }
  }

  Future<void> _showAboutDialogBox() async {
    await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('About Roof Profile & Tile Finder'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Roof Profile & Tile Finder was created to help roofers identify roof profile sheets, tiles and slates quickly and accurately on site.'),
        const SizedBox(height: 8),
        const Text('This is my first app and my first experience of coding. I work as a roofer, and I built it to help solve a real problem on site.'),
        const SizedBox(height: 8),
        const Text('Use the search fields, filters and measurements to narrow down likely matches, then review them on the dedicated results screen.'),
        const SizedBox(height: 8),
        const SizedBox(height: 8),
        const Text('Features:', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text(
          '🔍  700+ steel, cement and tile profiles\n'
          '📐  Roof Pitch Finder\n'
          '📋  Material List — Industrial & Domestic\n'
          '📏  Roof Area Calculator\n'
          '📐  Rafter Calculator\n'
          '🏗️  Perimeter Area Tool\n'
          '☕  Site Stops nearby finder\n'
          '🔦  Torch\n'
          '📍  GPS location saving with map view\n'
          '📄  PDF export\n'
          '☁️  Cloud backup & sync\n'
          '💾  Save & restore material lists',
          style: TextStyle(height: 1.8, fontSize: 12)),
        const SizedBox(height: 8),
        const Text('I will continue improving the database. If you notice a missing profile please use the suggest option in the menu.'),
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

  Future<void> _openAccountFromHeader() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const AccountScreen()),
    );
    if (result == true && mounted) setState(() {});
  }

  Widget _headerCircleButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    Color iconColor = Colors.white,
  }) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.14),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withOpacity(0.22)),
      ),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        icon: Icon(icon, size: 20, color: iconColor),
      ),
    );
  }

  List<String> get _availableCategories =>
      widget.allowedCategories.isEmpty ? const ['steel', 'cement', 'tile'] : widget.allowedCategories;

  String _categoryLabelFor(String category) {
    switch (category) {
      case 'steel':
        return 'Steel Sheets';
      case 'cement':
        return 'Cement Sheets';
      case 'composite':
        return 'Composite / Liner';
      case 'tile':
        return 'Tiles / Slates';
      default:
        return 'Profiles';
    }
  }

  IconData _categoryIconFor(String category) {
    switch (category) {
      case 'cement':
        return Icons.layers;
      case 'tile':
        return Icons.home;
      case 'composite':
        return Icons.layers_outlined;
      case 'steel':
      default:
        return Icons.factory_outlined;
    }
  }

  Color _categoryColorFor(String category) {
    switch (category) {
      case 'cement':
        return Colors.grey.shade700;
      case 'tile':
        return Colors.orange.shade700;
      case 'composite':
        return Colors.purple.shade700;
      case 'steel':
      default:
        return Colors.blue.shade700;
    }
  }

  PopupMenuItem<String> _categoryMenuItem(String category) {
    return PopupMenuItem<String>(
      value: category,
      child: Row(
        children: [
          Icon(_categoryIconFor(category), color: _categoryColorFor(category), size: 20),
          const SizedBox(width: 10),
          Text(_categoryLabelFor(category)),
        ],
      ),
    );
  }

  Widget _buildCategorySelector() {
    final categories = _availableCategories;
    // For tile-only screens keep original compact selector
    if (categories.length == 1) {
      return Row(children: [
        Text('Category:', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(width: 12),
        Chip(
          avatar: Icon(_categoryIconFor(categories.first), color: Colors.white, size: 16),
          label: Text(_categoryLabelFor(categories.first), style: const TextStyle(color: Colors.white, fontSize: 13)),
          backgroundColor: _categoryColorFor(categories.first),
        ),
      ]);
    }

    // Sheet screens: show toggle filter buttons
    final sheetCats = categories.where((c) => c != 'tile').toList();
    if (sheetCats.isEmpty) return const SizedBox.shrink();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Material type:', style: TextStyle(fontSize: 13, color: Colors.black54)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 6, children: sheetCats.map((cat) {
        final active = _activeSheetFilters.contains(cat);
        final color = _categoryColorFor(cat);
        return GestureDetector(
          onTap: () {
            setState(() {
              if (active && _activeSheetFilters.length == 1) return; // keep at least one
              if (active) {
                _activeSheetFilters.remove(cat);
              } else {
                _activeSheetFilters.add(cat);
              }
            });
            _reloadSheetProfiles();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: active ? color : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color, width: 1.5),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(_categoryIconFor(cat), color: active ? Colors.white : color, size: 16),
              const SizedBox(width: 6),
              Text(_categoryLabelFor(cat),
                style: TextStyle(
                  color: active ? Colors.white : color,
                  fontSize: 13, fontWeight: FontWeight.w600)),
              if (active) ...[
                const SizedBox(width: 4),
                Icon(Icons.check, color: Colors.white, size: 14),
              ],
            ]),
          ),
        );
      }).toList()),
    ]);
  }

  Future<void> _reloadSheetProfiles() async {
    setState(() { _loading = true; _nameSuggestions = []; });
    try {
      List<ProfileRecord> all = [];
      for (final cat in _activeSheetFilters) {
        final file = _fileMap[cat];
        if (file == null) continue;
        final String jsonString = await rootBundle.loadString(file);
        final List<dynamic> decoded = json.decode(jsonString) as List<dynamic>;
        final List<ProfileRecord> loaded = decoded
          .map((e) => ProfileRecord.fromJson(e as Map<String, dynamic>))
          .where((p) {
            if (cat == 'steel') return (p.materialGroup ?? '').toLowerCase() != 'composite';
            if (cat == 'composite') return (p.materialGroup ?? '').toLowerCase() == 'composite';
            return true; // cement - load all
          }).toList();
        all.addAll(loaded);
      }
      // Overlay any Firestore-approved community photos
      all = await ProfilePhotoService.applyTo(all);
      setState(() {
        _profiles = all;
        _loading = false;
      });
    } catch (e) {
      setState(() { _profiles = []; _loading = false; });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load profiles: $e')));
    }
  }

  Widget _buildQuickActionsRow({required bool insideHeader}) {
    final chips = [
      _quickChip(Icons.history, 'History', const Color(0xFF283593),
        () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HistoryScreen()))),
      _quickChip(Icons.save, 'Saved Lists', const Color(0xFF2E7D32),
        () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const _SavedListsScreen()))),
      _quickChip(Icons.star, 'Favorites', const Color(0xFFE65100), () => _handleTopMenu('favourites')),
    ];

    final row = SizedBox(
      height: 42,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: chips,
      ),
    );

    if (insideHeader) return row;

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 2),
      child: row,
    );
  }

  List<_HomeHubEntry> _buildHomeHubEntries() {
    return [
      _HomeHubEntry(
        icon: Icons.search,
        color: Colors.blue.shade700,
        title: '1. Profile Finder',
        subtitle: 'Search steel and cement roof sheets by name or measurements.',
        onTap: () async {
          await _playTapClick();
          if (!mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const ProfileSearchScreen(
                initialCategory: 'steel',
                allowedCategories: ['steel', 'cement', 'composite'],
                screenTitle: 'Profile Finder',
              ),
            ),
          );
        },
      ),
      _HomeHubEntry(
        icon: Icons.roofing,
        color: Colors.orange.shade700,
        title: '2. Tile Identifier',
        subtitle: 'Identify roof tiles and slates by name, type, filters and measurements.',
        onTap: () async {
          await _playTapClick();
          if (!mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const ProfileSearchScreen(
                initialCategory: 'tile',
                allowedCategories: ['tile'],
                screenTitle: 'Tile Identifier',
              ),
            ),
          );
        },
      ),
      _HomeHubEntry(
        icon: Icons.architecture,
        color: Colors.blue.shade700,
        title: '3. Roof Pitch Finder',
        subtitle: 'Use your phone to measure roof pitch in degrees and ratio.',
        onTap: () async {
          await _playTapClick();
          if (!mounted) return;
          await _openTool('pitch');
        },
      ),
      _HomeHubEntry(
        icon: Icons.list_alt,
        color: Colors.green.shade700,
        title: '4. Material List',
        subtitle: 'Build a material takeoff list for any roofing job.',
        onTap: () async {
          await _playTapClick();
          if (!mounted) return;
          await _openTool('material');
        },
      ),
      _HomeHubEntry(
        icon: Icons.straighten,
        color: Colors.brown.shade600,
        title: '5. Rafter Calculation Tool',
        subtitle: 'Calculate rafter lengths, ridge height and cut details.',
        onTap: () async {
          await _playTapClick();
          if (!mounted) return;
          await _openTool('rafter');
        },
      ),
      _HomeHubEntry(
        icon: Icons.calculate,
        color: Colors.teal.shade700,
        title: '6. Roof Area Calculator',
        subtitle: 'Calculate roof area from length, width and pitch.',
        onTap: () async {
          await _playTapClick();
          if (!mounted) return;
          await _openTool('area');
        },
      ),
      _HomeHubEntry(
        icon: Icons.crop_free,
        color: Colors.indigo.shade700,
        title: '7. Perimeter Roof Calculation',
        subtitle: 'Sketch a building outline and work out the roof area.',
        onTap: () async {
          await _playTapClick();
          if (!mounted) return;
          await _openTool('perimeter');
        },
      ),
      _HomeHubEntry(
        icon: Icons.storefront,
        color: Colors.brown.shade600,
        title: '8. Site Stops',
        subtitle: 'Find nearby cafés, food stops and trade counters, then open directions.',
        onTap: () async {
          await _playTapClick();
          if (!mounted) return;
          await _openTool('siteStops');
        },
      ),
      _HomeHubEntry(
        icon: Icons.flashlight_on,
        color: Colors.amber.shade700,
        title: '9. Torch',
        subtitle: 'Use your phone torch in dark roof spaces.',
        onTap: () async {
          await _playTapClick();
          if (!mounted) return;
          await _openTool('torch');
        },
      ),
    ];
  }

  Widget _buildHomeHubTile(_HomeHubEntry item) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          leading: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: item.color, borderRadius: BorderRadius.circular(10)),
            child: Icon(item.icon, color: Colors.white, size: 28),
          ),
          title: Text(item.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          subtitle: Text(item.subtitle),
          trailing: const Icon(Icons.arrow_forward_ios, size: 16),
          onTap: item.onTap,
        ),
      ),
    );
  }

  Widget _quickChip(IconData icon, String label, Color color, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () async {
          await _playTapClick();
          if (!mounted) return;
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: color.withOpacity(0.85),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }

  Future<void> _goHomeHub() async {
    if (widget.homeHubMode) {
      if (_homeHubScrollController.hasClients) {
        await _homeHubScrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const ProfileSearchScreen(homeHubMode: true)),
      (route) => false,
    );
  }

  void _handleAdminTap() {
    final now = DateTime.now();
    if (_lastLogoTap != null && now.difference(_lastLogoTap!).inSeconds > 3) {
      _logoTapCount = 0;
    }
    _lastLogoTap = now;
    _logoTapCount++;
    if (_logoTapCount >= 5) {
      _logoTapCount = 0;
      _showAdminPinDialog();
    }
  }

  Future<void> _showAdminPinDialog() async {
    final pinController = TextEditingController();
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Row(children: [Icon(Icons.admin_panel_settings, color: Colors.blue), SizedBox(width: 8), Text('Admin Access')]),
      content: TextField(
        controller: pinController,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 6,
        decoration: const InputDecoration(hintText: 'Enter PIN', border: OutlineInputBorder()),
        autofocus: true,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white),
          child: const Text('Enter')),
      ],
    ));
    if (confirm != true) return;
    if (pinController.text.trim() == '7950') {
      if (mounted) Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AdminScreen()));
    } else {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Incorrect PIN'), backgroundColor: Colors.red));
    }
  }

  void _handleTopMenu(String value) {
    switch (value) {
      case 'tools': Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ToolsScreen())); break;
      case 'help': Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HowToUseScreen())); break;
      case 'favourites': Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FavouritesScreen())); break;
      case 'history': Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HistoryScreen())); break;
      case 'savedlists': Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const _SavedListsScreen())); break;
      case 'about': _showAboutDialogBox(); break;
      case 'suggest': _showSuggestProfileDialog(); break;
      case 'backup': _backupAllData(); break;
      case 'restore': _restoreAllData(); break;
    }
  }

  Future<void> _backupAllData() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> matLists = prefs.getStringList('saved_material_lists') ?? [];

    if (AuthService.isLoggedIn) {
      // Logged in — backup everything to Firestore
      try {
        final history = await HistoryService.loadHistory();
        await AuthService.syncHistoryToCloud(history);
        // Save material lists to Firestore
        final uid = AuthService.currentUser!.uid;
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          'materialLists': matLists,
          'backupAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('✓ ${history.length} history entries + material lists backed up to cloud!'),
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 3),
        ));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Cloud backup failed: $e'), backgroundColor: Colors.red));
      }
    } else {
      // Not logged in — share JSON file
      try {
        final String historyBackup = await HistoryService.exportBackup();
        final Map<String, dynamic> fullBackup = {
          'version': 2,
          'exportedAt': DateTime.now().toIso8601String(),
          'history': historyBackup,
          'materialLists': matLists,
        };
        final String filename = 'roof_finder_backup_${DateTime.now().millisecondsSinceEpoch}.json';
        await Share.shareXFiles(
          [XFile.fromData(utf8.encode(jsonEncode(fullBackup)), name: filename, mimeType: 'application/json')],
          subject: 'Roof Profile Finder — Full Backup',
          text: 'Sign in to back up to the cloud automatically!',
          sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
        );
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Backup failed: $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _restoreAllData() async {
    // If logged in, offer cloud restore first
    if (AuthService.isLoggedIn) {
      final choice = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
        title: const Row(children: [Icon(Icons.restore, color: Colors.blue), SizedBox(width: 8), Text('Restore Data')]),
        content: const Text('How would you like to restore?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Cancel')),
          OutlinedButton.icon(onPressed: () => Navigator.pop(ctx, 'paste'), icon: const Icon(Icons.paste), label: const Text('Paste JSON')),
          ElevatedButton.icon(onPressed: () => Navigator.pop(ctx, 'cloud'),
            icon: const Icon(Icons.cloud_download),
            label: const Text('From Cloud'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white)),
        ],
      ));
      if (choice == 'cloud') {
        try {
          final cloudHistory = await AuthService.loadHistoryFromCloud();
          // Restore material lists from Firestore
          final uid = AuthService.currentUser!.uid;
          final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
          final mats = doc.data()?['materialLists'] as List<dynamic>? ?? [];
          for (final entry in cloudHistory.reversed) { await HistoryService.saveEntry(entry); }
          if (mats.isNotEmpty) {
            final prefs = await SharedPreferences.getInstance();
            final existing = prefs.getStringList('saved_material_lists') ?? [];
            for (final m in mats) { if (!existing.contains(m.toString())) existing.add(m.toString()); }
            await prefs.setStringList('saved_material_lists', existing);
          }
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('✓ Restored ${cloudHistory.length} entries + material lists!'),
            backgroundColor: Colors.green));
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cloud restore failed: \$e'), backgroundColor: Colors.red));
        }
        return;
      }
      if (choice != 'paste') return;
    }

    final TextEditingController pasteController = TextEditingController();
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Row(children: [Icon(Icons.restore, color: Colors.blue), SizedBox(width: 8), Text('Restore All Data')]),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Paste your backup JSON below to restore history and material lists:'),
        const SizedBox(height: 12),
        TextField(controller: pasteController, maxLines: 5,
          decoration: const InputDecoration(hintText: 'Paste backup JSON here...', border: OutlineInputBorder())),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white),
          child: const Text('Restore')),
      ],
    ));
    if (confirm != true || pasteController.text.trim().isEmpty) return;
    try {
      final Map<String, dynamic> backup = jsonDecode(pasteController.text.trim()) as Map<String, dynamic>;
      int restored = 0;
      // Restore history
      if (backup['history'] != null) {
        restored += await HistoryService.importBackup(backup['history'] as String);
      }
      // Restore material lists
      if (backup['materialLists'] != null) {
        final prefs = await SharedPreferences.getInstance();
        final List<dynamic> mats = backup['materialLists'] as List<dynamic>;
        final existing = prefs.getStringList('saved_material_lists') ?? [];
        for (final m in mats) { if (!existing.contains(m.toString())) existing.add(m.toString()); }
        await prefs.setStringList('saved_material_lists', existing);
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('✓ Restored $restored history entries + material lists!'),
        backgroundColor: Colors.green));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Restore failed: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _loadProfilesForCategory(String category) async {
    setState(() { _loading = true; _nameSuggestions = []; });
    _clearSearchInputs(silent: true);
    try {
      final String jsonString = await rootBundle.loadString(_fileMap[category]!);
      final List<dynamic> decoded = json.decode(jsonString) as List<dynamic>;
      List<ProfileRecord> loaded = decoded.map((e) => ProfileRecord.fromJson(e as Map<String, dynamic>)).toList();
      // Filter composite vs steel from same JSON
      if (category == 'steel') {
        loaded = loaded.where((p) => (p.materialGroup ?? '').toLowerCase() != 'composite').toList();
      } else if (category == 'composite') {
        loaded = loaded.where((p) => (p.materialGroup ?? '').toLowerCase() == 'composite').toList();
      }
      // Overlay any Firestore-approved community photos
      loaded = await ProfilePhotoService.applyTo(loaded);
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

  void _maybeTriggerHubScrollFeedback(double pixels) {
    final now = DateTime.now();
    if (_lastHubFeedbackOffset == null) {
      _lastHubFeedbackOffset = pixels;
      return;
    }

    final distance = (pixels - _lastHubFeedbackOffset!).abs();
    if (distance < 14) return;
    if (_lastHubHapticAt != null && now.difference(_lastHubHapticAt!) < const Duration(milliseconds: 85)) {
      return;
    }

    _lastHubFeedbackOffset = pixels;
    _lastHubHapticAt = now;
    unawaited(_playHubScrollFeedback());
  }

  Widget _buildFinderFormBody() {
    return _loading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                  children: [
                    const SizedBox(height: 8),
                    _buildCategorySelector(),
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
                    const SizedBox(height: 80),
                  ],
                ),
              ),
            ],
          );
  }

  Widget _hubCard({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          leading: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
          title: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.arrow_forward_ios, size: 16),
          onTap: onTap,
        ),
      ),
    );
  }

  Widget _buildHomeHubBody() {
    final items = _buildHomeHubEntries();
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification && notification.dragDetails != null) {
          _lastHubFeedbackOffset = notification.metrics.pixels;
        } else if (notification is ScrollUpdateNotification && notification.dragDetails != null) {
          _maybeTriggerHubScrollFeedback(notification.metrics.pixels);
        } else if (notification is ScrollEndNotification) {
          _lastHubFeedbackOffset = null;
        }
        return false;
      },
      child: ListView.builder(
        controller: _homeHubScrollController,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return _buildHomeHubTile(item);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.homeHubMode) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.screenTitle),
          backgroundColor: Colors.blue.shade700,
          foregroundColor: Colors.white,
          actions: [
            IconButton(
              tooltip: AuthService.isLoggedIn ? 'Account' : 'Sign In',
              icon: Icon(
                AuthService.isLoggedIn ? Icons.account_circle : Icons.account_circle_outlined,
                color: AuthService.isLoggedIn ? Colors.greenAccent : Colors.white,
              ),
              onPressed: _openAccountFromHeader,
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              onSelected: _handleTopMenu,
              itemBuilder: (context) => [
                const PopupMenuItem<String>(value: 'tools', child: Row(children: [Icon(Icons.build, size: 18), SizedBox(width: 10), Text('Tools')])),
                const PopupMenuItem<String>(value: 'favourites', child: Row(children: [Icon(Icons.star, size: 18, color: Colors.amber), SizedBox(width: 10), Text('Favorites')])),
                const PopupMenuItem<String>(value: 'history', child: Row(children: [Icon(Icons.history, size: 18, color: Color(0xFF283593)), SizedBox(width: 10), Text('History')])),
                const PopupMenuItem<String>(value: 'savedlists', child: Row(children: [Icon(Icons.save, size: 18, color: Color(0xFF2E7D32)), SizedBox(width: 10), Text('Saved Lists')])),
                const PopupMenuItem<String>(value: 'help', child: Row(children: [Icon(Icons.help_outline, size: 18), SizedBox(width: 10), Text('How to measure')])),
                const PopupMenuItem<String>(value: 'backup', child: Row(children: [Icon(Icons.backup, size: 18), SizedBox(width: 10), Text('Backup All Data')])),
                const PopupMenuItem<String>(value: 'restore', child: Row(children: [Icon(Icons.restore, size: 18), SizedBox(width: 10), Text('Restore Backup')])),
                const PopupMenuItem<String>(value: 'about', child: Row(children: [Icon(Icons.info_outline, size: 18), SizedBox(width: 10), Text('About')])),
                const PopupMenuItem<String>(value: 'suggest', child: Row(children: [Icon(Icons.add_circle_outline, size: 18), SizedBox(width: 10), Text('Suggest / Add Profile')])),
              ],
            ),
          ],
        ),
        body: _buildFinderFormBody(),
      );
    }

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(120),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF123B8C), Color(0xFF1E5FC8)],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                SizedBox(
                  height: 108,
                  child: Stack(
                    children: [
                      Align(
                        alignment: Alignment.topLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 10, top: 8),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _headerCircleButton(
                                tooltip: 'Donate',
                                icon: Icons.volunteer_activism,
                                onPressed: _openDonate,
                              ),
                              const SizedBox(height: 8),
                              _headerCircleButton(
                                tooltip: AuthService.isLoggedIn ? 'Account' : 'Sign In',
                                icon: AuthService.isLoggedIn ? Icons.account_circle : Icons.account_circle_outlined,
                                onPressed: _openAccountFromHeader,
                                iconColor: AuthService.isLoggedIn ? Colors.greenAccent : Colors.white,
                              ),
                            ],
                          ),
                        ),
                      ),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 82),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              GestureDetector(
                                onTap: _handleAdminTap,
                                child: Column(children: [
                              const FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  'ROOF PROFILE',
                                  maxLines: 1,
                                  softWrap: false,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              const Text(
                                '& TILE FINDER',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Color(0xFF95EA77),
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                ),
                              ),
                                ])),
                              const SizedBox(height: 8),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  'Identify hundreds of roof sheets, tiles and slates',
                                  maxLines: 1,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.92),
                                    fontSize: 10.2,
                                    height: 1.2,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8, right: 8),
                          child: Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.14),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white.withOpacity(0.22)),
                            ),
                            child: PopupMenuButton<String>(
                              tooltip: 'Menu',
                              onSelected: _handleTopMenu,
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.more_horiz, color: Colors.white),
                              itemBuilder: (context) => [
                                const PopupMenuItem<String>(value: 'tools', child: Row(children: [Icon(Icons.build, size: 18), SizedBox(width: 10), Text('Tools')])),
                                const PopupMenuItem<String>(value: 'favourites', child: Row(children: [Icon(Icons.star, size: 18, color: Colors.amber), SizedBox(width: 10), Text('Favorites')])),
                                const PopupMenuItem<String>(value: 'history', child: Row(children: [Icon(Icons.history, size: 18, color: Color(0xFF283593)), SizedBox(width: 10), Text('History')])),
                                const PopupMenuItem<String>(value: 'savedlists', child: Row(children: [Icon(Icons.save, size: 18, color: Color(0xFF2E7D32)), SizedBox(width: 10), Text('Saved Lists')])),
                                const PopupMenuItem<String>(value: 'help', child: Row(children: [Icon(Icons.help_outline, size: 18), SizedBox(width: 10), Text('How to measure')])),
                                const PopupMenuItem<String>(value: 'backup', child: Row(children: [Icon(Icons.backup, size: 18), SizedBox(width: 10), Text('Backup All Data')])),
                                const PopupMenuItem<String>(value: 'restore', child: Row(children: [Icon(Icons.restore, size: 18), SizedBox(width: 10), Text('Restore Backup')])),
                                const PopupMenuItem<String>(value: 'about', child: Row(children: [Icon(Icons.info_outline, size: 18), SizedBox(width: 10), Text('About')])),
                                const PopupMenuItem<String>(value: 'suggest', child: Row(children: [Icon(Icons.add_circle_outline, size: 18), SizedBox(width: 10), Text('Suggest / Add Profile')])),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          _buildQuickActionsRow(insideHeader: false),
          Expanded(
            child: _buildHomeHubBody(),
          ),
        ],
      ),
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

  Future<void> _exportPdf() async {
    // Let user pick entries
    final Set<int> selected = Set.from(List.generate(_history.length, (i) => i));
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: const Row(children: [Icon(Icons.picture_as_pdf, color: Colors.red), SizedBox(width: 8), Text('Export to PDF')]),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('${selected.length} of ${_history.length} selected', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              TextButton(
                onPressed: () => setS(() => selected.length == _history.length
                  ? selected.clear()
                  : selected.addAll(List.generate(_history.length, (i) => i))),
                child: Text(selected.length == _history.length ? 'Deselect all' : 'Select all'),
              ),
            ]),
            const Divider(),
            Flexible(child: ListView.builder(
              shrinkWrap: true,
              itemCount: _history.length,
              itemBuilder: (ctx, i) {
                final e = _history[i];
                return CheckboxListTile(
                  dense: true,
                  value: selected.contains(i),
                  onChanged: (v) => setS(() => v! ? selected.add(i) : selected.remove(i)),
                  title: Text(e.profile.displayTitle, style: const TextStyle(fontSize: 13)),
                  subtitle: Text('${e.buildingName ?? ''} ${e.formattedDate}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                );
              },
            )),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: selected.isEmpty ? null : () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Export PDF'),
          ),
        ],
      ),
    ));
    if (confirm != true || selected.isEmpty) return;
    try {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Generating PDF...')));
      final selectedHistory = selected.toList()..sort();
      final entries = selectedHistory.map((i) => _history[i]).toList();
      final Uint8List pdfBytes = await PdfService.generateHistoryPdf(entries);
      final String filename = 'roof_history_${DateTime.now().millisecondsSinceEpoch}.pdf';
      await Share.shareXFiles(
        [XFile.fromData(pdfBytes, name: filename, mimeType: 'application/pdf')],
        subject: 'Roof Profile History',
        sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF failed: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _backupHistory() async {
    try {
      final String backup = await HistoryService.exportBackup();
      final String filename = 'roof_profile_backup_${DateTime.now().millisecondsSinceEpoch}.json';
      await Share.shareXFiles(
        [XFile.fromData(utf8.encode(backup), name: filename, mimeType: 'application/json')],
        subject: 'Roof Profile Finder — History Backup',
        text: 'My saved roof profiles backup. To restore, open the app and use Import Backup.',
        sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Backup failed: $e')));
    }
  }

  Future<void> _restoreHistory() async {
    await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      title: const Row(children: [Icon(Icons.restore, color: Colors.blue), SizedBox(width: 8), Text('Restore Backup')]),
      content: const Text(
        'To restore your history:\n\n'
        '1. Find the backup JSON file\n'
        '2. Open it with this app\n\n'
        'Or paste the backup content below:',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ElevatedButton(
          onPressed: () async {
            Navigator.pop(ctx);
            await _pasteRestore();
          },
          style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white),
          child: const Text('Paste & Restore'),
        ),
      ],
    ));
  }

  Future<void> _pasteRestore() async {
    final TextEditingController pasteController = TextEditingController();
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Paste Backup Data'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Open the backup JSON file, copy all the text, then paste it here:'),
        const SizedBox(height: 12),
        TextField(
          controller: pasteController,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'Paste backup JSON here...',
            border: OutlineInputBorder(),
          ),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white),
          child: const Text('Restore'),
        ),
      ],
    ));
    if (confirm != true || pasteController.text.trim().isEmpty) return;
    try {
      final int added = await HistoryService.importBackup(pasteController.text.trim());
      await _loadHistory();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('✓ Restored $added entries!'),
        backgroundColor: Colors.green,
      ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Restore failed: $e'),
        backgroundColor: Colors.red,
      ));
    }
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
              tooltip: 'View on map',
              icon: const Icon(Icons.map),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => RoofMapScreen(history: _history))),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) async {
              switch (value) {
                case 'pdf': _exportPdf(); break;
                case 'backup': _backupHistory(); break;
                case 'restore': _restoreHistory(); break;
                case 'clear':
                  final confirm = await showDialog<bool>(context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Clear History'),
                      content: const Text('Remove all saved profiles?'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
                      ]));
                  if (confirm == true) _clearHistory();
                  break;
              }
            },
            itemBuilder: (context) => [
              if (_history.isNotEmpty)
                const PopupMenuItem(value: 'pdf', child: Row(children: [Icon(Icons.picture_as_pdf, size: 18, color: Colors.red), SizedBox(width: 10), Text('Export as PDF')])),
              const PopupMenuItem(value: 'backup', child: Row(children: [Icon(Icons.backup, size: 18), SizedBox(width: 10), Text('Backup History')])),
              const PopupMenuItem(value: 'restore', child: Row(children: [Icon(Icons.restore, size: 18), SizedBox(width: 10), Text('Restore Backup')])),
              if (_history.isNotEmpty)
                const PopupMenuItem(value: 'clear', child: Row(children: [Icon(Icons.delete_outline, size: 18, color: Colors.red), SizedBox(width: 10), Text('Clear History', style: TextStyle(color: Colors.red))])),
            ],
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
              : Column(children: [
                  Container(
                    width: double.infinity,
                    color: Colors.grey.shade100,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(children: [
                      Icon(Icons.swipe_left, size: 16, color: Colors.grey.shade500),
                      const SizedBox(width: 6),
                      Text('Swipe left on an entry to delete it', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                    ]),
                  ),
                  Expanded(child: ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _history.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final HistoryEntry entry = _history[index];
                    final ProfileRecord p = entry.profile;
                    return Dismissible(
                      key: Key('${entry.savedAt.millisecondsSinceEpoch}_$index'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        color: Colors.red.shade400,
                        child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.delete, color: Colors.white, size: 28),
                          Text('Delete', style: TextStyle(color: Colors.white, fontSize: 12)),
                        ]),
                      ),
                      confirmDismiss: (direction) async {
                        return await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Delete Entry'),
                            content: Text('Remove ${p.displayTitle} from history?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
                            ],
                          ),
                        );
                      },
                      onDismissed: (direction) async {
                        await HistoryService.deleteEntry(index);
                        setState(() { _history.removeAt(index); });
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Entry deleted'), duration: Duration(seconds: 1)));
                      },
                      child: ListTile(
                      leading: p.imageFile != null
                          ? ClipRRect(borderRadius: BorderRadius.circular(6),
                              child: Image.asset(p.imageFile!, width: 48, height: 48, fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) => const Icon(Icons.roofing, size: 48, color: Colors.blue)))
                          : const Icon(Icons.roofing, size: 48, color: Colors.blue),
                      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(p.displayTitle, style: const TextStyle(fontWeight: FontWeight.w600)),
                        if ((entry.buildingName ?? '').isNotEmpty)
                          Text(entry.buildingName!, style: TextStyle(fontSize: 13, color: Colors.blue.shade700, fontWeight: FontWeight.w500)),
                      ]),
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
                            Icon(entry.hasGps ? Icons.where_to_vote : Icons.location_on, size: 12, color: Colors.blueGrey),
                            const SizedBox(width: 4),
                            Expanded(child: Text(entry.location!, style: const TextStyle(fontSize: 11, color: Colors.blueGrey), overflow: TextOverflow.ellipsis)),
                          ]),
                        ],
                        if (entry.hasGps) ...[
                          const SizedBox(height: 4),
                          GestureDetector(
                            onTap: () async {
                              final lat = entry.gpsLat!;
                              final lng = entry.gpsLng!;
                              final Uri mapsUri = Platform.isIOS
                                ? Uri.parse('maps://?q=$lat,$lng')
                                : Uri.parse('geo:$lat,$lng?q=$lat,$lng');
                              if (await canLaunchUrl(mapsUri)) {
                                await launchUrl(mapsUri, mode: LaunchMode.externalApplication);
                              } else {
                                final fallback = Uri.parse('https://maps.google.com/?q=$lat,$lng');
                                await launchUrl(fallback, mode: LaunchMode.externalApplication);
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.green.shade50,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.green.shade300),
                              ),
                              child: Row(children: [
                                Icon(Icons.map, size: 16, color: Colors.green.shade700),
                                const SizedBox(width: 6),
                                Expanded(child: Text(
                                  '📍 ${entry.gpsLat!.toStringAsFixed(4)}, ${entry.gpsLng!.toStringAsFixed(4)}',
                                  style: TextStyle(fontSize: 13, color: Colors.green.shade700, fontWeight: FontWeight.w600),
                                )),
                                Icon(Icons.open_in_new, size: 14, color: Colors.green.shade600),
                              ]),
                            ),
                          ),
                        ],
                        if (entry.roofPitch != null) ...[
                          const SizedBox(height: 2),
                          Row(children: [
                            const Icon(Icons.architecture, size: 12, color: Colors.deepOrange),
                            const SizedBox(width: 4),
                            Text('Pitch: ${entry.roofPitch!.toStringAsFixed(1)}°', style: const TextStyle(fontSize: 11, color: Colors.deepOrange)),
                          ]),
                        ],
                        if ((entry.notes ?? '').isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Row(children: [
                            const Icon(Icons.notes, size: 12, color: Colors.purple),
                            const SizedBox(width: 4),
                            Expanded(child: Text(entry.notes!, style: const TextStyle(fontSize: 11, color: Colors.purple), overflow: TextOverflow.ellipsis)),
                          ]),
                        ],
                      ]),
                      isThreeLine: true,
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: 'Export as PDF',
                          icon: const Icon(Icons.picture_as_pdf, color: Colors.red, size: 20),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () async {
                            try {
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Generating PDF...'), duration: Duration(seconds: 1)));
                              final pdfBytes = await PdfService.generateHistoryPdf([entry]);
                              final safeName = p.displayTitle.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
                              final safeDate = DateTime.now().millisecondsSinceEpoch.toString();
                              await Share.shareXFiles(
                                [XFile.fromData(pdfBytes, name: '${safeName}_$safeDate.pdf', mimeType: 'application/pdf')],
                                subject: 'Roof Profile — ${p.displayTitle}',
                                sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
                              );
                            } catch (e) {
                              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF failed: \$e'), backgroundColor: Colors.red));
                            }
                          },
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_forward_ios, size: 16),
                      ]),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => ResultsScreen(title: 'Profile', results: [SearchResult(profile: p, score: 0)]))),
                    ),
                    );
                  }),
                ),
              ]),
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
  Set<String> _favouriteKeys = {};

  String _profileKey(ProfileRecord p) => '${p.code}_${p.profileName}';

  @override
  void initState() {
    super.initState();
    _loadFavourites();
  }

  Future<void> _loadFavourites() async {
    final keys = await FavouritesService.loadKeys();
    if (mounted) setState(() { _favouriteKeys = keys; });
  }

  Future<void> _toggleFavourite(ProfileRecord p) async {
    final key = '${p.code}_${p.profileName}_${p.manufacturer}';
    if (_favouriteKeys.contains(key)) {
      await FavouritesService.remove(p);
      setState(() { _favouriteKeys.remove(key); });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Removed from favourites'), duration: Duration(seconds: 1)));
    } else {
      await FavouritesService.add(p);
      setState(() { _favouriteKeys.add(key); });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('⭐ Added to favourites!'),
        backgroundColor: Colors.amber.shade700,
        duration: const Duration(seconds: 2)));
    }
  }

  bool _isFavourite(ProfileRecord p) =>
    _favouriteKeys.contains('${p.code}_${p.profileName}_${p.manufacturer}');

  Future<void> _saveToHistory(BuildContext context, ProfileRecord profile) async {
    final TextEditingController buildingController = TextEditingController();
    final TextEditingController locationController = TextEditingController();
    final TextEditingController pitchController = TextEditingController();
    final TextEditingController notesController = TextEditingController();
    double? gpsLat;
    double? gpsLng;
    bool gpsLoading = false;

    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + MediaQuery.of(ctx).padding.bottom + 20,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Handle bar
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 16),
            Text('Save Profile', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blue.shade700)),
            Text(profile.displayTitle, style: const TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 20),

            // Building name field
            const Text('Building Name', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            TextField(
              controller: buildingController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                hintText: 'e.g. Smith Residence, Factory Unit 4...',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.home_work_outlined),
                isDense: true,
              ),
            ),
            const SizedBox(height: 14),

            // Address / location field with GPS button
            const Text('Address / Location', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: TextField(
                controller: locationController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  hintText: 'e.g. 14 High Street, Birmingham',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.location_on),
                  isDense: true,
                ),
              )),
              const SizedBox(width: 8),
              // GPS pin button
              Tooltip(
                message: 'Use my GPS location',
                child: SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: gpsLoading ? null : () async {
                      setSheetState(() { gpsLoading = true; });
                      try {
                        LocationPermission perm = await Geolocator.checkPermission();

                        if (perm == LocationPermission.denied) {
                          perm = await Geolocator.requestPermission();
                        }

                        if (perm == LocationPermission.deniedForever) {
                          setSheetState(() { gpsLoading = false; });
                          if (ctx.mounted) {
                            await showDialog<void>(
                              context: ctx,
                              builder: (dCtx) => AlertDialog(
                                title: const Row(children: [
                                  Icon(Icons.location_off, color: Colors.orange),
                                  SizedBox(width: 8),
                                  Text('Location Disabled'),
                                ]),
                                content: const Text(
                                  'Location access is turned off for Profile Finder.\n\n'
                                  'To enable it:\n'
                                  '1. Tap "Open Settings" below\n'
                                  '2. Tap Location\n'
                                  '3. Select "While Using the App"\n\n'
                                  'This lets the app save the GPS pin of the roof you are working on.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(dCtx),
                                    child: const Text('Not Now'),
                                  ),
                                  ElevatedButton.icon(
                                    onPressed: () async {
                                      Navigator.pop(dCtx);
                                      await Geolocator.openAppSettings();
                                    },
                                    icon: const Icon(Icons.settings),
                                    label: const Text('Open Settings'),
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white),
                                  ),
                                ],
                              ),
                            );
                          }
                          return;
                        }

                        if (perm == LocationPermission.denied) {
                          setSheetState(() { gpsLoading = false; });
                          if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Location permission is needed to save GPS pin.')));
                          return;
                        }

                        // Use timeout to prevent it getting stuck
                        final pos = await Geolocator.getCurrentPosition(
                          desiredAccuracy: LocationAccuracy.medium,
                        ).timeout(const Duration(seconds: 10), onTimeout: () {
                          throw Exception('Location timed out. Try again.');
                        });
                        gpsLat = pos.latitude;
                        gpsLng = pos.longitude;
                        if (locationController.text.isEmpty) {
                          locationController.text = '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';
                        }
                        setSheetState(() { gpsLoading = false; });
                        if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('📍 GPS location captured!'), backgroundColor: Colors.green, duration: Duration(seconds: 1)));
                      } catch (e) {
                        setSheetState(() { gpsLoading = false; });
                        if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                          content: Text(e.toString().contains('timed out') ? '📍 Location timed out — try again' : 'Could not get location: $e'),
                          duration: const Duration(seconds: 3),
                        ));
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: gpsLat != null ? Colors.green : Colors.blue.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: gpsLoading
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Icon(gpsLat != null ? Icons.where_to_vote : Icons.my_location, size: 22),
                  ),
                ),
              ),
            ]),
            if (gpsLat != null) ...[
              const SizedBox(height: 4),
              Text('📍 GPS captured: ${gpsLat!.toStringAsFixed(5)}, ${gpsLng!.toStringAsFixed(5)}',
                style: TextStyle(fontSize: 11, color: Colors.green.shade700)),
            ],
            const SizedBox(height: 16),

            // Pitch field
            const Text('Roof pitch (degrees)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            TextField(
              controller: pitchController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                hintText: 'e.g. 22.5',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.architecture),
                suffixText: '°',
                isDense: true,
                helperText: 'Use the Pitch Finder tool in Tools menu',
              ),
            ),
            const SizedBox(height: 24),

            // Notes field
            const Text('Notes', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            TextField(
              controller: notesController,
              textCapitalization: TextCapitalization.sentences,
              maxLines: 2,
              decoration: const InputDecoration(
                hintText: 'e.g. Needs replacing, Match confirmed, Check ridge...',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.notes),
                isDense: true,
              ),
            ),
            const SizedBox(height: 24),

            // Save / Cancel buttons — Cancel is compact, Save takes more space
            Row(children: [
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx, null),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 12),
              Expanded(child: ElevatedButton.icon(
                onPressed: () => Navigator.pop(ctx, {
                  'buildingName': buildingController.text.trim(),
                  'location': locationController.text.trim(),
                  'pitch': pitchController.text.trim(),
                  'notes': notesController.text.trim(),
                  'gpsLat': gpsLat,
                  'gpsLng': gpsLng,
                }),
                icon: const Icon(Icons.bookmark_add),
                label: const Text('Save to History'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              )),
            ]),
          ]),
        ),
      ),
    );

    if (result == null) return;
    final String buildingName = result['buildingName'] as String? ?? '';
    final String location = result['location'] as String? ?? '';
    final double? pitch = double.tryParse(result['pitch'] as String? ?? '');
    final String notes = result['notes'] as String? ?? '';
    await HistoryService.saveEntry(HistoryEntry(
      profile: profile,
      savedAt: DateTime.now(),
      buildingName: buildingName.isEmpty ? null : buildingName,
      location: location.isEmpty ? null : location,
      roofPitch: pitch,
      gpsLat: result['gpsLat'] as double?,
      gpsLng: result['gpsLng'] as double?,
      notes: notes.isEmpty ? null : notes,
    ));
    setState(() { _savedKeys.add(_profileKey(profile)); });
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle, color: Colors.white),
          const SizedBox(width: 8),
          Text(buildingName.isEmpty && location.isEmpty ? 'Saved to history!' : 'Saved: ${buildingName.isNotEmpty ? buildingName : location}'),
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

  void _shareProfile(ProfileRecord p) {
    final StringBuffer sb = StringBuffer();
    sb.writeln('🏠 Roof Profile Finder');
    sb.writeln('─────────────────────');
    sb.writeln(p.displayTitle);
    sb.writeln('Manufacturer: ${p.manufacturer}');
    if (p.isTileCategory) {
      sb.writeln('Material: ${p.materialLabel}');
      sb.writeln('Type: ${p.tileTypeLabel}');
      if (p.nominalLengthMm != null) sb.writeln('Size: ${p.nominalLengthMm!.toInt()} x ${p.nominalWidthMm?.toInt()} mm');
      if (p.minimumPitchDegMin != null) sb.writeln('Min Pitch: ${p.minimumPitchDegMin!.toStringAsFixed(1)}°');
    } else {
      sb.writeln('Shape: ${p.shape}');
      if (p.pitch != null) sb.writeln('Pitch: ${p.pitch!.toStringAsFixed(1)} mm');
      if (p.depth != null) sb.writeln('Depth: ${p.depth!.toStringAsFixed(1)} mm');
      if (p.coverWidth != null) sb.writeln('Cover Width: ${p.coverWidth!.toStringAsFixed(1)} mm');
      if (p.overallWidth != null) sb.writeln('Overall Width: ${p.overallWidth!.toStringAsFixed(1)} mm');
    }
    if ((p.sourceUrl ?? '').isNotEmpty) sb.writeln('Source: ${p.sourceUrl}');
    sb.writeln('─────────────────────');
    sb.writeln('Shared via Roof Profile Finder');
    Share.share(sb.toString(), subject: p.displayTitle, sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1));
  }

  Widget _shareButton(ProfileRecord p) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => _shareProfile(p),
          icon: const Icon(Icons.share, size: 18),
          label: const Text('Share Profile'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.blue.shade700,
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
    );
  }

  Widget _favouriteButton(ProfileRecord p) {
    final isFav = _isFavourite(p);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => _toggleFavourite(p),
          icon: Icon(isFav ? Icons.star : Icons.star_border,
            color: isFav ? Colors.amber.shade700 : null, size: 18),
          label: Text(isFav ? 'Remove from Favourites' : 'Add to Favourites'),
          style: OutlinedButton.styleFrom(
            foregroundColor: isFav ? Colors.amber.shade700 : Colors.grey.shade700,
            side: BorderSide(color: isFav ? Colors.amber.shade400 : Colors.grey.shade400),
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
    );
  }

  // ── Real Photo Section (sheets) ───────────────────────────────
  Widget _realPhotoSection(BuildContext context, ProfileRecord p) {
    if (p.photoUrl != null && p.photoUrl!.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.photo_camera, size: 14, color: Colors.green.shade700),
            const SizedBox(width: 4),
            Text('Real Photo', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.green.shade700)),
          ]),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(height: 160, width: double.infinity,
              child: CachedNetworkImage(
                imageUrl: p.photoUrl!, fit: BoxFit.cover,
                placeholder: (_, __) => const Center(child: CircularProgressIndicator()),
                errorWidget: (_, __, ___) => const Center(child: Icon(Icons.broken_image)),
              ),
            ),
          ),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.blue.shade200),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.add_a_photo_outlined, color: Colors.blue.shade700, size: 18),
            const SizedBox(width: 8),
            Text('No real photo yet', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.blue.shade700)),
          ]),
          const SizedBox(height: 4),
          Text('Do you recognise this sheet? Help others by submitting a photo!',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _showSubmitPhotoSheet(context, p),
              icon: const Icon(Icons.upload_outlined, size: 18),
              label: const Text('Submit image for approval'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _showSubmitPhotoSheet(BuildContext context, ProfileRecord p) async {
    XFile? pickedImage;
    bool submitting = false;
    bool submitted  = false;
    final notesController = TextEditingController();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SingleChildScrollView(
          padding: EdgeInsets.only(left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + MediaQuery.of(ctx).padding.bottom + 20),
          child: submitted
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(height: 20),
                Icon(Icons.check_circle, color: Colors.green.shade600, size: 56),
                const SizedBox(height: 12),
                const Text('Thank you!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('Your photo has been submitted for approval.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                const SizedBox(height: 24),
                ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                const SizedBox(height: 12),
              ])
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Center(child: Container(width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                const SizedBox(height: 16),
                Row(children: [
                  Icon(Icons.add_a_photo_outlined, color: Colors.blue.shade700),
                  const SizedBox(width: 8),
                  const Text('Submit Image for Approval', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 4),
                Text(p.displayTitle, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                Text('Manufacturer: ${p.manufacturer}', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                const SizedBox(height: 20),
                const Text('Photo of Sheet / Profile', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: OutlinedButton.icon(
                    onPressed: () async {
                      final img = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 80);
                      if (img != null) setSheet(() => pickedImage = img);
                    },
                    icon: const Icon(Icons.camera_alt_outlined), label: const Text('Camera'),
                  )),
                  const SizedBox(width: 10),
                  Expanded(child: OutlinedButton.icon(
                    onPressed: () async {
                      final img = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80);
                      if (img != null) setSheet(() => pickedImage = img);
                    },
                    icon: const Icon(Icons.photo_library_outlined), label: const Text('Gallery'),
                  )),
                ]),
                if (pickedImage != null) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 18),
                    const SizedBox(width: 6),
                    Expanded(child: Text(pickedImage!.name, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
                  ]),
                ],
                const SizedBox(height: 14),
                const Text('Notes (optional)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 6),
                TextField(controller: notesController, maxLines: 2,
                  decoration: InputDecoration(
                    hintText: 'e.g. Photographed on a factory in Birmingham...',
                    border: const OutlineInputBorder(), isDense: true,
                    hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400))),
                const SizedBox(height: 20),
                SizedBox(width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: (submitting || pickedImage == null) ? null : () async {
                      setSheet(() => submitting = true);
                      try {
                        final ref = FirebaseStorage.instance
                          .ref('sheet_photos/${p.code}_${DateTime.now().millisecondsSinceEpoch}.jpg');
                        await ref.putFile(File(pickedImage!.path));
                        final uploadedUrl = await ref.getDownloadURL();
                        await FirebaseFirestore.instance.collection('image_corrections').add({
                          'type': 'sheet_photo', 'profileId': p.code,
                          'profileName': p.profileName, 'manufacturer': p.manufacturer,
                          'photoUrl': uploadedUrl, 'notes': notesController.text.trim(),
                          'submittedBy': FirebaseAuth.instance.currentUser?.email ?? 'anonymous',
                          'submittedAt': FieldValue.serverTimestamp(), 'status': 'pending',
                        });
                        setSheet(() { submitting = false; submitted = true; });
                      } catch (e) {
                        setSheet(() => submitting = false);
                        if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
                      }
                    },
                    icon: submitting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.upload_outlined),
                    label: Text(submitting ? 'Uploading...' : 'Submit for Approval'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
                if (pickedImage == null)
                  Padding(padding: const EdgeInsets.only(top: 6),
                    child: Center(child: Text('Please select a photo first',
                      style: TextStyle(fontSize: 11, color: Colors.orange.shade700)))),
                const SizedBox(height: 8),
                Center(child: Text('Photos are reviewed before appearing in the app.',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500))),
              ]),
        ),
      ),
    );
  }

  Widget _reportButton(BuildContext context, ProfileRecord p) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => _showReportSheet(context, p),
          icon: const Icon(Icons.flag_outlined, size: 18),
          label: const Text('Report incorrect image / details'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.orange.shade700,
            side: BorderSide(color: Colors.orange.shade300),
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
    );
  }

  Future<void> _showReportSheet(BuildContext context, ProfileRecord p) async {
    final nameCtrl = TextEditingController(text: p.profileName);
    final mfrCtrl  = TextEditingController(text: p.manufacturer);
    XFile? pickedImage;
    bool submitting = false;
    bool submitted  = false;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SingleChildScrollView(
          padding: EdgeInsets.only(left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + MediaQuery.of(ctx).padding.bottom + 20),
          child: submitted
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(height: 20),
                Icon(Icons.check_circle, color: Colors.green.shade600, size: 56),
                const SizedBox(height: 12),
                const Text('Thank you!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('Your correction has been sent.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                const SizedBox(height: 24),
                ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                const SizedBox(height: 12),
              ])
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Center(child: Container(width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                const SizedBox(height: 16),
                Row(children: [
                  Icon(Icons.flag_outlined, color: Colors.orange.shade700),
                  const SizedBox(width: 8),
                  const Text('Report Incorrect Details', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 4),
                Text(p.displayTitle, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                const SizedBox(height: 20),
                const Text('Profile Name', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 6),
                TextField(controller: nameCtrl,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, prefixIcon: Icon(Icons.label_outline))),
                const SizedBox(height: 14),
                const Text('Manufacturer', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 6),
                TextField(controller: mfrCtrl,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, prefixIcon: Icon(Icons.business_outlined))),
                const SizedBox(height: 14),
                const Text('Photo (optional)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: OutlinedButton.icon(
                    onPressed: () async {
                      final img = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 70);
                      if (img != null) setSheet(() => pickedImage = img);
                    },
                    icon: const Icon(Icons.camera_alt_outlined), label: const Text('Camera'),
                  )),
                  const SizedBox(width: 10),
                  Expanded(child: OutlinedButton.icon(
                    onPressed: () async {
                      final img = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70);
                      if (img != null) setSheet(() => pickedImage = img);
                    },
                    icon: const Icon(Icons.photo_library_outlined), label: const Text('Gallery'),
                  )),
                ]),
                if (pickedImage != null) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 18),
                    const SizedBox(width: 6),
                    Expanded(child: Text(pickedImage!.name, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
                  ]),
                ],
                const SizedBox(height: 20),
                SizedBox(width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: submitting ? null : () async {
                      setSheet(() => submitting = true);
                      try {
                        String? photoUrl;
                        if (pickedImage != null) {
                          final ref = FirebaseStorage.instance
                            .ref('corrections/${p.code}_${DateTime.now().millisecondsSinceEpoch}.jpg');
                          await ref.putFile(File(pickedImage!.path));
                          photoUrl = await ref.getDownloadURL();
                        }
                        await FirebaseFirestore.instance.collection('image_corrections').add({
                          'type': 'correction', 'profileId': p.code,
                          'originalName': p.profileName, 'originalMfr': p.manufacturer,
                          'correctedName': nameCtrl.text.trim(), 'correctedMfr': mfrCtrl.text.trim(),
                          'photoUrl': photoUrl,
                          'submittedBy': FirebaseAuth.instance.currentUser?.email ?? 'anonymous',
                          'submittedAt': FieldValue.serverTimestamp(), 'status': 'pending',
                        });
                        setSheet(() { submitting = false; submitted = true; });
                      } catch (e) {
                        setSheet(() => submitting = false);
                        if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
                      }
                    },
                    icon: submitting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send_outlined),
                    label: Text(submitting ? 'Sending...' : 'Send Correction'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange.shade700, foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
                const SizedBox(height: 8),
                Center(child: Text('Corrections are reviewed before going live.',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500))),
              ]),
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
          _realPhotoSection(context, p),
          _saveButton(context, p),
          _shareButton(p),
          _favouriteButton(p),
          _reportButton(context, p),
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
          _shareButton(p),
          _favouriteButton(p),
          _reportButton(context, p),
        ])));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.title} Results'), backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white),
      body: widget.results.isEmpty
          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No matches found.\n\nTry widening the tolerance or changing one of the measurements.', textAlign: TextAlign.center)))
          : Column(children: [
              // Prominent save banner at top
              Container(
                width: double.infinity,
                color: Colors.amber.shade50,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(children: [
                  const Icon(Icons.bookmark_add, color: Colors.orange, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('Found your profile? Scroll down to save it with location & roof pitch!', style: TextStyle(fontSize: 13, color: Colors.black87))),
                ]),
              ),
              Expanded(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text('Matches found: ${widget.results.length}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                ...widget.results.map((r) => Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: r.profile.isTileCategory ? _tileResultCard(context, r) : _sheetResultCard(context, r))),
                const SizedBox(height: 20),
              ]))),
            ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Admin Corrections Tab
// ═══════════════════════════════════════════════════════════════

class _AdminCorrectionsTab extends StatefulWidget {
  const _AdminCorrectionsTab();
  @override
  State<_AdminCorrectionsTab> createState() => _AdminCorrectionsTabState();
}

class _AdminCorrectionsTabState extends State<_AdminCorrectionsTab> {
  bool _loading = false;

  Future<void> _approve(String docId, String? photoUrl) async {
    setState(() => _loading = true);
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'europe-west2')
        .httpsCallable('approveCorrection');
      await callable.call({'correctionId': docId});
      ProfilePhotoService.invalidate(); // force fresh fetch on next profile load
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Approved!'), backgroundColor: Colors.green));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reject(String docId) async {
    setState(() => _loading = true);
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'europe-west2')
        .httpsCallable('rejectCorrection');
      await callable.call({'correctionId': docId});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rejected and deleted.'), backgroundColor: Colors.orange));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
        .collection('image_corrections')
        .where('status', isEqualTo: 'pending')
        .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.lock_outline, size: 48, color: Colors.orange),
              const SizedBox(height: 12),
              const Text('Please sign in to view corrections',
                style: TextStyle(fontSize: 16)),
            ]),
          ));
        }
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.check_circle_outline, size: 56, color: Colors.green),
              SizedBox(height: 12),
              Text('No pending corrections!', style: TextStyle(fontSize: 16)),
            ]),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final doc = docs[index];
            final data = doc.data() as Map<String, dynamic>;
            final type = data['type'] == 'sheet_photo' ? 'Photo submission' : 'Correction report';
            final name = data['profileName'] ?? data['originalName'] ?? 'Unknown';
            final mfr  = data['manufacturer'] ?? data['originalMfr'] ?? '';
            final photoUrl = data['photoUrl'] as String?;
            final notes = data['notes'] ?? data['correctedName'] ?? '';
            final by = data['submittedBy'] ?? 'anonymous';

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: data['type'] == 'sheet_photo' ? Colors.blue.shade50 : Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: data['type'] == 'sheet_photo' ? Colors.blue.shade200 : Colors.orange.shade200),
                      ),
                      child: Text(type, style: TextStyle(fontSize: 11, color: data['type'] == 'sheet_photo' ? Colors.blue.shade700 : Colors.orange.shade700)),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  if (mfr.isNotEmpty) Text(mfr, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                  if (notes.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('Notes: $notes', style: const TextStyle(fontSize: 13)),
                  ],
                  Text('From: $by', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  if (photoUrl != null) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: 180, width: double.infinity,
                        child: CachedNetworkImage(
                          imageUrl: photoUrl, fit: BoxFit.cover,
                          placeholder: (_, __) => const Center(child: CircularProgressIndicator()),
                          errorWidget: (_, __, ___) => const Center(child: Icon(Icons.broken_image)),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: ElevatedButton.icon(
                      onPressed: _loading ? null : () => _approve(doc.id, photoUrl),
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Approve'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade600,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    )),
                    const SizedBox(width: 10),
                    Expanded(child: OutlinedButton.icon(
                      onPressed: _loading ? null : () => _reject(doc.id),
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('Reject'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade600,
                        side: BorderSide(color: Colors.red.shade300),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    )),
                  ]),
                ]),
              ),
            );
          },
        );
      },
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
// Tools Screen
// ═══════════════════════════════════════════════════════════════

class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key});
  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  List<Map<String, String>> _customApps = [];

  @override
  void initState() {
    super.initState();
    _loadCustomApps();
  }

  Future<void> _loadCustomApps() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> raw = prefs.getStringList('custom_apps') ?? [];
    setState(() {
      _customApps = raw.map((e) => Map<String, String>.from(jsonDecode(e) as Map)).toList();
    });
  }

  Future<void> _saveCustomApps() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('custom_apps', _customApps.map((e) => jsonEncode(e)).toList());
  }

  Future<void> _addOrEditApp({int? index}) async {
    final nameController = TextEditingController(text: index != null ? _customApps[index]['name'] : '');
    final urlController = TextEditingController(text: index != null ? _customApps[index]['url'] : '');
    final result = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(index != null ? 'Edit App' : 'Add Custom App'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Add a link to any app or website you use on site.', style: TextStyle(fontSize: 13, color: Colors.grey)),
        const SizedBox(height: 16),
        TextField(
          controller: nameController,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'App Name', hintText: 'e.g. BBC Weather', border: OutlineInputBorder(), prefixIcon: Icon(Icons.apps)),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: urlController,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: 'URL or App Link', hintText: 'e.g. https://weather.com', border: OutlineInputBorder(), prefixIcon: Icon(Icons.link)),
        ),
        const SizedBox(height: 8),
        const Text('Tip: For apps try their web address. e.g. https://bbc.co.uk/weather', style: TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
      actions: [
        if (index != null)
          TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Delete', style: TextStyle(color: Colors.red))),
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white),
          child: const Text('Save'),
        ),
      ],
    ));
    if (result == null && index != null) {
      // Delete
      setState(() { _customApps.removeAt(index); });
      await _saveCustomApps();
    } else if (result == true && nameController.text.isNotEmpty && urlController.text.isNotEmpty) {
      setState(() {
        if (index != null) {
          _customApps[index] = {'name': nameController.text.trim(), 'url': urlController.text.trim()};
        } else {
          _customApps.add({'name': nameController.text.trim(), 'url': urlController.text.trim()});
        }
      });
      await _saveCustomApps();
    }
  }

  Future<void> _launchCustomApp(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open: $url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tools'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Roofer\'s Tools', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: Container(
                width: 52, height: 52,
                decoration: BoxDecoration(color: Colors.blue.shade700, borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.architecture, color: Colors.white, size: 28),
              ),
              title: const Text('Roof Pitch Finder', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              subtitle: const Text('Use your phone to measure roof pitch in degrees and ratio'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () { ToolUsageService.recordUsage('pitch'); Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PitchAngleScreen())); },
            ),
          ),
          ...[
            const SizedBox(height: 12),
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                leading: Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(color: Colors.brown.shade600, borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.storefront, color: Colors.white, size: 28),
                ),
                title: const Text('Site Stops', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                subtitle: const Text('Find nearby coffee, food and trade counters, then open directions'),
                trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                onTap: () { ToolUsageService.recordUsage('siteStops'); Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SiteStopsScreen())); },
              ),
            ),
            const SizedBox(height: 12),
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                leading: Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(color: Colors.amber.shade700, borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.flashlight_on, color: Colors.white, size: 28),
                ),
                title: const Text('Torch', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                subtitle: const Text('Turn on your phone torch for working in dark roof spaces'),
                trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                onTap: () { ToolUsageService.recordUsage('torch'); Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TorchScreen())); },
              ),
            ),
          ],
          const SizedBox(height: 12),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: Container(
                width: 52, height: 52,
                decoration: BoxDecoration(color: Colors.green.shade700, borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.list_alt, color: Colors.white, size: 28),
              ),
              title: const Text('Material List', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              subtitle: const Text('Build a material takeoff list for any roofing job'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () { ToolUsageService.recordUsage('material'); Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MaterialListScreen())); },
            ),
          ),
          const SizedBox(height: 12),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: Container(
                width: 52, height: 52,
                decoration: BoxDecoration(color: Colors.teal.shade700, borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.calculate, color: Colors.white, size: 28),
              ),
              title: const Text('Roof Area Calculator', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              subtitle: const Text('Calculate roof area from length, width and pitch'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () { ToolUsageService.recordUsage('area'); Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RoofAreaCalculator())); },
            ),
          ),
          const SizedBox(height: 12),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: Container(
                width: 52, height: 52,
                decoration: BoxDecoration(color: Colors.indigo.shade700, borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.crop_free, color: Colors.white, size: 28),
              ),
              title: const Text('Perimeter Area Tool', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              subtitle: const Text('Draw building outline and enter wall lengths to calculate area'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () { ToolUsageService.recordUsage('perimeter'); Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PerimeterAreaTool())); },
            ),
          ),
          const SizedBox(height: 12),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: Container(
                width: 52, height: 52,
                decoration: BoxDecoration(color: Colors.brown.shade600, borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.straighten, color: Colors.white, size: 28),
              ),
              title: const Text('Rafter Calculator', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              subtitle: const Text('Calculate rafter length, ridge height and number of rafters'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () { ToolUsageService.recordUsage('rafter'); Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RafterCalculator())); },
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// My Apps Screen
// ═══════════════════════════════════════════════════════════════

class MyAppsScreen extends StatefulWidget {
  const MyAppsScreen({super.key});
  @override
  State<MyAppsScreen> createState() => _MyAppsScreenState();
}

class _MyAppsScreenState extends State<MyAppsScreen> {
  List<Map<String, String>> _customApps = [];

  // Popular app suggestions with their URL schemes
  static const List<Map<String, String>> _suggestions = [
    {'name': 'BBC Weather', 'url': 'https://bbc.co.uk/weather', 'icon': '🌤️'},
    {'name': 'Met Office', 'url': 'https://metoffice.gov.uk', 'icon': '🌦️'},
    {'name': 'Google Maps', 'url': 'https://maps.google.com', 'icon': '🗺️'},
    {'name': 'WhatsApp', 'url': 'whatsapp://', 'icon': '💬'},
    {'name': 'Jewson', 'url': 'https://jewson.co.uk', 'icon': '🏗️'},
    {'name': 'Travis Perkins', 'url': 'https://travisperkins.co.uk', 'icon': '🔨'},
    {'name': 'Roofing Superstore', 'url': 'https://roofingsuperstore.co.uk', 'icon': '🏠'},
    {'name': 'Calculator', 'url': 'calculator://', 'icon': '🔢'},
    {'name': 'Camera', 'url': 'photos://', 'icon': '📷'},
    {'name': 'Phone', 'url': 'tel:', 'icon': '📞'},
  ];

  @override
  void initState() {
    super.initState();
    _loadCustomApps();
  }

  Future<void> _loadCustomApps() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> raw = prefs.getStringList('custom_apps') ?? [];
    setState(() {
      _customApps = raw.map((e) => Map<String, String>.from(jsonDecode(e) as Map)).toList();
    });
  }

  Future<void> _saveCustomApps() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('custom_apps', _customApps.map((e) => jsonEncode(e)).toList());
  }

  Future<void> _addApp({Map<String, String>? suggestion}) async {
    final nameController = TextEditingController(text: suggestion?['name'] ?? '');
    final urlController = TextEditingController(text: suggestion?['url'] ?? '');
    final result = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Add App'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          controller: nameController,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'App Name', hintText: 'e.g. BBC Weather', border: OutlineInputBorder(), prefixIcon: Icon(Icons.apps)),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: urlController,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: 'URL or App Link', hintText: 'e.g. https://bbc.co.uk/weather', border: OutlineInputBorder(), prefixIcon: Icon(Icons.link)),
        ),
        const SizedBox(height: 8),
        const Text('Use any website URL or app URL scheme', style: TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple.shade400, foregroundColor: Colors.white),
          child: const Text('Add'),
        ),
      ],
    ));
    if (result == true && nameController.text.isNotEmpty && urlController.text.isNotEmpty) {
      setState(() { _customApps.add({'name': nameController.text.trim(), 'url': urlController.text.trim()}); });
      await _saveCustomApps();
    }
  }

  Future<void> _editApp(int index) async {
    final nameController = TextEditingController(text: _customApps[index]['name']);
    final urlController = TextEditingController(text: _customApps[index]['url']);
    final result = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Edit App'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: nameController, textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'App Name', border: OutlineInputBorder(), prefixIcon: Icon(Icons.apps))),
        const SizedBox(height: 12),
        TextField(controller: urlController, keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: 'URL', border: OutlineInputBorder(), prefixIcon: Icon(Icons.link))),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: const Text('Delete', style: TextStyle(color: Colors.red))),
        TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, 'save'),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple.shade400, foregroundColor: Colors.white),
          child: const Text('Save')),
      ],
    ));
    if (result == 'delete') {
      setState(() { _customApps.removeAt(index); });
      await _saveCustomApps();
    } else if (result == 'save' && nameController.text.isNotEmpty) {
      setState(() { _customApps[index] = {'name': nameController.text.trim(), 'url': urlController.text.trim()}; });
      await _saveCustomApps();
    }
  }

  Future<void> _launchApp(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open: $url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Apps'),
        backgroundColor: Colors.deepPurple.shade400,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Add app',
            icon: const Icon(Icons.add),
            onPressed: () => _addApp(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Saved apps
          if (_customApps.isNotEmpty) ...[
            const Text('My Saved Apps', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ..._customApps.asMap().entries.map((entry) {
              final i = entry.key;
              final app = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: Container(
                      width: 48, height: 48,
                      decoration: BoxDecoration(color: Colors.deepPurple.shade400, borderRadius: BorderRadius.circular(10)),
                      child: const Icon(Icons.open_in_new, color: Colors.white, size: 24),
                    ),
                    title: Text(app['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(app['url'] ?? '', style: const TextStyle(fontSize: 11, color: Colors.grey), overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: Icon(Icons.edit, size: 18, color: Colors.grey.shade400),
                      onPressed: () => _editApp(i),
                    ),
                    onTap: () => _launchApp(app['url'] ?? ''),
                  ),
                ),
              );
            }),
            const SizedBox(height: 24),
          ],

          // Suggestions
          const Text('Popular Apps for Roofers', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Tap + to add any of these to your list', style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 12),
          ..._suggestions.map((s) {
            final alreadyAdded = _customApps.any((a) => a['name'] == s['name']);
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                color: alreadyAdded ? Colors.grey.shade50 : Colors.white,
                child: ListTile(
                  leading: Text(s['icon'] ?? '📱', style: const TextStyle(fontSize: 28)),
                  title: Text(s['name'] ?? '', style: TextStyle(fontWeight: FontWeight.w600, color: alreadyAdded ? Colors.grey : Colors.black)),
                  subtitle: Text(s['url'] ?? '', style: const TextStyle(fontSize: 11, color: Colors.grey), overflow: TextOverflow.ellipsis),
                  trailing: alreadyAdded
                    ? Icon(Icons.check_circle, color: Colors.green.shade400, size: 20)
                    : IconButton(
                        icon: Icon(Icons.add_circle_outline, color: Colors.deepPurple.shade400),
                        onPressed: () => _addApp(suggestion: s),
                      ),
                  onTap: alreadyAdded ? null : () => _addApp(suggestion: s),
                ),
              ),
            );
          }),
          const SizedBox(height: 12),

          // Custom add button
          OutlinedButton.icon(
            onPressed: () => _addApp(),
            icon: const Icon(Icons.add),
            label: const Text('Add Custom App or Website'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.deepPurple.shade400,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Pitch Angle Screen
// ═══════════════════════════════════════════════════════════════

class PitchAngleScreen extends StatefulWidget {
  const PitchAngleScreen({super.key});
  @override
  State<PitchAngleScreen> createState() => _PitchAngleScreenState();
}

class _PitchAngleScreenState extends State<PitchAngleScreen> {
  double _pitch = 0.0;
  double? _lockedPitch;
  bool _locked = false;
  double _calibrationOffset = 0.0;
  bool _showInstructions = true;
  StreamSubscription<AccelerometerEvent>? _sub;

  // TTS
  final FlutterTts _flutterTts = FlutterTts();
  bool _ttsEnabled = true; // on by default
  double _lastSpokenAngle = -1;
  Timer? _speakTimer; // debounce — only speak after angle stable
  double _ttsSensitivity = 1.0; // seconds — 0.3 to 2.0

  // Smoothing buffer
  final List<double> _buffer = [];
  static const int _bufferSize = 15;

  @override
  void initState() {
    super.initState();
    _loadCalibration();
    _loadInstructionsPref();
    _loadTtsPref();
    _loadSensitivityPref();
    _initTts();
    _sub = accelerometerEventStream(samplingPeriod: SensorInterval.normalInterval).listen((event) {
      final double rawPitch = math.atan2(-event.y, math.sqrt(event.x * event.x + event.z * event.z)) * 180 / math.pi;
      final double calibrated = (rawPitch - _calibrationOffset).abs();

      _buffer.add(calibrated);
      if (_buffer.length > _bufferSize) _buffer.removeAt(0);
      final double smoothed = _buffer.reduce((a, b) => a + b) / _buffer.length;

      if (!_locked && mounted) {
        setState(() { _pitch = smoothed.clamp(0.0, 90.0); });
        if (_ttsEnabled) {
          final int rounded = smoothed.clamp(0.0, 90.0).round();
          if (rounded != _lastSpokenAngle.round()) {
            _lastSpokenAngle = rounded.toDouble();
            // Cancel previous timer — restart 1 second countdown
            _speakTimer?.cancel();
            _speakTimer = Timer(Duration(milliseconds: (_ttsSensitivity * 1000).round()), () async {
              final String angleText = smoothed.clamp(0.0, 90.0).toStringAsFixed(1);
              await _flutterTts.stop(); // clear iOS queue before speaking
              _flutterTts.speak('$angleText degrees');
            });
          }
        }
      }
    });
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage('en-GB');
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
  }

  Future<void> _loadTtsPref() async {
    final prefs = await SharedPreferences.getInstance();
    // Default true — only false if user has explicitly turned it off
    setState(() { _ttsEnabled = prefs.getBool('tts_enabled') ?? true; });
  }

  Future<void> _saveTtsPref(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tts_enabled', value);
  }

  Future<void> _loadSensitivityPref() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() { _ttsSensitivity = prefs.getDouble('tts_sensitivity') ?? 1.0; });
  }

  Future<void> _saveSensitivityPref(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('tts_sensitivity', value);
  }

  Future<void> _loadCalibration() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() { _calibrationOffset = prefs.getDouble('pitch_calibration') ?? 0.0; });
  }

  Future<void> _loadInstructionsPref() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() { _showInstructions = prefs.getBool('pitch_show_instructions') ?? true; });
  }

  Future<void> _hideInstructions({bool permanently = false}) async {
    if (permanently) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('pitch_show_instructions', false);
    }
    setState(() { _showInstructions = false; });
  }

  Future<void> _calibrate() async {
    final prefs = await SharedPreferences.getInstance();
    final double rawNow = _pitch + _calibrationOffset;
    await prefs.setDouble('pitch_calibration', rawNow);
    setState(() { _calibrationOffset = rawNow; _buffer.clear(); _pitch = 0.0; });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('✓ Calibrated! Phone is now set as 0°'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ));
    }
  }

  Future<void> _resetCalibration() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('pitch_calibration');
    setState(() { _calibrationOffset = 0.0; _buffer.clear(); });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _speakTimer?.cancel();
    _flutterTts.stop();
    super.dispose();
  }

  // Convert degrees to pitch ratio
  String _pitchRatio(double deg) {
    if (deg < 1) return 'Flat';
    final double rise = math.tan(deg * math.pi / 180) * 12;
    return '${rise.toStringAsFixed(1)}/12';
  }

  // Pitch description
  String _pitchDescription(double deg) {
    if (deg < 2) return 'Flat / Very Low Pitch';
    if (deg < 10) return 'Low Pitch';
    if (deg < 20) return 'Medium Pitch';
    if (deg < 30) return 'Steep Pitch';
    if (deg < 45) return 'Very Steep';
    return 'Extreme Pitch';
  }

  Color _pitchColor(double deg) {
    if (deg < 2) return Colors.grey;
    if (deg < 10) return Colors.green;
    if (deg < 20) return Colors.orange;
    if (deg < 30) return Colors.deepOrange;
    return Colors.red;
  }

  double get _displayPitch => _locked ? (_lockedPitch ?? _pitch) : _pitch;

  Future<void> _shareRidgeHipDiagram(GlobalKey diagramKey, double pitchDeg, double ridgeAngle, double hipAngle) async {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final boundary = diagramKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) {
        Share.share(
          'Ridge & Hip Angles\nPitch: ${pitchDeg.toStringAsFixed(1)}°\nRidge flashing angle: ${ridgeAngle.toStringAsFixed(1)}°\nHip / valley flashing angle: ${hipAngle.toStringAsFixed(1)}°\n\nCalculated by Roof Profile Finder',
          sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
        );
        return;
      }
      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw Exception('Could not create image');
      final file = File('${Directory.systemTemp.path}/ridge_hip_angles_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(byteData.buffer.asUint8List());
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Ridge & Hip Angles - pitch ${pitchDeg.toStringAsFixed(1)}°',
        sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
      );
    } catch (_) {
      Share.share(
        'Ridge & Hip Angles\nPitch: ${pitchDeg.toStringAsFixed(1)}°\nRidge flashing angle: ${ridgeAngle.toStringAsFixed(1)}°\nHip / valley flashing angle: ${hipAngle.toStringAsFixed(1)}°\n\nCalculated by Roof Profile Finder',
        sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
      );
    }
  }

  void _showRidgeAngleDialog(double pitchDeg) {
    final double ridgeAngle = 180 - (pitchDeg * 2);
    final double hipAngle = 90 + pitchDeg;
    final diagramKey = GlobalKey();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Icon(Icons.roofing, color: Colors.teal.shade700),
          const SizedBox(width: 8),
          const Expanded(child: Text('Ridge & Hip Angles', overflow: TextOverflow.ellipsis)),
        ]),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: math.min(MediaQuery.of(ctx).size.width - 64, 420)),
          child: SingleChildScrollView(
            child: RepaintBoundary(
              key: diagramKey,
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(4),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(color: Colors.teal.shade50, borderRadius: BorderRadius.circular(12)),
                    child: CustomPaint(
                      size: const Size(260, 130),
                      painter: _RidgeDiagramPainter(pitchDeg: pitchDeg, ridgeAngle: ridgeAngle),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.teal.shade700, borderRadius: BorderRadius.circular(10)),
                    child: Column(children: [
                      const Text('Ridge Flashing Angle', style: TextStyle(color: Colors.white70, fontSize: 13)),
                      const SizedBox(height: 4),
                      FittedBox(child: Text('${ridgeAngle.toStringAsFixed(1)}°',
                        style: const TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.bold, height: 1.1))),
                      Text('For a ${pitchDeg.toStringAsFixed(1)}° pitch roof',
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.orange.shade700, borderRadius: BorderRadius.circular(10)),
                    child: Column(children: [
                      const Text('Hip / Valley Flashing Angle', style: TextStyle(color: Colors.white70, fontSize: 13)),
                      const SizedBox(height: 4),
                      FittedBox(child: Text('${hipAngle.toStringAsFixed(1)}°',
                        style: const TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.bold, height: 1.1))),
                      Text('Internal angle each side: ${(pitchDeg + 90).toStringAsFixed(1)}°',
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
                    child: const Text(
                      '💡 The ridge angle is the angle you set your sheet metal bender or flashing folder to.\n\nFormula: 180° − (pitch × 2)',
                      style: TextStyle(fontSize: 12, height: 1.5),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text('Calculated by Roof Profile Finder', style: TextStyle(color: Colors.grey.shade500, fontSize: 10)),
                ]),
              ),
            ),
          ),
        ),
        actions: [
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
            ElevatedButton.icon(
              onPressed: () => _shareRidgeHipDiagram(diagramKey, pitchDeg, ridgeAngle, hipAngle),
              icon: const Icon(Icons.share, size: 18),
              label: const Text('Share diagram'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal.shade700, foregroundColor: Colors.white),
            ),
          ]),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double deg = _displayPitch;
    final Color pitchColor = _pitchColor(deg);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Roof Pitch Finder'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: _ttsEnabled ? 'Voice readout ON' : 'Voice readout OFF',
            icon: Icon(_ttsEnabled ? Icons.volume_up : Icons.volume_off,
              color: _ttsEnabled ? Colors.greenAccent : Colors.white),
            onPressed: () {
              setState(() { _ttsEnabled = !_ttsEnabled; _lastSpokenAngle = -1; });
              _saveTtsPref(_ttsEnabled);
              if (_ttsEnabled) _flutterTts.speak('Voice readout on');
              else { _speakTimer?.cancel(); _flutterTts.stop(); }
            },
          ),
          TextButton.icon(
            onPressed: _calibrate,
            icon: const Icon(Icons.tune, color: Colors.white, size: 18),
            label: const Text('Calibrate', style: TextStyle(color: Colors.white, fontSize: 13)),
          ),
          if (_calibrationOffset != 0.0)
            IconButton(
              tooltip: 'Reset calibration',
              icon: const Icon(Icons.refresh, color: Colors.white),
              onPressed: _resetCalibration,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // How to hold phone diagram — dismissible
            if (_showInstructions) Card(
              color: Colors.blue.shade50,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.info_outline, color: Colors.blue),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('How to Measure', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue))),
                    // Close button
                    IconButton(
                      onPressed: () => _hideInstructions(),
                      icon: const Icon(Icons.close, size: 18, color: Colors.blue),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: 'Close',
                    ),
                  ]),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                    child: Column(children: [
                      CustomPaint(size: const Size(200, 80), painter: _RoofDiagramPainter()),
                      const SizedBox(height: 8),
                      const Text('Hold the BOTTOM EDGE of your phone\nagainst the roof slope', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  const Text('• Hold phone in portrait mode\n• Press the bottom edge flat against the roof\n• Keep steady for a stable reading\n• Tap Lock to capture the angle\n• Use Calibrate (top right) on a known flat surface to zero the reading', style: TextStyle(fontSize: 13, height: 1.6)),
                  if (_calibrationOffset != 0.0) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.green.shade300)),
                      child: Row(children: [
                        Icon(Icons.check_circle, size: 14, color: Colors.green.shade700),
                        const SizedBox(width: 6),
                        Text('Calibrated (offset: ${_calibrationOffset.toStringAsFixed(1)}°)', style: TextStyle(fontSize: 12, color: Colors.green.shade700)),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 10),
                  // Don't show again button
                  SizedBox(width: double.infinity,
                    child: TextButton.icon(
                      onPressed: () => _hideInstructions(permanently: true),
                      icon: const Icon(Icons.visibility_off, size: 16),
                      label: const Text('Don\'t show again', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(foregroundColor: Colors.grey),
                    ),
                  ),
                ]),
              ),
            ),
            if (_showInstructions) const SizedBox(height: 16),

            // Lock / Unlock button — NOW AT TOP
            SizedBox(width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  setState(() {
                    if (_locked) {
                      _locked = false;
                      _lockedPitch = null;
                    } else {
                      _locked = true;
                      _lockedPitch = _pitch;
                    }
                  });
                },
                icon: Icon(_locked ? Icons.lock_open : Icons.lock),
                label: Text(_locked ? 'Unlock (Resume Live)' : 'Lock Reading'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _locked ? Colors.orange : Colors.blue.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Combined pitch display box
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: pitchColor.withOpacity(0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: pitchColor, width: 2),
              ),
              child: Column(children: [
                // Main degrees — big
                Text(
                  '${deg.toStringAsFixed(1)}°',
                  style: TextStyle(fontSize: 80, fontWeight: FontWeight.bold, color: pitchColor, height: 1.0),
                ),
                Text(
                  _pitchDescription(deg),
                  style: TextStyle(fontSize: 18, color: pitchColor, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 12),
                // Ratio and slope in same row
                Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  Column(children: [
                    const Text('Pitch Ratio', style: TextStyle(fontSize: 11, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Text(_pitchRatio(deg), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  ]),
                  Container(width: 1, height: 40, color: Colors.grey.shade300),
                  Column(children: [
                    const Text('% Slope', style: TextStyle(fontSize: 11, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Text('${(math.tan(deg * math.pi / 180) * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  ]),
                ]),
              ]),
            ),
            const SizedBox(height: 16),

            // Ridge Angle button
            SizedBox(width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _showRidgeAngleDialog(deg),
                icon: const Icon(Icons.roofing),
                label: const Text('Ridge / Hip Flashing Angle'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Voice sensitivity slider — only shown when TTS enabled
            if (_ttsEnabled) Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(Icons.graphic_eq, size: 16, color: Colors.blue.shade700),
                    const SizedBox(width: 6),
                    Text('Voice Sensitivity', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.blue.shade700)),
                    const Spacer(),
                    Text(
                      _ttsSensitivity <= 0.4 ? 'Very Fast' :
                      _ttsSensitivity <= 0.7 ? 'Fast' :
                      _ttsSensitivity <= 1.1 ? 'Normal' :
                      _ttsSensitivity <= 1.6 ? 'Slow' : 'Very Slow',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 6),
                    Text('(${_ttsSensitivity.toStringAsFixed(1)}s)',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                  ]),
                  Slider(
                    value: _ttsSensitivity,
                    min: 0.3,
                    max: 2.0,
                    divisions: 17,
                    activeColor: Colors.blue.shade700,
                    onChanged: (val) => setState(() { _ttsSensitivity = val; }),
                    onChangeEnd: _saveSensitivityPref,
                  ),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text('Fast', style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                    Text('Slow', style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                  ]),
                ]),
              ),
            ),
            const SizedBox(height: 16),

            if (_locked) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.orange.shade300)),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.lock, size: 16, color: Colors.orange.shade700),
                  const SizedBox(width: 6),
                  Text('Locked at ${(_lockedPitch ?? 0).toStringAsFixed(1)}°',
                    style: TextStyle(color: Colors.orange.shade700, fontWeight: FontWeight.w600)),
                ]),
              ),
              const SizedBox(height: 8),
              const Text('Go to Profile Search, find your profile,\nthen tap Save to History + Location to record this pitch.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],

            if (!_locked) ...[
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Container(width: 8, height: 8,
                  decoration: BoxDecoration(color: Colors.green, shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: Colors.green.withOpacity(0.5), blurRadius: 6)])),
                const SizedBox(width: 6),
                const Text('Live reading', style: TextStyle(color: Colors.green, fontSize: 12)),
              ]),
            ],
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Roof Diagram Painter (for pitch finder instructions)
// ═══════════════════════════════════════════════════════════════

class _RoofDiagramPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..strokeWidth = 2.5..style = PaintingStyle.stroke;

    // Draw roof outline
    paint.color = Colors.grey.shade400;
    final roofPath = Path()
      ..moveTo(size.width * 0.1, size.height * 0.8)
      ..lineTo(size.width * 0.5, size.height * 0.15)
      ..lineTo(size.width * 0.9, size.height * 0.8);
    canvas.drawPath(roofPath, paint);

    // Draw phone on left slope
    paint.color = Colors.blue.shade600;
    paint.strokeWidth = 3;
    // Phone rectangle on slope
    final double cx = size.width * 0.27;
    final double cy = size.height * 0.5;
    final double angle = -math.atan2(size.height * 0.65, size.width * 0.4);
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(angle);
    final phoneRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 28, height: 14),
      const Radius.circular(3));
    canvas.drawRRect(phoneRect, paint..style = PaintingStyle.fill..color = Colors.blue.shade100);
    canvas.drawRRect(phoneRect, paint..style = PaintingStyle.stroke..color = Colors.blue.shade700);
    canvas.restore();

    // Angle arc
    paint.color = Colors.orange;
    paint.strokeWidth = 1.5;
    paint.style = PaintingStyle.stroke;
    canvas.drawArc(
      Rect.fromCenter(center: Offset(size.width * 0.1, size.height * 0.8), width: 50, height: 50),
      -math.pi / 2, -math.atan2(size.height * 0.65, size.width * 0.4), false, paint);

    // Angle label
    final tp = TextPainter(
      text: TextSpan(text: '°', style: TextStyle(color: Colors.orange.shade700, fontSize: 14, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr);
    tp.layout();
    tp.paint(canvas, Offset(size.width * 0.1 + 28, size.height * 0.55));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ═══════════════════════════════════════════════════════════════
// Ridge Flashing Diagram Painter
// ═══════════════════════════════════════════════════════════════

class _RidgeDiagramPainter extends CustomPainter {
  final double pitchDeg;
  final double ridgeAngle;

  const _RidgeDiagramPainter({required this.pitchDeg, required this.ridgeAngle});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..strokeWidth = 2.5..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;

    final double cx = size.width / 2;
    final double cy = size.height * 0.4;
    final double slopeLen = size.width * 0.38;
    final double pitchRad = pitchDeg * math.pi / 180;

    // Left and right eave points
    final double lx = cx - slopeLen * math.cos(pitchRad);
    final double ly = cy + slopeLen * math.sin(pitchRad);
    final double rx = cx + slopeLen * math.cos(pitchRad);

    // Draw roof slopes
    paint.color = Colors.grey.shade500;
    paint.strokeWidth = 3;
    canvas.drawLine(Offset(lx, ly), Offset(cx, cy), paint);
    canvas.drawLine(Offset(cx, cy), Offset(rx, ly), paint);

    // Draw ridge flashing overlay (teal)
    paint.color = Colors.teal.shade600;
    paint.strokeWidth = 6;
    final double flashW = 20.0;
    final double flLx = cx - flashW * math.cos(pitchRad);
    final double flLy = cy + flashW * math.sin(pitchRad);
    final double flRx = cx + flashW * math.cos(pitchRad);
    canvas.drawLine(Offset(flLx, flLy), Offset(cx, cy), paint);
    canvas.drawLine(Offset(cx, cy), Offset(flRx, flLy), paint);

    // Ridge angle arc
    paint.color = Colors.teal.shade400;
    paint.strokeWidth = 1.5;
    final double arcR = 28.0;
    canvas.drawArc(
      Rect.fromCenter(center: Offset(cx, cy), width: arcR * 2, height: arcR * 2),
      math.pi + pitchRad,
      math.pi - (2 * pitchRad),
      false,
      paint,
    );

    // Labels
    _drawText(canvas, '${ridgeAngle.toStringAsFixed(0)}°',
      Offset(cx, cy + arcR + 14), Colors.teal.shade800, 13, FontWeight.bold);
    _drawText(canvas, '${pitchDeg.toStringAsFixed(1)}°',
      Offset(lx + 20, ly - 14), Colors.grey.shade700, 11, FontWeight.normal);
    _drawText(canvas, '${pitchDeg.toStringAsFixed(1)}°',
      Offset(rx - 20, ly - 14), Colors.grey.shade700, 11, FontWeight.normal);
    _drawText(canvas, 'Ridge Flashing',
      Offset(cx, cy - 18), Colors.teal.shade700, 11, FontWeight.w600);
  }

  void _drawText(Canvas canvas, String text, Offset position, Color color, double fontSize, FontWeight weight) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: fontSize, fontWeight: weight)),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, Offset(position.dx - tp.width / 2, position.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _RidgeDiagramPainter old) =>
    old.pitchDeg != pitchDeg || old.ridgeAngle != ridgeAngle;
}

// ═══════════════════════════════════════════════════════════════
// Material List Screen — tabbed Industrial / Domestic
// ═══════════════════════════════════════════════════════════════

typedef _MaterialListScreenStateIndustrial = _MaterialListScreenState;
typedef _MaterialListScreenStateDomestic = _DomesticMaterialListState;

class MaterialListScreen extends StatefulWidget {
  const MaterialListScreen({super.key});
  @override
  State<MaterialListScreen> createState() => _MaterialListScreenState2();
}

class _MaterialListScreenState2 extends State<MaterialListScreen> with SingleTickerProviderStateMixin {
  int _saveCount = 0;
  late TabController _tabController;
  final GlobalKey<_MaterialListScreenStateIndustrial> _industrialKey = GlobalKey();
  final GlobalKey<_MaterialListScreenStateDomestic> _domesticKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadCount();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadCount() async {
    final lists = await MaterialListService.loadAll();
    if (mounted) setState(() { _saveCount = lists.length; });
  }

  void _handleMenu(String value) {
    final isIndustrial = _tabController.index == 0;
    switch (value) {
      case 'save':
        if (isIndustrial) _industrialKey.currentState?.saveList();
        else _domesticKey.currentState?.saveList();
        Future.delayed(const Duration(milliseconds: 800), _loadCount);
        break;
      case 'share':
        if (isIndustrial) _industrialKey.currentState?.shareList();
        else _domesticKey.currentState?.shareList();
        break;
      case 'clear':
        if (isIndustrial) _industrialKey.currentState?.clearAll();
        else _domesticKey.currentState?.clearAll();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Material List'),
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
        actions: [
          // Folder icon — view saved lists
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                tooltip: 'View saved lists',
                icon: const Icon(Icons.folder_open),
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const _SavedListsScreen()));
                  _loadCount();
                },
              ),
              if (_saveCount > 0)
                Positioned(
                  top: 6, right: 6,
                  child: Container(
                    width: 16, height: 16,
                    decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle),
                    child: Center(child: Text('$_saveCount',
                      style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.bold))),
                  ),
                ),
            ],
          ),
          // Save icon — save current list
          IconButton(
            tooltip: 'Save list',
            icon: const Icon(Icons.save),
            onPressed: () {
              _handleMenu('save');
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: _handleMenu,
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'save', child: Row(children: [Icon(Icons.save, size: 18), SizedBox(width: 10), Text('Save List')])),
              const PopupMenuItem(value: 'share', child: Row(children: [Icon(Icons.share, size: 18), SizedBox(width: 10), Text('Share')])),
              const PopupMenuItem(value: 'clear', child: Row(children: [Icon(Icons.delete_outline, size: 18, color: Colors.red), SizedBox(width: 10), Text('Clear All', style: TextStyle(color: Colors.red))])),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(icon: Icon(Icons.factory_outlined), text: 'Industrial'),
            Tab(icon: Icon(Icons.home_outlined), text: 'Domestic'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          IndustrialMaterialList(key: _industrialKey),
          DomesticMaterialList(key: _domesticKey),
        ],
      ),
    );
  }
}

class _SavedListsScreen extends StatefulWidget {
  const _SavedListsScreen();
  @override
  State<_SavedListsScreen> createState() => _SavedListsScreenState();
}

class _SavedListsScreenState extends State<_SavedListsScreen> {
  List<Map<String, dynamic>> _lists = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final lists = await MaterialListService.loadAll();
    if (mounted) setState(() { _lists = lists; _loading = false; });
  }

  Future<void> _shareSavedList(Map<String, dynamic> item) async {
    final name = (item['name'] as String?)?.trim().isNotEmpty == true ? item['name'] as String : 'Saved Material List';
    await Share.share(_savedMaterialListToText(item), subject: name, sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1));
  }

  Future<void> _openSavedList(Map<String, dynamic> item) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _SavedMaterialListDetailScreen(savedList: item),
    ));
    _load();
  }

  Future<void> _deleteSavedList(int index, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete List'),
        content: Text('Delete "{name}"?'.replaceFirst('{name}', name)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm == true) {
      await MaterialListService.delete(index);
      if (!mounted) return;
      setState(() { _lists.removeAt(index); });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved list deleted')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Saved Lists (${_lists.length})'),
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _lists.isEmpty
          ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.folder_open, size: 64, color: Colors.grey),
              SizedBox(height: 12),
              Text('No saved lists yet.\nSave a material list using the ⋮ menu.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
            ]))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _lists.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, index) {
                final item = _lists[index];
                final name = item['name'] as String? ?? 'Unnamed';
                final type = item['type'] as String? ?? 'industrial';
                final savedAt = item['savedAt'] as String? ?? '';
                DateTime? dt; try { dt = DateTime.parse(savedAt); } catch (_) {}
                final dateStr = dt != null ? '${dt.day.toString().padLeft(2,'0')}/${dt.month.toString().padLeft(2,'0')}/${dt.year}' : '';
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  leading: Container(
                    width: 44, height: 44,
                    decoration: BoxDecoration(
                      color: type == 'domestic' ? Colors.orange.shade100 : Colors.green.shade100,
                      borderRadius: BorderRadius.circular(8)),
                    child: Icon(
                      type == 'domestic' ? Icons.home : Icons.factory_outlined,
                      color: type == 'domestic' ? Colors.orange.shade700 : Colors.green.shade700,
                      size: 22)),
                  title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${type == 'domestic' ? 'Domestic' : 'Industrial'}${dateStr.isNotEmpty ? ' • $dateStr' : ''}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Share',
                        icon: const Icon(Icons.share_outlined, size: 20),
                        onPressed: () => _shareSavedList(item),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                        onPressed: () => _deleteSavedList(index, name),
                      ),
                      const Icon(Icons.arrow_forward_ios, size: 16),
                    ],
                  ),
                  onTap: () => _openSavedList(item),
                );
              },
            ),
    );
  }
}

String _savedMaterialListToText(Map<String, dynamic> data) {
  final sb = StringBuffer();
  final type = (data['type'] as String? ?? 'industrial').toLowerCase();
  final name = (data['name'] as String?)?.trim();
  final buildingName = (data['buildingName'] as String?)?.trim();
  final savedAt = data['savedAt'] as String? ?? '';
  DateTime? dt;
  try { dt = DateTime.parse(savedAt); } catch (_) {}
  final dateStr = dt != null
      ? '${dt.day.toString().padLeft(2,'0')}/${dt.month.toString().padLeft(2,'0')}/${dt.year}'
      : '';

  void writeSection(String title, List<String> lines) {
    final nonEmpty = lines.where((e) => e.trim().isNotEmpty).toList();
    if (nonEmpty.isEmpty) return;
    sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
    sb.writeln(title);
    sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
    for (final line in nonEmpty) {
      sb.writeln(line);
    }
    sb.writeln('');
  }

  if (type == 'domestic') {
    sb.writeln('╔══════════════════════════╗');
    sb.writeln('║  🏠 DOMESTIC ROOF LIST   ║');
    sb.writeln('╚══════════════════════════╝');
  } else {
    sb.writeln('╔══════════════════════════╗');
    sb.writeln('║  🏭 INDUSTRIAL ROOF LIST ║');
    sb.writeln('╚══════════════════════════╝');
  }
  if (name != null && name.isNotEmpty) sb.writeln('📝 Name: $name');
  if (buildingName != null && buildingName.isNotEmpty) sb.writeln('📍 Job:  $buildingName');
  if (dateStr.isNotEmpty) sb.writeln('📅 Date: $dateStr');
  sb.writeln('');

  if (type == 'domestic') {
    final tiles = (data['tiles'] as List?)?.cast<Map>() ?? const [];
    writeSection('🏠 TILES / SLATES', [
      for (final i in tiles)
        if ((i['qty'] ?? '').toString().isNotEmpty || (i['material'] ?? '').toString().isNotEmpty)
          '• ${((i['material'] ?? '').toString().isNotEmpty ? i['material'] : 'Tile')}${(i['qty'] ?? '').toString().isNotEmpty ? ' — Qty: ${i['qty']}' : ''}${(i['size'] ?? '').toString().isNotEmpty ? ' | Size: ${i['size']}' : ''}',
    ]);
    writeSection('🛡️ UNDERLAY / WATERPROOFING', [
      if ((data['epdm'] ?? '').toString().isNotEmpty) '• EPDM: ${data['epdm']} m²',
      if ((data['felt'] ?? '').toString().isNotEmpty) '• Felt: ${data['felt']} rolls',
      if ((data['adhesive'] ?? '').toString().isNotEmpty) '• Adhesive: ${data['adhesive']} litres',
      if ((data['primer'] ?? '').toString().isNotEmpty) '• Primer: ${data['primer']} litres',
    ]);
    writeSection('🪵 BATTENS', [
      if ((data['battens'] ?? '').toString().isNotEmpty) '• Battens: ${data['battens']} m',
      if ((data['battenSpacing'] ?? '').toString().isNotEmpty) '• Spacing: ${data['battenSpacing']} mm',
    ]);
    writeSection('🔩 FIXINGS', [
      if ((data['nails'] ?? '').toString().isNotEmpty) '• Nails: ${data['nails']}',
      if ((data['screws'] ?? '').toString().isNotEmpty) '• Screws: ${data['screws']}',
    ]);
    final flashings = (data['flashings'] as List?)?.cast<Map>() ?? const [];
    writeSection('⚡ FLASHINGS', [
      for (final i in flashings)
        if ((i['type'] ?? '').toString().isNotEmpty || (i['qty'] ?? '').toString().isNotEmpty)
          '• ${((i['type'] ?? '').toString().isNotEmpty ? i['type'] : 'Flashing')}${(i['qty'] ?? '').toString().isNotEmpty ? ' — Qty: ${i['qty']}' : ''}${(i['size'] ?? '').toString().isNotEmpty ? ' | Size: ${i['size']}' : ''}${(i['colour'] ?? '').toString().isNotEmpty ? ' | ${i['colour']}' : ''}${(i['material'] ?? '').toString().isNotEmpty ? ' | ${i['material']}' : ''}',
    ]);
    final ridges = (data['ridges'] as List?)?.cast<Map>() ?? const [];
    final hips = (data['hips'] as List?)?.cast<Map>() ?? const [];
    final valleys = (data['valleys'] as List?)?.cast<Map>() ?? const [];
    writeSection('🔺 RIDGE / HIP / VALLEY', [
      for (final i in ridges)
        if ((i['qty'] ?? '').toString().isNotEmpty) '• Ridge — Qty: ${i['qty']}${(i['size'] ?? '').toString().isNotEmpty ? ' | ${i['size']}' : ''}',
      for (final i in hips)
        if ((i['qty'] ?? '').toString().isNotEmpty) '• Hip — Qty: ${i['qty']}${(i['size'] ?? '').toString().isNotEmpty ? ' | ${i['size']}' : ''}',
      for (final i in valleys)
        if ((i['length'] ?? '').toString().isNotEmpty) '• Valley — ${i['length']}m${(i['type'] ?? '').toString().isNotEmpty ? ' | ${i['type']}' : ''}${(i['size'] ?? '').toString().isNotEmpty ? ' | ${i['size']}' : ''}',
    ]);
    writeSection('🧰 EXTRAS / SAFETY', [
      if ((data['vents'] ?? '').toString().isNotEmpty) '• Vents: ${data['vents']}${(data['ventsType'] ?? '').toString().isNotEmpty ? ' | ${data['ventsType']}' : ''}',
      if ((data['rooflights'] ?? '').toString().isNotEmpty) '• Rooflights: ${data['rooflights']}${(data['rooflightsSize'] ?? '').toString().isNotEmpty ? ' | ${data['rooflightsSize']}' : ''}',
      if ((data['guttering'] ?? '').toString().isNotEmpty) '• Guttering: ${data['guttering']} m',
      if ((data['downpipes'] ?? '').toString().isNotEmpty) '• Downpipes: ${data['downpipes']}',
      if ((data['scaffolding'] ?? '').toString().isNotEmpty) '• Scaffolding: ${data['scaffolding']}',
      if ((data['netting'] ?? '').toString().isNotEmpty) '• Netting: ${data['netting']}',
      if ((data['plant'] ?? '').toString().isNotEmpty) '• Plant: ${data['plant']}',
    ]);
  } else {
    final sheets = (data['sheets'] as List?)?.cast<Map>() ?? const [];
    writeSection('📦 ROOFING MATERIALS', [
      for (final i in sheets)
        if ((i['qty'] ?? '').toString().isNotEmpty || (i['length'] ?? '').toString().isNotEmpty || (i['material'] ?? '').toString().isNotEmpty)
          '• ${((i['material'] ?? '').toString().isNotEmpty ? i['material'] : 'Sheet')}${(i['qty'] ?? '').toString().isNotEmpty ? ' — Qty: ${i['qty']}' : ''}${(i['length'] ?? '').toString().isNotEmpty ? ' | Length: ${i['length']}m' : ''}',
      if ((data['insulation'] ?? '').toString().isNotEmpty) '• Insulation: ${data['insulation']} m²',
      if ((data['felt'] ?? '').toString().isNotEmpty) '• Felt / Underlay: ${data['felt']} rolls',
      if ((data['battens'] ?? '').toString().isNotEmpty) '• Battens: ${data['battens']} m',
      if ((data['spacingBars'] ?? '').toString().isNotEmpty) '• Spacing Bars: ${data['spacingBars']}',
    ]);
    final fixings = (data['fixings'] as List?)?.cast<Map>() ?? const [];
    writeSection('🔩 FIXINGS', [
      for (final i in fixings)
        if ((i['head'] ?? '').toString().isNotEmpty || (i['qty'] ?? '').toString().isNotEmpty)
          '• ${((i['head'] ?? '').toString().isNotEmpty ? i['head'] : 'Fixing')}${(i['length'] ?? '').toString().isNotEmpty ? ' ${i['length']}mm' : ''}${(i['washer'] ?? '').toString().isNotEmpty ? ' | Washer: ${i['washer']}' : ''}${(i['qty'] ?? '').toString().isNotEmpty ? ' | Qty: ${i['qty']}' : ''}',
      if ((data['rafterFixings'] ?? '').toString().isNotEmpty) '• Rafter Fixings: ${data['rafterFixings']}',
    ]);
    final flashings = (data['flashings'] as List?)?.cast<Map>() ?? const [];
    writeSection('⚡ FLASHINGS', [
      for (final i in flashings)
        if ((i['type'] ?? '').toString().isNotEmpty || (i['qty'] ?? '').toString().isNotEmpty)
          '• ${((i['type'] ?? '').toString().isNotEmpty ? i['type'] : 'Flashing')}${(i['qty'] ?? '').toString().isNotEmpty ? ' — Qty: ${i['qty']}' : ''}${(i['colour'] ?? '').toString().isNotEmpty ? ' | ${i['colour']}' : ''}${(i['material'] ?? '').toString().isNotEmpty ? ' | ${i['material']}' : ''}',
    ]);
    writeSection('🧰 EXTRAS', [
      if ((data['sealants'] ?? '').toString().isNotEmpty) '• Sealants: ${data['sealants']} tubes',
      if ((data['fillerBlocks'] ?? '').toString().isNotEmpty) '• Filler Blocks: ${data['fillerBlocks']}',
      if ((data['vents'] ?? '').toString().isNotEmpty) '• Vents: ${data['vents']}',
      if ((data['guttering'] ?? '').toString().isNotEmpty) '• Guttering: ${data['guttering']} m',
      if ((data['downpipes'] ?? '').toString().isNotEmpty) '• Downpipes: ${data['downpipes']}',
    ]);
  }

  if ((data['notes'] ?? '').toString().trim().isNotEmpty) {
    writeSection('📝 NOTES', [data['notes'].toString()]);
  }

  sb.writeln('──────────────────────────');
  sb.writeln('Generated by Roof Profile Finder');
  return sb.toString();
}

class _SavedMaterialListDetailScreen extends StatelessWidget {
  final Map<String, dynamic> savedList;
  const _SavedMaterialListDetailScreen({required this.savedList});

  @override
  Widget build(BuildContext context) {
    final name = (savedList['name'] as String?)?.trim().isNotEmpty == true
        ? savedList['name'] as String
        : 'Saved Material List';
    final text = _savedMaterialListToText(savedList);
    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share_outlined),
            onPressed: () => Share.share(text, subject: name, sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1)),
          ),
        ],
      ),
      body: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: SelectableText(
            text,
            style: const TextStyle(fontSize: 14, height: 1.45),
          ),
        ),
      ),
    );
  }
}

class _SheetItem {
  final TextEditingController qtyController;
  final TextEditingController lengthController;
  final TextEditingController materialController;
  _SheetItem() : qtyController = TextEditingController(),
                 lengthController = TextEditingController(),
                 materialController = TextEditingController();
  void dispose() { qtyController.dispose(); lengthController.dispose(); materialController.dispose(); }
}

class _FixingItem {
  final TextEditingController headController;
  final TextEditingController lengthController;
  final TextEditingController washerController;
  final TextEditingController qtyController;
  _FixingItem() : headController = TextEditingController(),
                  lengthController = TextEditingController(),
                  washerController = TextEditingController(),
                  qtyController = TextEditingController();
  void dispose() { headController.dispose(); lengthController.dispose(); washerController.dispose(); qtyController.dispose(); }
}

class _FlashingItem {
  final TextEditingController typeController;
  final TextEditingController qtyController;
  final TextEditingController colourController;
  final TextEditingController materialController;
  _FlashingItem() : typeController = TextEditingController(),
                    qtyController = TextEditingController(),
                    colourController = TextEditingController(),
                    materialController = TextEditingController();
  void dispose() { typeController.dispose(); qtyController.dispose(); colourController.dispose(); materialController.dispose(); }
}

class IndustrialMaterialList extends StatefulWidget {
  const IndustrialMaterialList({super.key});
  @override
  State<IndustrialMaterialList> createState() => _MaterialListScreenState();
}

class _MaterialListScreenState extends State<IndustrialMaterialList> {
  final _buildingController = TextEditingController();
  final _notesController = TextEditingController();

  // Roofing — dynamic sheet items
  final List<_SheetItem> _sheetItems = [_SheetItem()];

  // Roofing other
  final _insulationController = TextEditingController();
  final _feltController = TextEditingController();
  final _battensController = TextEditingController();
  final _spacingBarsController = TextEditingController();

  // Fixings — dynamic
  final List<_FixingItem> _fixingItems = [_FixingItem()];
  final _rafterFixingsController = TextEditingController();

  // Flashings — dynamic
  final List<_FlashingItem> _flashingItems = [_FlashingItem()];

  // Extras
  final _sealantsController = TextEditingController();
  final _fillerBlocksController = TextEditingController();
  final _ventsController = TextEditingController();
  final _gutteringController = TextEditingController();
  final _downpipesController = TextEditingController();

  static InputDecoration _hintDec(String hint, {String? suffix}) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12),
    suffixText: suffix,
    border: const OutlineInputBorder(),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
  );

  String _date = '';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _date = '${now.day.toString().padLeft(2,'0')}/${now.month.toString().padLeft(2,'0')}/${now.year}';
  }

  @override
  void dispose() {
    for (final item in _sheetItems) { item.dispose(); }
    for (final item in _fixingItems) { item.dispose(); }
    for (final item in _flashingItems) { item.dispose(); }
    for (final c in [_buildingController, _notesController,
      _insulationController, _feltController, _battensController, _spacingBarsController,
      _rafterFixingsController,
      _sealantsController, _fillerBlocksController, _ventsController,
      _gutteringController, _downpipesController]) { c.dispose(); }
    super.dispose();
  }

  void _clearAll() {
    showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Clear All'),
      content: const Text('Clear all fields and start a new list?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear', style: TextStyle(color: Colors.red))),
      ],
    )).then((confirm) {
      if (confirm == true) {
        for (final item in _sheetItems) { item.dispose(); }
        _sheetItems.clear();
        _sheetItems.add(_SheetItem());
        for (final item in _fixingItems) { item.dispose(); }
        _fixingItems.clear();
        _fixingItems.add(_FixingItem());
        for (final item in _flashingItems) { item.dispose(); }
        _flashingItems.clear();
        _flashingItems.add(_FlashingItem());
        for (final c in [_buildingController, _notesController,
          _insulationController, _feltController, _battensController, _spacingBarsController,
          _rafterFixingsController,
          _sealantsController, _fillerBlocksController, _ventsController,
          _gutteringController, _downpipesController]) { c.clear(); }
        setState(() {});
      }
    });
  }

  void saveList() => _saveList();
  void exportPdf() => _exportPdf();
  void shareList() => _shareList();
  void clearAll() => _clearAll();

  Map<String, dynamic> _collectData() {
    return {
      'savedAt': DateTime.now().toIso8601String(),
      'buildingName': _buildingController.text,
      'notes': _notesController.text,
      'insulation': _insulationController.text,
      'felt': _feltController.text,
      'battens': _battensController.text,
      'spacingBars': _spacingBarsController.text,
      'rafterFixings': _rafterFixingsController.text,
      'sealants': _sealantsController.text,
      'fillerBlocks': _fillerBlocksController.text,
      'vents': _ventsController.text,
      'guttering': _gutteringController.text,
      'downpipes': _downpipesController.text,
      'sheets': _sheetItems.map((i) => {'qty': i.qtyController.text, 'length': i.lengthController.text, 'material': i.materialController.text}).toList(),
      'fixings': _fixingItems.map((i) => {'head': i.headController.text, 'length': i.lengthController.text, 'washer': i.washerController.text, 'qty': i.qtyController.text}).toList(),
      'flashings': _flashingItems.map((i) => {'type': i.typeController.text, 'qty': i.qtyController.text, 'colour': i.colourController.text, 'material': i.materialController.text}).toList(),
    };
  }

  void _loadData(Map<String, dynamic> data) {
    _buildingController.text = data['buildingName'] ?? '';
    _notesController.text = data['notes'] ?? '';
    _insulationController.text = data['insulation'] ?? '';
    _feltController.text = data['felt'] ?? '';
    _battensController.text = data['battens'] ?? '';
    _spacingBarsController.text = data['spacingBars'] ?? '';
    _rafterFixingsController.text = data['rafterFixings'] ?? '';
    _sealantsController.text = data['sealants'] ?? '';
    _fillerBlocksController.text = data['fillerBlocks'] ?? '';
    _ventsController.text = data['vents'] ?? '';
    _gutteringController.text = data['guttering'] ?? '';
    _downpipesController.text = data['downpipes'] ?? '';
    // Sheets
    for (final item in _sheetItems) { item.dispose(); }
    _sheetItems.clear();
    final sheets = data['sheets'] as List<dynamic>? ?? [];
    if (sheets.isEmpty) { _sheetItems.add(_SheetItem()); }
    else { for (final s in sheets) { final i = _SheetItem(); i.qtyController.text = s['qty'] ?? ''; i.lengthController.text = s['length'] ?? ''; i.materialController.text = s['material'] ?? ''; _sheetItems.add(i); } }
    // Fixings
    for (final item in _fixingItems) { item.dispose(); }
    _fixingItems.clear();
    final fixings = data['fixings'] as List<dynamic>? ?? [];
    if (fixings.isEmpty) { _fixingItems.add(_FixingItem()); }
    else { for (final f in fixings) { final i = _FixingItem(); i.headController.text = f['head'] ?? ''; i.lengthController.text = f['length'] ?? ''; i.washerController.text = f['washer'] ?? ''; i.qtyController.text = f['qty'] ?? ''; _fixingItems.add(i); } }
    // Flashings
    for (final item in _flashingItems) { item.dispose(); }
    _flashingItems.clear();
    final flashings = data['flashings'] as List<dynamic>? ?? [];
    if (flashings.isEmpty) { _flashingItems.add(_FlashingItem()); }
    else { for (final f in flashings) { final i = _FlashingItem(); i.typeController.text = f['type'] ?? ''; i.qtyController.text = f['qty'] ?? ''; i.colourController.text = f['colour'] ?? ''; i.materialController.text = f['material'] ?? ''; _flashingItems.add(i); } }
    setState(() {});
  }

  Future<void> _saveList() async {
    final autoName = _buildingController.text.trim().isNotEmpty
      ? _buildingController.text.trim()
      : 'List ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}';
    final nameController = TextEditingController(text: autoName);
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Save Material List'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Enter a name for this list:'),
        const SizedBox(height: 12),
        TextField(controller: nameController, textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(border: OutlineInputBorder(), prefixIcon: Icon(Icons.list_alt)),
          autofocus: true),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white),
          child: const Text('Save')),
      ],
    ));
    if (confirm != true) return;
    final data = _collectData();
    data['type'] = 'industrial';
    data['name'] = nameController.text.trim().isNotEmpty ? nameController.text.trim() : autoName;
    await MaterialListService.save(data);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('✓ Saved: ${data['name']}'),
      backgroundColor: Colors.green.shade700,
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _openSavedLists() async {
    final lists = await MaterialListService.loadAll();
    if (!mounted) return;
    if (lists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No saved lists yet. Fill in a list and tap Save.')));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.4,
          expand: false,
          builder: (ctx, scrollController) => Column(children: [
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                const Icon(Icons.folder_open, color: Colors.green),
                const SizedBox(width: 8),
                const Expanded(child: Text('Saved Lists', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
              ]),
            ),
            const Divider(height: 1),
            Expanded(child: ListView.separated(
              controller: scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: lists.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, index) {
                final item = lists[index];
                final name = item['name'] as String? ?? 'Unnamed';
                final savedAt = item['savedAt'] as String? ?? '';
                DateTime? dt; try { dt = DateTime.parse(savedAt); } catch (_) {}
                final dateStr = dt != null ? '${dt.day.toString().padLeft(2,'0')}/${dt.month.toString().padLeft(2,'0')}/${dt.year}' : '';
                return ListTile(
                  leading: Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(color: Colors.green.shade100, borderRadius: BorderRadius.circular(8)),
                    child: Icon(Icons.list_alt, color: Colors.green.shade700, size: 22),
                  ),
                  title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(dateStr, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                    onPressed: () async {
                      final confirm = await showDialog<bool>(context: ctx, builder: (d) => AlertDialog(
                        title: const Text('Delete List'),
                        content: Text('Delete "$name"?'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
                        ],
                      ));
                      if (confirm == true) {
                        await MaterialListService.delete(index);
                        lists.removeAt(index);
                        setSheetState(() {});
                      }
                    },
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _loadData(item);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('Loaded: $name'),
                      backgroundColor: Colors.green.shade700,
                      duration: const Duration(seconds: 2),
                    ));
                  },
                );
              },
            )),
          ]),
        ),
      ),
    );
  }

  Future<void> _exportPdf() async {
    try {
      final StringBuffer sb = StringBuffer();
      for (int i = 0; i < _sheetItems.length; i++) {
        final item = _sheetItems[i];
        if (item.qtyController.text.isNotEmpty || item.lengthController.text.isNotEmpty) {
          sb.writeln('${item.materialController.text.isNotEmpty ? item.materialController.text : 'Sheet ${i+1}'}: Qty ${item.qtyController.text} x ${item.lengthController.text}m');
        }
      }
      if (_insulationController.text.isNotEmpty) sb.writeln('Insulation: ${_insulationController.text} m2');
      if (_feltController.text.isNotEmpty) sb.writeln('Felt/Underlay: ${_feltController.text} rolls');
      if (_battensController.text.isNotEmpty) sb.writeln('Battens: ${_battensController.text} m');
      if (_spacingBarsController.text.isNotEmpty) sb.writeln('Spacing Bars: ${_spacingBarsController.text}');
      sb.writeln('');
      bool hasFixings = _fixingItems.any((i) => i.headController.text.isNotEmpty || i.qtyController.text.isNotEmpty);
      if (hasFixings) {
        sb.writeln('FIXINGS');
        for (final f in _fixingItems) {
          if (f.headController.text.isNotEmpty || f.qtyController.text.isNotEmpty) {
            sb.writeln('${f.headController.text} ${f.lengthController.text}mm - Qty: ${f.qtyController.text}');
          }
        }
        sb.writeln('');
      }
      bool hasFlashings = _flashingItems.any((i) => i.typeController.text.isNotEmpty || i.qtyController.text.isNotEmpty);
      if (hasFlashings) {
        sb.writeln('FLASHINGS');
        for (final f in _flashingItems) {
          if (f.typeController.text.isNotEmpty || f.qtyController.text.isNotEmpty) {
            sb.writeln('${f.typeController.text}: Qty ${f.qtyController.text} ${f.colourController.text} ${f.materialController.text}');
          }
        }
        sb.writeln('');
      }
      if (_sealantsController.text.isNotEmpty) sb.writeln('Sealants: ${_sealantsController.text} tubes');
      if (_fillerBlocksController.text.isNotEmpty) sb.writeln('Filler Blocks: ${_fillerBlocksController.text}');
      if (_ventsController.text.isNotEmpty) sb.writeln('Vents: ${_ventsController.text}');
      if (_gutteringController.text.isNotEmpty) sb.writeln('Guttering: ${_gutteringController.text} m');
      if (_downpipesController.text.isNotEmpty) sb.writeln('Downpipes: ${_downpipesController.text}');
      if (_notesController.text.isNotEmpty) { sb.writeln(''); sb.writeln('NOTES'); sb.writeln(_notesController.text); }
      final pdfBytes = await PdfService.generateMaterialPdf(
        buildingName: _buildingController.text,
        date: _date,
        type: 'Industrial',
        content: sb.toString(),
      );
      await Share.shareXFiles(
        [XFile.fromData(pdfBytes, name: 'industrial_list_${DateTime.now().millisecondsSinceEpoch}.pdf', mimeType: 'application/pdf')],
        subject: 'Industrial Material List',
        sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF failed: $e'), backgroundColor: Colors.red));
    }
  }

  void _shareList() {
    final StringBuffer sb = StringBuffer();
    sb.writeln('╔══════════════════════════╗');
    sb.writeln('║  🏠 ROOF MATERIAL LIST   ║');
    sb.writeln('╚══════════════════════════╝');
    if (_buildingController.text.isNotEmpty) sb.writeln('📍 Job:  ${_buildingController.text}');
    sb.writeln('📅 Date: $_date');
    sb.writeln('');

    bool hasSheets = _sheetItems.any((i) => i.qtyController.text.isNotEmpty || i.lengthController.text.isNotEmpty);
    bool hasInsulation = _insulationController.text.isNotEmpty;
    bool hasFelt = _feltController.text.isNotEmpty;
    bool hasBattens = _battensController.text.isNotEmpty;
    bool hasSpacing = _spacingBarsController.text.isNotEmpty;

    if (hasSheets || hasInsulation || hasFelt || hasBattens || hasSpacing) {
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      sb.writeln('📦 ROOFING MATERIALS');
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      for (int i = 0; i < _sheetItems.length; i++) {
        final item = _sheetItems[i];
        final qty = item.qtyController.text;
        final len = item.lengthController.text;
        final mat = item.materialController.text;
        if (qty.isNotEmpty || len.isNotEmpty) {
          sb.writeln('  • ${mat.isNotEmpty ? mat : 'Sheet ${i+1}'}');
          sb.writeln('    Qty: ${qty.isNotEmpty ? qty : '-'}  |  Length: ${len.isNotEmpty ? '${len}m' : '-'}');
        }
      }
      if (hasInsulation) sb.writeln('  • Insulation:     ${_insulationController.text} m²');
      if (hasFelt) sb.writeln('  • Felt/Underlay:  ${_feltController.text} rolls');
      if (hasBattens) sb.writeln('  • Battens:        ${_battensController.text} m');
      if (hasSpacing) sb.writeln('  • Spacing Bars:   ${_spacingBarsController.text}');
      sb.writeln('');
    }

    bool hasFixings = _fixingItems.any((i) => i.headController.text.isNotEmpty || i.qtyController.text.isNotEmpty);
    if (hasFixings || _rafterFixingsController.text.isNotEmpty) {
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      sb.writeln('🔩 FIXINGS');
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      for (final item in _fixingItems) {
        final head = item.headController.text;
        final len = item.lengthController.text;
        final washer = item.washerController.text;
        final qty = item.qtyController.text;
        if (head.isNotEmpty || qty.isNotEmpty) {
          sb.writeln('  • ${head.isNotEmpty ? head : 'Fixing'}${len.isNotEmpty ? ' ${len}mm' : ''}');
          if (washer.isNotEmpty) sb.writeln('    Washer: $washer');
          sb.writeln('    Qty: ${qty.isNotEmpty ? qty : '-'}');
        }
      }
      if (_rafterFixingsController.text.isNotEmpty) sb.writeln('  • Rafter Fixings: ${_rafterFixingsController.text}');
      sb.writeln('');
    }

    bool hasFlashings = _flashingItems.any((i) => i.typeController.text.isNotEmpty || i.qtyController.text.isNotEmpty);
    if (hasFlashings) {
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      sb.writeln('⚡ FLASHINGS');
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      for (final item in _flashingItems) {
        final type = item.typeController.text;
        final qty = item.qtyController.text;
        final colour = item.colourController.text;
        final material = item.materialController.text;
        if (type.isNotEmpty || qty.isNotEmpty) {
          sb.writeln('  • ${type.isNotEmpty ? type : 'Flashing'}');
          sb.writeln('    Qty: ${qty.isNotEmpty ? qty : '-'}${colour.isNotEmpty ? '  |  Colour: $colour' : ''}${material.isNotEmpty ? '  |  Material: $material' : ''}');
        }
      }
      sb.writeln('');
    }

    bool hasExtras = [_sealantsController, _fillerBlocksController, _ventsController, _gutteringController, _downpipesController].any((c) => c.text.isNotEmpty);
    if (hasExtras) {
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      sb.writeln('🛠️  EXTRAS');
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      if (_sealantsController.text.isNotEmpty) sb.writeln('  • Sealants:      ${_sealantsController.text} tubes');
      if (_fillerBlocksController.text.isNotEmpty) sb.writeln('  • Filler Blocks: ${_fillerBlocksController.text} qty');
      if (_ventsController.text.isNotEmpty) sb.writeln('  • Vents:         ${_ventsController.text} qty');
      if (_gutteringController.text.isNotEmpty) sb.writeln('  • Guttering:     ${_gutteringController.text} m');
      if (_downpipesController.text.isNotEmpty) sb.writeln('  • Downpipes:     ${_downpipesController.text} qty');
      sb.writeln('');
    }

    if (_notesController.text.isNotEmpty) {
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      sb.writeln('📝 NOTES');
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      sb.writeln(_notesController.text);
      sb.writeln('');
    }

    sb.writeln('──────────────────────────');
    sb.writeln('Generated by Roof Profile Finder');
    Share.share(sb.toString(), subject: 'Material List - ${_buildingController.text.isNotEmpty ? _buildingController.text : _date}', sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1));
  }

  Widget _sectionHeader(String title, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 10),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }

  Widget _field(String label, TextEditingController controller, {String? suffix, String? hint, TextInputType? keyboardType, bool isLabel = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Expanded(flex: 3, child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(flex: 2, child: TextField(
          controller: controller,
          keyboardType: keyboardType ?? (isLabel ? TextInputType.text : const TextInputType.numberWithOptions(decimal: true)),
          textCapitalization: isLabel ? TextCapitalization.words : TextCapitalization.none,
          decoration: InputDecoration(
            hintText: hint ?? (isLabel ? 'Label' : '0'),
            hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12),
            suffixText: suffix,
            border: const OutlineInputBorder(),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          ),
        )),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header
          Card(color: Colors.green.shade50, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: _buildingController,
                textCapitalization: TextCapitalization.words,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  hintText: 'Building / Job Name',
                  border: InputBorder.none,
                  prefixIcon: Icon(Icons.home_work_outlined),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 12),
                child: Text('Date: $_date', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
              ),
            ])),
          ),

          // Roofing Materials
          _sectionHeader('Roofing Materials', Icons.roofing, Colors.blue.shade700),
          // Column headers
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              const Expanded(flex: 2, child: Text('Qty', style: TextStyle(fontSize: 12, color: Colors.grey))),
              const SizedBox(width: 6),
              const Expanded(flex: 2, child: Text('Length (m)', style: TextStyle(fontSize: 12, color: Colors.grey))),
              const SizedBox(width: 6),
              const Expanded(flex: 3, child: Text('Material', style: TextStyle(fontSize: 12, color: Colors.grey))),
              const SizedBox(width: 32),
            ]),
          ),
          // Dynamic sheet rows
          ..._sheetItems.asMap().entries.map((entry) {
            final i = entry.key;
            final item = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(flex: 2, child: TextField(
                  controller: item.qtyController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _hintDec('0'),
                )),
                const SizedBox(width: 6),
                Expanded(flex: 2, child: TextField(
                  controller: item.lengthController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _hintDec('0.0'),
                )),
                const SizedBox(width: 6),
                Expanded(flex: 3, child: TextField(
                  controller: item.materialController,
                  textCapitalization: TextCapitalization.words,
                  decoration: _hintDec('Steel'),
                )),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: _sheetItems.length > 1 ? () => setState(() { _sheetItems[i].dispose(); _sheetItems.removeAt(i); }) : null,
                  icon: Icon(Icons.remove_circle_outline, color: _sheetItems.length > 1 ? Colors.red : Colors.grey, size: 22),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                ),
              ]),
            );
          }),
          // Add row button
          TextButton.icon(
            onPressed: () => setState(() { _sheetItems.add(_SheetItem()); }),
            icon: const Icon(Icons.add_circle_outline, size: 18),
            label: const Text('Add row'),
            style: TextButton.styleFrom(foregroundColor: Colors.blue.shade700),
          ),
          const SizedBox(height: 4),
          _field('Insulation', _insulationController, suffix: 'm²'),
          _field('Felt / Underlay', _feltController, suffix: 'rolls'),
          _field('Battens', _battensController, suffix: 'm'),
          _field('Spacing Bars', _spacingBarsController, suffix: 'qty'),

          // Fixings
          _sectionHeader('Fixings', Icons.settings, Colors.orange.shade700),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              const Expanded(flex: 2, child: Text('Head', style: TextStyle(fontSize: 12, color: Colors.grey))),
              const SizedBox(width: 4),
              const Expanded(flex: 2, child: Text('Length', style: TextStyle(fontSize: 12, color: Colors.grey))),
              const SizedBox(width: 4),
              const Expanded(flex: 2, child: Text('Washer', style: TextStyle(fontSize: 12, color: Colors.grey))),
              const SizedBox(width: 4),
              const Expanded(flex: 2, child: Text('Qty', style: TextStyle(fontSize: 12, color: Colors.grey))),
              const SizedBox(width: 32),
            ]),
          ),
          ..._fixingItems.asMap().entries.map((entry) {
            final i = entry.key;
            final item = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(flex: 2, child: TextField(controller: item.headController,
                  textCapitalization: TextCapitalization.words,
                  decoration: _hintDec('Hex'))),
                const SizedBox(width: 4),
                Expanded(flex: 2, child: TextField(controller: item.lengthController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _hintDec('51mm'))),
                const SizedBox(width: 4),
                Expanded(flex: 2, child: TextField(controller: item.washerController,
                  textCapitalization: TextCapitalization.words,
                  decoration: _hintDec('EPDM'))),
                const SizedBox(width: 4),
                Expanded(flex: 2, child: TextField(controller: item.qtyController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: false),
                  decoration: _hintDec('0'))),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: _fixingItems.length > 1 ? () => setState(() { _fixingItems[i].dispose(); _fixingItems.removeAt(i); }) : null,
                  icon: Icon(Icons.remove_circle_outline, color: _fixingItems.length > 1 ? Colors.red : Colors.grey, size: 20),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints()),
              ]),
            );
          }),
          TextButton.icon(
            onPressed: () => setState(() { _fixingItems.add(_FixingItem()); }),
            icon: const Icon(Icons.add_circle_outline, size: 18),
            label: const Text('Add fixing'),
            style: TextButton.styleFrom(foregroundColor: Colors.orange.shade700),
          ),
          const SizedBox(height: 4),
          _field('Rafter Fixings', _rafterFixingsController, suffix: 'qty'),

          // Flashings
          _sectionHeader('Flashings', Icons.water, Colors.purple.shade700),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              const Expanded(flex: 3, child: Text('Type', style: TextStyle(fontSize: 12, color: Colors.grey))),
              const SizedBox(width: 4),
              const Expanded(flex: 2, child: Text('Qty', style: TextStyle(fontSize: 12, color: Colors.grey))),
              const SizedBox(width: 4),
              const Expanded(flex: 2, child: Text('Colour', style: TextStyle(fontSize: 12, color: Colors.grey))),
              const SizedBox(width: 4),
              const Expanded(flex: 2, child: Text('Material', style: TextStyle(fontSize: 12, color: Colors.grey))),
              const SizedBox(width: 32),
            ]),
          ),
          ..._flashingItems.asMap().entries.map((entry) {
            final i = entry.key;
            final item = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(flex: 3, child: TextField(controller: item.typeController,
                  textCapitalization: TextCapitalization.words,
                  decoration: _hintDec('Ridge'))),
                const SizedBox(width: 4),
                Expanded(flex: 2, child: TextField(controller: item.qtyController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _hintDec('0'))),
                const SizedBox(width: 4),
                Expanded(flex: 2, child: TextField(controller: item.colourController,
                  textCapitalization: TextCapitalization.words,
                  decoration: _hintDec('Grey'))),
                const SizedBox(width: 4),
                Expanded(flex: 2, child: TextField(controller: item.materialController,
                  textCapitalization: TextCapitalization.words,
                  decoration: _hintDec('Steel'))),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: _flashingItems.length > 1 ? () => setState(() { _flashingItems[i].dispose(); _flashingItems.removeAt(i); }) : null,
                  icon: Icon(Icons.remove_circle_outline, color: _flashingItems.length > 1 ? Colors.red : Colors.grey, size: 20),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints()),
              ]),
            );
          }),
          TextButton.icon(
            onPressed: () => setState(() { _flashingItems.add(_FlashingItem()); }),
            icon: const Icon(Icons.add_circle_outline, size: 18),
            label: const Text('Add flashing'),
            style: TextButton.styleFrom(foregroundColor: Colors.purple.shade700),
          ),
          const SizedBox(height: 4),

          // Extras
          _sectionHeader('Extras', Icons.construction, Colors.red.shade700),
          _field('Sealants', _sealantsController, suffix: 'tubes'),
          _field('Filler Blocks', _fillerBlocksController, suffix: 'qty'),
          _field('Vents', _ventsController, suffix: 'qty'),
          _field('Guttering', _gutteringController, suffix: 'm'),
          _field('Downpipes', _downpipesController, suffix: 'qty'),

          // Notes
          _sectionHeader('Notes', Icons.notes, Colors.grey.shade700),
          TextField(
            controller: _notesController,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'Any additional notes for this job...',
              border: OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: 24),
          SizedBox(width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _shareList,
              icon: const Icon(Icons.share),
              label: const Text('Share Material List'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _clearAll,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Clear All Fields'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const SizedBox(height: 30),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Domestic Material List
// ═══════════════════════════════════════════════════════════════

class _TileItem {
  final TextEditingController qtyController;
  final TextEditingController sizeController;
  final TextEditingController materialController;
  _TileItem() : qtyController = TextEditingController(), sizeController = TextEditingController(), materialController = TextEditingController();
  void dispose() { qtyController.dispose(); sizeController.dispose(); materialController.dispose(); }
}

class _RidgeItem {
  final TextEditingController qtyController;
  final TextEditingController sizeController;
  _RidgeItem() : qtyController = TextEditingController(), sizeController = TextEditingController();
  void dispose() { qtyController.dispose(); sizeController.dispose(); }
}

class _ValleyItem {
  final TextEditingController lengthController;
  final TextEditingController typeController;
  final TextEditingController sizeController;
  _ValleyItem() : lengthController = TextEditingController(), typeController = TextEditingController(), sizeController = TextEditingController();
  void dispose() { lengthController.dispose(); typeController.dispose(); sizeController.dispose(); }
}

class _DomFlashingItem {
  final TextEditingController typeController;
  final TextEditingController qtyController;
  final TextEditingController colourController;
  final TextEditingController materialController;
  final TextEditingController sizeController;
  _DomFlashingItem() : typeController = TextEditingController(), qtyController = TextEditingController(), colourController = TextEditingController(), materialController = TextEditingController(), sizeController = TextEditingController();
  void dispose() { typeController.dispose(); qtyController.dispose(); colourController.dispose(); materialController.dispose(); sizeController.dispose(); }
}

class DomesticMaterialList extends StatefulWidget {
  const DomesticMaterialList({super.key});
  @override
  State<DomesticMaterialList> createState() => _DomesticMaterialListState();
}

class _DomesticMaterialListState extends State<DomesticMaterialList> {
  final _buildingController = TextEditingController();
  final _notesController = TextEditingController();

  // Tiles/Slates
  final List<_TileItem> _tileItems = [_TileItem()];

  // Underlay
  final _epdmController = TextEditingController();
  final _feltController = TextEditingController();
  final _adhesiveController = TextEditingController();
  final _primerController = TextEditingController();

  // Battens
  final _battensController = TextEditingController();
  final _battenSpacingController = TextEditingController();

  // Fixings
  final _nailsController = TextEditingController();
  final _screwsController = TextEditingController();

  // Flashings
  final List<_DomFlashingItem> _flashingItems = [_DomFlashingItem()];

  // Ridge / Hip / Valley
  final List<_RidgeItem> _ridgeItems = [_RidgeItem()];
  final List<_RidgeItem> _hipItems = [_RidgeItem()];
  final List<_ValleyItem> _valleyItems = [_ValleyItem()];

  // Extras
  final _ventsController = TextEditingController();
  final _ventsTypeController = TextEditingController();
  final _rooflightsController = TextEditingController();
  final _rooflightsSizeController = TextEditingController();
  final _gutteringController = TextEditingController();
  final _downpipesController = TextEditingController();

  // Safety
  final _scaffoldingController = TextEditingController();
  final _nettingController = TextEditingController();
  final _plantController = TextEditingController();

  String _date = '';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _date = '${now.day.toString().padLeft(2,'0')}/${now.month.toString().padLeft(2,'0')}/${now.year}';
  }

  @override
  void dispose() {
    for (final i in _tileItems) { i.dispose(); }
    for (final i in _flashingItems) { i.dispose(); }
    for (final i in _ridgeItems) { i.dispose(); }
    for (final i in _hipItems) { i.dispose(); }
    for (final i in _valleyItems) { i.dispose(); }
    for (final c in [_buildingController, _notesController, _epdmController, _feltController,
      _adhesiveController, _primerController, _battensController, _battenSpacingController,
      _nailsController, _screwsController, _ventsController, _ventsTypeController,
      _rooflightsController, _rooflightsSizeController, _gutteringController,
      _downpipesController, _scaffoldingController, _nettingController, _plantController]) { c.dispose(); }
    super.dispose();
  }

  static InputDecoration _hintDec(String hint, {String? suffix}) => InputDecoration(
    hintText: hint, hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12),
    suffixText: suffix, border: const OutlineInputBorder(), isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
  );

  Widget _sectionHeader(String title, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 10),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }

  Widget _field(String label, TextEditingController controller, {String? suffix, String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Expanded(flex: 3, child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(flex: 2, child: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            hintText: hint ?? '0', hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12),
            suffixText: suffix, border: const OutlineInputBorder(), isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          ),
        )),
      ]),
    );
  }

  void _clearAll() {
    showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Clear All'),
      content: const Text('Clear all fields?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear', style: TextStyle(color: Colors.red))),
      ],
    )).then((confirm) {
      if (confirm == true) {
        for (final i in _tileItems) { i.dispose(); } _tileItems.clear(); _tileItems.add(_TileItem());
        for (final i in _flashingItems) { i.dispose(); } _flashingItems.clear(); _flashingItems.add(_DomFlashingItem());
        for (final i in _ridgeItems) { i.dispose(); } _ridgeItems.clear(); _ridgeItems.add(_RidgeItem());
        for (final i in _hipItems) { i.dispose(); } _hipItems.clear(); _hipItems.add(_RidgeItem());
        for (final i in _valleyItems) { i.dispose(); } _valleyItems.clear(); _valleyItems.add(_ValleyItem());
        for (final c in [_buildingController, _notesController, _epdmController, _feltController,
          _adhesiveController, _primerController, _battensController, _battenSpacingController,
          _nailsController, _screwsController, _ventsController, _ventsTypeController,
          _rooflightsController, _rooflightsSizeController, _gutteringController,
          _downpipesController, _scaffoldingController, _nettingController, _plantController]) { c.clear(); }
        setState(() {});
      }
    });
  }

  void saveList() => _saveList();
  void exportPdf() => _exportPdf();
  void shareList() => _shareList();
  void clearAll() => _clearAll();

  Map<String, dynamic> _collectData() {
    return {
      'savedAt': DateTime.now().toIso8601String(),
      'type': 'domestic',
      'buildingName': _buildingController.text,
      'notes': _notesController.text,
      'epdm': _epdmController.text,
      'felt': _feltController.text,
      'adhesive': _adhesiveController.text,
      'primer': _primerController.text,
      'battens': _battensController.text,
      'battenSpacing': _battenSpacingController.text,
      'nails': _nailsController.text,
      'screws': _screwsController.text,
      'vents': _ventsController.text,
      'ventsType': _ventsTypeController.text,
      'rooflights': _rooflightsController.text,
      'rooflightsSize': _rooflightsSizeController.text,
      'guttering': _gutteringController.text,
      'downpipes': _downpipesController.text,
      'scaffolding': _scaffoldingController.text,
      'netting': _nettingController.text,
      'plant': _plantController.text,
      'tiles': _tileItems.map((i) => {'qty': i.qtyController.text, 'size': i.sizeController.text, 'material': i.materialController.text}).toList(),
      'flashings': _flashingItems.map((i) => {'type': i.typeController.text, 'qty': i.qtyController.text, 'colour': i.colourController.text, 'material': i.materialController.text, 'size': i.sizeController.text}).toList(),
      'ridges': _ridgeItems.map((i) => {'qty': i.qtyController.text, 'size': i.sizeController.text}).toList(),
      'hips': _hipItems.map((i) => {'qty': i.qtyController.text, 'size': i.sizeController.text}).toList(),
      'valleys': _valleyItems.map((i) => {'length': i.lengthController.text, 'type': i.typeController.text, 'size': i.sizeController.text}).toList(),
    };
  }

  Future<void> _saveList() async {
    final autoName = _buildingController.text.trim().isNotEmpty
      ? _buildingController.text.trim()
      : 'Domestic ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}';
    final nameController = TextEditingController(text: autoName);
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Save Domestic List'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Enter a name for this list:'),
        const SizedBox(height: 12),
        TextField(controller: nameController, textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(border: OutlineInputBorder(), prefixIcon: Icon(Icons.home)),
          autofocus: true),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white),
          child: const Text('Save')),
      ],
    ));
    if (confirm != true) return;
    final data = _collectData();
    data['name'] = nameController.text.trim().isNotEmpty ? nameController.text.trim() : autoName;
    await MaterialListService.save(data);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Saved: ${data['name']}'),
      backgroundColor: Colors.green.shade700,
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _exportPdf() async {
    try {
      final sb = StringBuffer();
      for (final i in _tileItems) {
        if (i.qtyController.text.isNotEmpty) sb.writeln('${i.materialController.text.isNotEmpty ? i.materialController.text : 'Tile'}: Qty ${i.qtyController.text}');
      }
      if (_epdmController.text.isNotEmpty) sb.writeln('EPDM: ${_epdmController.text} m2');
      if (_feltController.text.isNotEmpty) sb.writeln('Felt: ${_feltController.text} rolls');
      if (_battensController.text.isNotEmpty) sb.writeln('Battens: ${_battensController.text} m');
      for (final f in _flashingItems) { if (f.typeController.text.isNotEmpty) sb.writeln('Flashing: ${f.typeController.text} Qty: ${f.qtyController.text}'); }
      for (final r in _ridgeItems) { if (r.qtyController.text.isNotEmpty) sb.writeln('Ridge: Qty ${r.qtyController.text}'); }
      for (final h in _hipItems) { if (h.qtyController.text.isNotEmpty) sb.writeln('Hip: Qty ${h.qtyController.text}'); }
      for (final v in _valleyItems) { if (v.lengthController.text.isNotEmpty) sb.writeln('Valley: ${v.lengthController.text}m'); }
      if (_gutteringController.text.isNotEmpty) sb.writeln('Guttering: ${_gutteringController.text} m');
      if (_notesController.text.isNotEmpty) sb.writeln('\nNOTES\n${_notesController.text}');
      final pdfBytes = await PdfService.generateMaterialPdf(
        buildingName: _buildingController.text,
        date: _date,
        type: 'Domestic',
        content: sb.toString(),
      );
      await Share.shareXFiles(
        [XFile.fromData(pdfBytes, name: 'domestic_${DateTime.now().millisecondsSinceEpoch}.pdf', mimeType: 'application/pdf')],
        subject: 'Domestic Material List',
        sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF failed: $e'), backgroundColor: Colors.red));
    }
  }

  void _shareList() {
    final sb = StringBuffer();
    sb.writeln('╔══════════════════════════╗');
    sb.writeln('║  🏠 DOMESTIC ROOF LIST   ║');
    sb.writeln('╚══════════════════════════╝');
    if (_buildingController.text.isNotEmpty) sb.writeln('📍 Job:  ${_buildingController.text}');
    sb.writeln('📅 Date: $_date\n');

    bool hasTiles = _tileItems.any((i) => i.qtyController.text.isNotEmpty);
    if (hasTiles) {
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      sb.writeln('🏠 TILES / SLATES');
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      for (final i in _tileItems) {
        if (i.qtyController.text.isNotEmpty) {
          sb.writeln('  • ${i.materialController.text.isNotEmpty ? i.materialController.text : 'Tile'}');
          sb.writeln('    Qty: ${i.qtyController.text}${i.sizeController.text.isNotEmpty ? '  |  Size: ${i.sizeController.text}' : ''}');
        }
      }
      sb.writeln('');
    }

    sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
    sb.writeln('🛡️ UNDERLAY / WATERPROOFING');
    sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
    if (_epdmController.text.isNotEmpty) sb.writeln('  • EPDM: ${_epdmController.text} m²');
    if (_feltController.text.isNotEmpty) sb.writeln('  • Felt: ${_feltController.text} rolls');
    if (_adhesiveController.text.isNotEmpty) sb.writeln('  • Adhesive: ${_adhesiveController.text} litres');
    if (_primerController.text.isNotEmpty) sb.writeln('  • Primer: ${_primerController.text} litres');
    sb.writeln('');

    if (_battensController.text.isNotEmpty || _battenSpacingController.text.isNotEmpty) {
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      sb.writeln('🪵 BATTENS');
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      if (_battensController.text.isNotEmpty) sb.writeln('  • Battens: ${_battensController.text} m');
      if (_battenSpacingController.text.isNotEmpty) sb.writeln('  • Spacing: ${_battenSpacingController.text} mm');
      sb.writeln('');
    }

    bool hasFlashings = _flashingItems.any((i) => i.typeController.text.isNotEmpty);
    if (hasFlashings) {
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      sb.writeln('⚡ FLASHINGS');
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      for (final i in _flashingItems) {
        if (i.typeController.text.isNotEmpty || i.qtyController.text.isNotEmpty) {
          sb.writeln('  • ${i.typeController.text.isNotEmpty ? i.typeController.text : 'Flashing'}');
          sb.writeln('    Qty: ${i.qtyController.text}${i.sizeController.text.isNotEmpty ? '  |  Size: ${i.sizeController.text}' : ''}${i.colourController.text.isNotEmpty ? '  |  ${i.colourController.text}' : ''}${i.materialController.text.isNotEmpty ? '  |  ${i.materialController.text}' : ''}');
        }
      }
      sb.writeln('');
    }

    bool hasRidge = _ridgeItems.any((i) => i.qtyController.text.isNotEmpty);
    bool hasHip = _hipItems.any((i) => i.qtyController.text.isNotEmpty);
    bool hasValley = _valleyItems.any((i) => i.lengthController.text.isNotEmpty);
    if (hasRidge || hasHip || hasValley) {
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      sb.writeln('🔺 RIDGE / HIP / VALLEY');
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      for (final i in _ridgeItems) { if (i.qtyController.text.isNotEmpty) sb.writeln('  • Ridge: Qty ${i.qtyController.text}${i.sizeController.text.isNotEmpty ? '  |  ${i.sizeController.text}' : ''}'); }
      for (final i in _hipItems) { if (i.qtyController.text.isNotEmpty) sb.writeln('  • Hip: Qty ${i.qtyController.text}${i.sizeController.text.isNotEmpty ? '  |  ${i.sizeController.text}' : ''}'); }
      for (final i in _valleyItems) { if (i.lengthController.text.isNotEmpty) sb.writeln('  • Valley: ${i.lengthController.text}m${i.typeController.text.isNotEmpty ? '  |  ${i.typeController.text}' : ''}${i.sizeController.text.isNotEmpty ? '  |  ${i.sizeController.text}' : ''}'); }
      sb.writeln('');
    }

    if (_notesController.text.isNotEmpty) {
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      sb.writeln('📝 NOTES');
      sb.writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━');
      sb.writeln(_notesController.text);
    }
    sb.writeln('\n──────────────────────────');
    sb.writeln('Generated by Roof Profile Finder');
    Share.share(sb.toString(), subject: 'Domestic Material List - ${_buildingController.text.isNotEmpty ? _buildingController.text : _date}', sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1));
  }

  Widget _dynamicRows<T>({
    required List<T> items,
    required List<String> headers,
    required Widget Function(T item, int index) rowBuilder,
    required VoidCallback onAdd,
    required String addLabel,
    required Color color,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          ...headers.map((h) => Expanded(child: Text(h, style: const TextStyle(fontSize: 12, color: Colors.grey)))),
          const SizedBox(width: 32),
        ]),
      ),
      ...items.asMap().entries.map((e) => rowBuilder(e.value, e.key)),
      TextButton.icon(
        onPressed: onAdd,
        icon: const Icon(Icons.add_circle_outline, size: 18),
        label: Text(addLabel),
        style: TextButton.styleFrom(foregroundColor: color),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header
          Card(color: Colors.green.shade50, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: _buildingController, textCapitalization: TextCapitalization.words,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                decoration: InputDecoration(hintText: 'Building / Job Name', border: InputBorder.none,
                  prefixIcon: const Icon(Icons.home_work_outlined),
                  hintStyle: TextStyle(color: Colors.grey.shade400))),
              const Divider(height: 1),
              Padding(padding: const EdgeInsets.only(top: 8, left: 12),
                child: Text('Date: $_date', style: TextStyle(fontSize: 13, color: Colors.grey.shade600))),
            ])),
          ),

          // Tiles / Slates
          _sectionHeader('Tiles / Slates', Icons.roofing, Colors.blue.shade700),
          Padding(padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: const [
              Expanded(flex: 2, child: Text('Qty', style: TextStyle(fontSize: 12, color: Colors.grey))),
              SizedBox(width: 6),
              Expanded(flex: 2, child: Text('Size', style: TextStyle(fontSize: 12, color: Colors.grey))),
              SizedBox(width: 6),
              Expanded(flex: 3, child: Text('Material', style: TextStyle(fontSize: 12, color: Colors.grey))),
              SizedBox(width: 32),
            ]),
          ),
          ..._tileItems.asMap().entries.map((entry) {
            final i = entry.key; final item = entry.value;
            return Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
              Expanded(flex: 2, child: TextField(controller: item.qtyController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _hintDec('0'))),
              const SizedBox(width: 6),
              Expanded(flex: 2, child: TextField(controller: item.sizeController, decoration: _hintDec('265x165'))),
              const SizedBox(width: 6),
              Expanded(flex: 3, child: TextField(controller: item.materialController, textCapitalization: TextCapitalization.words, decoration: _hintDec('Concrete'))),
              const SizedBox(width: 4),
              IconButton(onPressed: _tileItems.length > 1 ? () => setState(() { _tileItems[i].dispose(); _tileItems.removeAt(i); }) : null,
                icon: Icon(Icons.remove_circle_outline, color: _tileItems.length > 1 ? Colors.red : Colors.grey, size: 22),
                padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]));
          }),
          TextButton.icon(onPressed: () => setState(() { _tileItems.add(_TileItem()); }),
            icon: const Icon(Icons.add_circle_outline, size: 18), label: const Text('Add tile/slate'),
            style: TextButton.styleFrom(foregroundColor: Colors.blue.shade700)),

          // Underlay
          _sectionHeader('Underlay / Waterproofing', Icons.water_drop, Colors.cyan.shade700),
          _field('EPDM', _epdmController, suffix: 'm²'),
          _field('Felt / Underlay', _feltController, suffix: 'rolls'),
          _field('Adhesive', _adhesiveController, suffix: 'litres'),
          _field('Primer', _primerController, suffix: 'litres'),

          // Battens
          _sectionHeader('Battens', Icons.view_column, Colors.brown.shade600),
          _field('Battens', _battensController, suffix: 'm'),
          Row(children: [
            const Expanded(flex: 3, child: Text('Batten Spacing', style: TextStyle(fontSize: 13))),
            Expanded(flex: 2, child: TextField(controller: _battenSpacingController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(hintText: '100', hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                suffixText: 'mm', border: const OutlineInputBorder(), isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10)))),
          ]),
          const SizedBox(height: 10),

          // Fixings
          _sectionHeader('Fixings', Icons.settings, Colors.orange.shade700),
          _field('Nails', _nailsController, suffix: 'qty'),
          _field('Screws', _screwsController, suffix: 'qty'),

          // Flashings
          _sectionHeader('Flashings', Icons.water, Colors.purple.shade700),
          Padding(padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: const [
              Expanded(flex: 3, child: Text('Type', style: TextStyle(fontSize: 12, color: Colors.grey))),
              SizedBox(width: 4),
              Expanded(flex: 2, child: Text('Qty', style: TextStyle(fontSize: 12, color: Colors.grey))),
              SizedBox(width: 4),
              Expanded(flex: 2, child: Text('Size', style: TextStyle(fontSize: 12, color: Colors.grey))),
              SizedBox(width: 4),
              Expanded(flex: 2, child: Text('Colour', style: TextStyle(fontSize: 12, color: Colors.grey))),
              SizedBox(width: 32),
            ]),
          ),
          ..._flashingItems.asMap().entries.map((entry) {
            final i = entry.key; final item = entry.value;
            return Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
              Expanded(flex: 3, child: TextField(controller: item.typeController, textCapitalization: TextCapitalization.words, decoration: _hintDec('Lead'))),
              const SizedBox(width: 4),
              Expanded(flex: 2, child: TextField(controller: item.qtyController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _hintDec('0'))),
              const SizedBox(width: 4),
              Expanded(flex: 2, child: TextField(controller: item.sizeController, decoration: _hintDec('150mm'))),
              const SizedBox(width: 4),
              Expanded(flex: 2, child: TextField(controller: item.colourController, textCapitalization: TextCapitalization.words, decoration: _hintDec('Grey'))),
              const SizedBox(width: 4),
              IconButton(onPressed: _flashingItems.length > 1 ? () => setState(() { _flashingItems[i].dispose(); _flashingItems.removeAt(i); }) : null,
                icon: Icon(Icons.remove_circle_outline, color: _flashingItems.length > 1 ? Colors.red : Colors.grey, size: 20),
                padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]));
          }),
          TextButton.icon(onPressed: () => setState(() { _flashingItems.add(_DomFlashingItem()); }),
            icon: const Icon(Icons.add_circle_outline, size: 18), label: const Text('Add flashing'),
            style: TextButton.styleFrom(foregroundColor: Colors.purple.shade700)),

          // Ridge / Hip / Valley
          _sectionHeader('Ridge / Hip / Valley', Icons.change_history, Colors.red.shade700),
          const Text('Ridge Tiles', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey)),
          const SizedBox(height: 6),
          ..._ridgeItems.asMap().entries.map((entry) {
            final i = entry.key; final item = entry.value;
            return Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
              const Expanded(flex: 2, child: Text('Qty', style: TextStyle(fontSize: 12, color: Colors.grey))),
              const SizedBox(width: 8),
              const Expanded(flex: 2, child: Text('Size', style: TextStyle(fontSize: 12, color: Colors.grey))),
              const SizedBox(width: 32),
            ]));
          }),
          ..._ridgeItems.asMap().entries.map((entry) {
            final i = entry.key; final item = entry.value;
            return Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
              Expanded(flex: 2, child: TextField(controller: item.qtyController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _hintDec('0'))),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: TextField(controller: item.sizeController, decoration: _hintDec('200mm'))),
              const SizedBox(width: 4),
              IconButton(onPressed: _ridgeItems.length > 1 ? () => setState(() { _ridgeItems[i].dispose(); _ridgeItems.removeAt(i); }) : null,
                icon: Icon(Icons.remove_circle_outline, color: _ridgeItems.length > 1 ? Colors.red : Colors.grey, size: 20),
                padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]));
          }),
          TextButton.icon(onPressed: () => setState(() { _ridgeItems.add(_RidgeItem()); }),
            icon: const Icon(Icons.add_circle_outline, size: 18), label: const Text('Add ridge'),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade700)),

          const SizedBox(height: 8),
          const Text('Hip Tiles', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey)),
          const SizedBox(height: 6),
          ..._hipItems.asMap().entries.map((entry) {
            final i = entry.key; final item = entry.value;
            return Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
              Expanded(flex: 2, child: TextField(controller: item.qtyController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _hintDec('0'))),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: TextField(controller: item.sizeController, decoration: _hintDec('200mm'))),
              const SizedBox(width: 4),
              IconButton(onPressed: _hipItems.length > 1 ? () => setState(() { _hipItems[i].dispose(); _hipItems.removeAt(i); }) : null,
                icon: Icon(Icons.remove_circle_outline, color: _hipItems.length > 1 ? Colors.red : Colors.grey, size: 20),
                padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]));
          }),
          TextButton.icon(onPressed: () => setState(() { _hipItems.add(_RidgeItem()); }),
            icon: const Icon(Icons.add_circle_outline, size: 18), label: const Text('Add hip'),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade700)),

          const SizedBox(height: 8),
          const Text('Valley', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey)),
          const SizedBox(height: 6),
          ..._valleyItems.asMap().entries.map((entry) {
            final i = entry.key; final item = entry.value;
            return Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
              Expanded(flex: 2, child: TextField(controller: item.lengthController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _hintDec('0', suffix: 'm'))),
              const SizedBox(width: 6),
              Expanded(flex: 2, child: TextField(controller: item.typeController, textCapitalization: TextCapitalization.words, decoration: _hintDec('GRP'))),
              const SizedBox(width: 6),
              Expanded(flex: 2, child: TextField(controller: item.sizeController, decoration: _hintDec('150mm'))),
              const SizedBox(width: 4),
              IconButton(onPressed: _valleyItems.length > 1 ? () => setState(() { _valleyItems[i].dispose(); _valleyItems.removeAt(i); }) : null,
                icon: Icon(Icons.remove_circle_outline, color: _valleyItems.length > 1 ? Colors.red : Colors.grey, size: 20),
                padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]));
          }),
          TextButton.icon(onPressed: () => setState(() { _valleyItems.add(_ValleyItem()); }),
            icon: const Icon(Icons.add_circle_outline, size: 18), label: const Text('Add valley'),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade700)),

          // Extras
          _sectionHeader('Extras', Icons.construction, Colors.teal.shade700),
          Row(children: [
            const Expanded(flex: 3, child: Text('Vents', style: TextStyle(fontSize: 13))),
            Expanded(flex: 2, child: TextField(controller: _ventsController, keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(hintText: '0', hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                suffixText: 'qty', border: const OutlineInputBorder(), isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10)))),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: TextField(controller: _ventsTypeController, textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(hintText: 'Type', hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                border: const OutlineInputBorder(), isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10)))),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            const Expanded(flex: 3, child: Text('Rooflights', style: TextStyle(fontSize: 13))),
            Expanded(flex: 2, child: TextField(controller: _rooflightsController, keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(hintText: '0', hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                suffixText: 'qty', border: const OutlineInputBorder(), isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10)))),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: TextField(controller: _rooflightsSizeController,
              decoration: InputDecoration(hintText: '1000x1000', hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                border: const OutlineInputBorder(), isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10)))),
          ]),
          const SizedBox(height: 10),
          _field('Guttering', _gutteringController, suffix: 'm'),
          _field('Downpipes', _downpipesController, suffix: 'qty'),

          // Safety
          _sectionHeader('Safety', Icons.health_and_safety, Colors.red.shade700),
          _field('Scaffolding', _scaffoldingController, hint: 'weeks/days'),
          _field('Netting', _nettingController, suffix: 'm²'),
          _field('Plant / Equipment', _plantController, hint: 'description'),

          // Notes
          _sectionHeader('Notes', Icons.notes, Colors.grey.shade700),
          TextField(controller: _notesController, maxLines: 4, textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(hintText: 'Any additional notes...', hintStyle: TextStyle(color: Colors.grey.shade400), border: const OutlineInputBorder())),

          const SizedBox(height: 24),
          SizedBox(width: double.infinity,
            child: ElevatedButton.icon(onPressed: _shareList, icon: const Icon(Icons.share),
              label: const Text('Share Domestic List'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)))),
          const SizedBox(height: 30),
        ]),
      ),
    );
  }
}


// ═══════════════════════════════════════════════════════════════
// Site Stops Screen — nearby coffee, food and trade counter launcher
// ═══════════════════════════════════════════════════════════════

class SiteStopOption {
  final String label;
  final String query;
  final IconData icon;
  final Color color;
  final String subtitle;
  const SiteStopOption(this.label, this.query, this.icon, this.color, this.subtitle);
}

class SiteStopsScreen extends StatefulWidget {
  const SiteStopsScreen({super.key});

  @override
  State<SiteStopsScreen> createState() => _SiteStopsScreenState();
}

class _SiteStopsScreenState extends State<SiteStopsScreen> {
  double _radiusMiles = 3;
  bool _opening = false;

  static final List<SiteStopOption> _options = [
    SiteStopOption('Cafes', 'cafe', Icons.local_cafe, Colors.brown.shade600, 'Independent cafes nearby'),
    SiteStopOption('Coffee shops', 'coffee shop', Icons.coffee, Colors.brown.shade700, 'Coffee chains and independents'),
    SiteStopOption('Greggs', 'Greggs', Icons.bakery_dining, Colors.indigo.shade700, 'Breakfast, lunch and snacks'),
    SiteStopOption('McDonald\'s', 'McDonald\'s', Icons.fastfood, Colors.red.shade700, 'Fast food nearby'),
    SiteStopOption('KFC', 'KFC', Icons.restaurant, Colors.deepOrange.shade700, 'Chicken restaurants'),
    SiteStopOption('Costa', 'Costa Coffee', Icons.coffee_maker, Colors.red.shade900, 'Costa Coffee stores'),
    SiteStopOption('Burger King', 'Burger King', Icons.lunch_dining, Colors.orange.shade800, 'Burger King restaurants'),
    SiteStopOption('Screwfix', 'Screwfix', Icons.handyman, Colors.blue.shade800, 'Trade counter and supplies'),
    SiteStopOption('Toolstation', 'Toolstation', Icons.construction, Colors.green.shade700, 'Trade counter and supplies'),
  ];

  Future<Position?> _getPosition() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission is needed to search near your current site.')),
          );
        }
        return null;
      }
      return await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not get your current location.')),
        );
      }
      return null;
    }
  }

  Future<void> _openInMaps(SiteStopOption option, {required bool directions}) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final pos = await _getPosition();
      if (pos == null) return;
      final query = '${option.query} within ${_radiusMiles.round()} miles';
      late final Uri uri;
      if (directions) {
        if (Platform.isIOS) {
          uri = Uri.parse('https://maps.apple.com/?saddr=${pos.latitude},${pos.longitude}&daddr=${Uri.encodeComponent(query)}&dirflg=d');
        } else {
          uri = Uri.parse('https://www.google.com/maps/dir/?api=1&origin=${pos.latitude},${pos.longitude}&destination=${Uri.encodeComponent(query)}&travelmode=driving');
        }
      } else {
        if (Platform.isIOS) {
          uri = Uri.parse('https://maps.apple.com/?ll=${pos.latitude},${pos.longitude}&q=${Uri.encodeComponent(query)}');
        } else {
          uri = Uri.parse('geo:${pos.latitude},${pos.longitude}?q=${Uri.encodeComponent(query)}');
        }
      }
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open maps for ${option.label}.')),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _showOptionSheet(SiteStopOption option) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: option.color.withOpacity(0.12),
                      child: Icon(option.icon, color: option.color),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(option.label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                          Text('Search within ${_radiusMiles.round()} miles', style: TextStyle(color: Colors.grey.shade700)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                ElevatedButton.icon(
                  icon: const Icon(Icons.map),
                  label: const Text('Show on map'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.brown.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    _openInMaps(option, directions: false);
                  },
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  icon: const Icon(Icons.directions),
                  label: const Text('Open directions'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    _openInMaps(option, directions: true);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Site Stops'),
        backgroundColor: Colors.brown.shade700,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Colors.brown.shade700, Colors.brown.shade500]),
              borderRadius: BorderRadius.circular(22),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 16, offset: const Offset(0, 8))],
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.storefront, color: Colors.white, size: 34),
                SizedBox(height: 12),
                Text('Find a quick stop near site', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
                SizedBox(height: 6),
                Text('Coffee, food and trade counters. Opens in the maps app installed on this device.', style: TextStyle(color: Colors.white70, height: 1.35)),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(child: Text('Search distance', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(color: Colors.brown.shade50, borderRadius: BorderRadius.circular(999)),
                        child: Text('${_radiusMiles.round()} miles', style: TextStyle(color: Colors.brown.shade800, fontWeight: FontWeight.w800)),
                      ),
                    ],
                  ),
                  Slider(
                    value: _radiusMiles,
                    min: 1,
                    max: 8,
                    divisions: 7,
                    label: '${_radiusMiles.round()} miles',
                    activeColor: Colors.brown.shade700,
                    onChanged: (v) => setState(() => _radiusMiles = v),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _options.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.22,
            ),
            itemBuilder: (context, index) {
              final option = _options[index];
              return InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: _opening ? null : () => _showOptionSheet(option),
                child: Ink(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.grey.shade200),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(color: option.color.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
                        child: Icon(option.icon, color: option.color),
                      ),
                      const Spacer(),
                      Text(option.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
                      const SizedBox(height: 3),
                      Text(option.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: Colors.grey.shade700, height: 1.15)),
                    ],
                  ),
                ),
              );
            },
          ),
          if (_opening) ...[
            const SizedBox(height: 18),
            const Center(child: CircularProgressIndicator()),
          ],
          const SizedBox(height: 20),
          Text(
            'Tip: choose Show on map first if you want to compare nearby options. Choose Open directions when you already know which stop you want.',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 12, height: 1.35),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Torch Screen
// ═══════════════════════════════════════════════════════════════

class TorchScreen extends StatefulWidget {
  const TorchScreen({super.key});
  @override
  State<TorchScreen> createState() => _TorchScreenState();
}

class _TorchScreenState extends State<TorchScreen> {
  bool _torchOn = false;
  bool _supported = true;

  static const _channel = MethodChannel('torch_channel');

  Future<void> _toggleTorch() async {
    try {
      await _channel.invokeMethod('setTorch', {'on': !_torchOn});
      setState(() { _torchOn = !_torchOn; });
    } catch (e) {
      setState(() { _supported = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Torch not available on this device'),
          duration: Duration(seconds: 2),
        ));
      }
    }
  }

  @override
  void dispose() {
    // Make sure torch is off when leaving
    if (_torchOn) {
      try { _channel.invokeMethod('setTorch', {'on': false}); } catch (_) {}
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _torchOn ? Colors.white : Colors.grey.shade900,
      appBar: AppBar(
        title: const Text('Torch'),
        backgroundColor: Colors.amber.shade700,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          // Big torch button
          GestureDetector(
            onTap: _toggleTorch,
            child: Container(
              width: 180, height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _torchOn ? Colors.amber.shade400 : Colors.grey.shade700,
                boxShadow: _torchOn ? [
                  BoxShadow(color: Colors.amber.withOpacity(0.6), blurRadius: 40, spreadRadius: 20),
                ] : [],
              ),
              child: Icon(
                _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                size: 80,
                color: _torchOn ? Colors.white : Colors.grey.shade400,
              ),
            ),
          ),
          const SizedBox(height: 32),
          Text(
            _torchOn ? 'Torch ON' : 'Torch OFF',
            style: TextStyle(
              fontSize: 24, fontWeight: FontWeight.bold,
              color: _torchOn ? Colors.amber.shade700 : Colors.grey.shade400,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Tap to ${_torchOn ? 'turn off' : 'turn on'}',
            style: TextStyle(fontSize: 14, color: _torchOn ? Colors.grey.shade700 : Colors.grey.shade500),
          ),
          if (!_supported) ...[
            const SizedBox(height: 24),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 32),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.orange.shade300)),
              child: const Text('Torch not supported on this device', textAlign: TextAlign.center, style: TextStyle(color: Colors.orange)),
            ),
          ],
          const SizedBox(height: 48),
          Text('Tap the button to toggle torch', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Roof Map Screen
// ═══════════════════════════════════════════════════════════════

class RoofMapScreen extends StatefulWidget {
  final List<HistoryEntry> history;
  const RoofMapScreen({super.key, required this.history});
  @override
  State<RoofMapScreen> createState() => _RoofMapScreenState();
}

class _RoofMapScreenState extends State<RoofMapScreen> {
  GoogleMapController? _mapController;
  final Set<Marker> _markers = {};
  HistoryEntry? _selectedEntry;

  @override
  void initState() {
    super.initState();
    _buildMarkers();
  }

  void _buildMarkers() {
    for (int i = 0; i < widget.history.length; i++) {
      final entry = widget.history[i];
      if (!entry.hasGps) continue;
      _markers.add(Marker(
        markerId: MarkerId('marker_$i'),
        position: LatLng(entry.gpsLat!, entry.gpsLng!),
        infoWindow: InfoWindow(
          title: entry.buildingName ?? entry.profile.displayTitle,
          snippet: '${entry.profile.displayTitle}${entry.roofPitch != null ? ' • ${entry.roofPitch!.toStringAsFixed(1)}°' : ''}',
        ),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        onTap: () => setState(() { _selectedEntry = entry; }),
      ));
    }
  }

  LatLng get _initialPosition {
    final withGps = widget.history.where((e) => e.hasGps).toList();
    if (withGps.isEmpty) return const LatLng(52.5, -1.9); // UK centre
    return LatLng(withGps.first.gpsLat!, withGps.first.gpsLng!);
  }

  int get _pinCount => widget.history.where((e) => e.hasGps).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Roof Locations'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
      ),
      body: _pinCount == 0
          ? const Center(child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.location_off, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text('No GPS locations saved yet.\n\nTap the GPS button when saving a profile to add a map pin.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
              ]),
            ))
          : Stack(children: [
              GoogleMap(
                initialCameraPosition: CameraPosition(target: _initialPosition, zoom: 13),
                markers: _markers,
                myLocationEnabled: true,
                myLocationButtonEnabled: true,
                mapType: MapType.normal,
                onMapCreated: (controller) {
                  _mapController = controller;
                  // Fit all markers
                  if (_pinCount > 1) {
                    final points = widget.history.where((e) => e.hasGps)
                        .map((e) => LatLng(e.gpsLat!, e.gpsLng!)).toList();
                    double minLat = points.map((p) => p.latitude).reduce(math.min);
                    double maxLat = points.map((p) => p.latitude).reduce(math.max);
                    double minLng = points.map((p) => p.longitude).reduce(math.min);
                    double maxLng = points.map((p) => p.longitude).reduce(math.max);
                    controller.animateCamera(CameraUpdate.newLatLngBounds(
                      LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)), 80));
                  }
                },
                onTap: (_) => setState(() { _selectedEntry = null; }),
              ),

              // Pin count badge
              Positioned(top: 12, left: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: Colors.blue.shade700, borderRadius: BorderRadius.circular(20)),
                  child: Text('$_pinCount roof${_pinCount == 1 ? '' : 's'} saved',
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),

              // Selected entry card
              if (_selectedEntry != null)
                Positioned(
                  bottom: 16, left: 16, right: 16,
                  child: Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 6,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          const Icon(Icons.roofing, color: Colors.blue, size: 20),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_selectedEntry!.profile.displayTitle,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
                          IconButton(onPressed: () => setState(() { _selectedEntry = null; }),
                            icon: const Icon(Icons.close, size: 18), padding: EdgeInsets.zero,
                            constraints: const BoxConstraints()),
                        ]),
                        if ((_selectedEntry!.buildingName ?? '').isNotEmpty)
                          Text(_selectedEntry!.buildingName!, style: TextStyle(color: Colors.blue.shade700, fontWeight: FontWeight.w500)),
                        if ((_selectedEntry!.location ?? '').isNotEmpty)
                          Text(_selectedEntry!.location!, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                        const SizedBox(height: 6),
                        Row(children: [
                          const Icon(Icons.access_time, size: 12, color: Colors.grey),
                          const SizedBox(width: 4),
                          Text(_selectedEntry!.formattedDate, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          if (_selectedEntry!.roofPitch != null) ...[
                            const SizedBox(width: 12),
                            const Icon(Icons.architecture, size: 12, color: Colors.deepOrange),
                            const SizedBox(width: 4),
                            Text('${_selectedEntry!.roofPitch!.toStringAsFixed(1)}°',
                              style: const TextStyle(fontSize: 11, color: Colors.deepOrange)),
                          ],
                        ]),
                        const SizedBox(height: 8),
                        SizedBox(width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                              builder: (_) => ResultsScreen(title: 'Profile', results: [SearchResult(profile: _selectedEntry!.profile, score: 0)]))),
                            icon: const Icon(Icons.search, size: 16),
                            label: const Text('View Profile'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 10)),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
            ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Roof Area Calculator Screen
// ═══════════════════════════════════════════════════════════════

class RoofAreaCalculator extends StatefulWidget {
  const RoofAreaCalculator({super.key});
  @override
  State<RoofAreaCalculator> createState() => _RoofAreaCalculatorState();
}

class _RoofAreaCalculatorState extends State<RoofAreaCalculator> {
  final _lengthController = TextEditingController();
  final _widthController = TextEditingController();
  final _pitchController = TextEditingController();
  final _wastageController = TextEditingController(text: '10');
  double? _flatArea;
  double? _pitchedArea;
  double? _totalWithWastage;

  @override
  void dispose() {
    _lengthController.dispose();
    _widthController.dispose();
    _pitchController.dispose();
    _wastageController.dispose();
    super.dispose();
  }

  void _calculate() {
    final length = double.tryParse(_lengthController.text);
    final width = double.tryParse(_widthController.text);
    final pitch = double.tryParse(_pitchController.text);
    final wastage = double.tryParse(_wastageController.text) ?? 10;
    if (length == null || width == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter length and width to calculate')));
      return;
    }
    final flat = length * width;
    double pitched = flat;
    if (pitch != null && pitch > 0) {
      pitched = flat * (1 / math.cos(pitch * math.pi / 180));
    }
    final total = pitched * (1 + wastage / 100);
    setState(() {
      _flatArea = flat;
      _pitchedArea = pitched;
      _totalWithWastage = total;
    });
  }

  void _clear() {
    _lengthController.clear();
    _widthController.clear();
    _pitchController.clear();
    _wastageController.text = '10';
    setState(() {
      _flatArea = null;
      _pitchedArea = null;
      _totalWithWastage = null;
    });
  }

  void _shareAreaCalculation() {
    if (_flatArea == null || _pitchedArea == null || _totalWithWastage == null) return;
    final text = '📐 Roof Area Calculation\n'
      'Length: ${_lengthController.text}m × Width: ${_widthController.text}m\n'
      '${_pitchController.text.isNotEmpty ? 'Pitch: ${_pitchController.text}°\n' : ''}'
      'Flat Area: ${_flatArea!.toStringAsFixed(2)} m²\n'
      'Pitched Area: ${_pitchedArea!.toStringAsFixed(2)} m²\n'
      'Total + ${_wastageController.text}% wastage: ${_totalWithWastage!.toStringAsFixed(2)} m²\n\n'
      'Calculated by Roof Profile Finder';
    Share.share(text, sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1));
  }

  Widget _inputField(String label, TextEditingController controller, {String? suffix, String? hint, IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint ?? '0.0',
          suffixText: suffix,
          prefixIcon: icon == null ? null : Icon(icon),
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.shade400),
          ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F2E8),
      appBar: AppBar(
        title: const Text('Roof Area Calculator'),
        backgroundColor: Colors.teal.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(tooltip: 'Clear', onPressed: _clear, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _buildHeroCard(),
          const SizedBox(height: 16),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.straighten, color: Colors.teal.shade700),
                  const SizedBox(width: 8),
                  const Text('Measurements', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: _inputField('Length', _lengthController, suffix: 'm', icon: Icons.swap_horiz)),
                  const SizedBox(width: 12),
                  Expanded(child: _inputField('Width', _widthController, suffix: 'm', icon: Icons.swap_vert)),
                ]),
                Row(children: [
                  Expanded(child: _inputField('Roof Pitch', _pitchController, suffix: '°', hint: 'optional', icon: Icons.architecture)),
                  const SizedBox(width: 12),
                  Expanded(child: _inputField('Wastage', _wastageController, suffix: '%', icon: Icons.percent)),
                ]),
                const SizedBox(height: 4),
                Row(children: [
                  Expanded(child: ElevatedButton.icon(
                    onPressed: _calculate,
                    icon: const Icon(Icons.calculate),
                    label: const Text('Calculate'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  )),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _clear,
                    icon: const Icon(Icons.clear),
                    label: const Text('Clear'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
          if (_flatArea != null) ...[
            const SizedBox(height: 20),
            const Text('Calculation Results', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.55,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              children: [
                _resultTile(Icons.crop_square, 'Flat Area', '${_flatArea!.toStringAsFixed(2)} m²', Colors.grey.shade700),
                _resultTile(Icons.roofing, 'Pitched Area', '${_pitchedArea!.toStringAsFixed(2)} m²', Colors.teal.shade700),
                _resultTile(Icons.add_chart, 'With Wastage', '${_totalWithWastage!.toStringAsFixed(2)} m²', Colors.blue.shade700),
                _resultTile(Icons.percent, 'Wastage', '${_wastageController.text}%', Colors.orange.shade700),
              ],
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: ElevatedButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MaterialListScreen())),
                icon: const Icon(Icons.playlist_add),
                label: const Text('Open Material List'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              )),
              const SizedBox(width: 10),
              Expanded(child: OutlinedButton.icon(
                onPressed: _shareAreaCalculation,
                icon: const Icon(Icons.share),
                label: const Text('Share Results'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              )),
            ]),
          ],
          const SizedBox(height: 30),
        ]),
      ),
    );
  }

  Widget _buildHeroCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [Colors.teal.shade800, Colors.teal.shade600]),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 12, offset: const Offset(0, 6))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.16), borderRadius: BorderRadius.circular(14)),
            child: const Icon(Icons.area_chart, color: Colors.white, size: 30),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Calculate roof area fast', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            SizedBox(height: 4),
            Text('Enter length, width, pitch and wastage for quick estimating on site.', style: TextStyle(color: Colors.white70, fontSize: 13)),
          ])),
        ]),
        const SizedBox(height: 16),
        Container(
          height: 120,
          width: double.infinity,
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.12), borderRadius: BorderRadius.circular(14)),
          child: Stack(children: [
            Positioned(left: 24, right: 24, top: 24, child: Container(height: 68, decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 2), borderRadius: BorderRadius.circular(8)))),
            Positioned(left: 54, top: 18, child: Transform.rotate(angle: -0.45, child: Container(width: 2, height: 82, color: Colors.white70))),
            Positioned(right: 54, top: 18, child: Transform.rotate(angle: 0.45, child: Container(width: 2, height: 82, color: Colors.white70))),
            const Positioned(left: 34, top: 48, child: Text('Length', style: TextStyle(color: Colors.white70, fontSize: 12))),
            const Positioned(right: 34, top: 48, child: Text('Width', style: TextStyle(color: Colors.white70, fontSize: 12))),
            Positioned(bottom: 12, left: 0, right: 0, child: Center(child: Text('Area • pitch • wastage', style: TextStyle(color: Colors.teal.shade50, fontWeight: FontWeight.bold)))),
          ]),
        ),
      ]),
    );
  }

  Widget _resultTile(IconData icon, String label, String value, Color color) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Icon(icon, color: color, size: 24),
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          FittedBox(child: Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color))),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Rafter Calculator
// ═══════════════════════════════════════════════════════════════

class RafterCalculator extends StatefulWidget {
  const RafterCalculator({super.key});
  @override
  State<RafterCalculator> createState() => _RafterCalculatorState();
}

class _RafterCalculatorState extends State<RafterCalculator> {
  final _spanController = TextEditingController();
  final _pitchController = TextEditingController();
  final _eavesController = TextEditingController(text: '0.3');
  final _spacingController = TextEditingController(text: '600');
  final _buildingLengthController = TextEditingController();

  double? _rafterLength;
  double? _ridgeHeight;
  double? _halfSpan;
  int? _numberOfRafters;
  bool _isHip = false;

  double? _hipLength;
  double? _hipPlumbCut;
  double? _hipSeatCut;
  double? _hipDihedral;
  int _savedCount = 0;

  @override
  void initState() {
    super.initState();
    _loadSavedCount();
  }

  Future<void> _loadSavedCount() async {
    final all = await RafterSaveService.loadAll();
    if (mounted) setState(() { _savedCount = all.length; });
  }

  Future<void> _saveCalculation() async {
    final pitch = double.tryParse(_pitchController.text) ?? 0;
    final autoName = _spanController.text.isNotEmpty
      ? 'Span ${_spanController.text}m @ ${pitch.toStringAsFixed(0)}°'
      : 'Rafter ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}';
    final nameController = TextEditingController(text: autoName);
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Row(children: [Icon(Icons.save, color: Colors.brown), SizedBox(width: 8), Text('Save Calculation')]),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Enter a name for this calculation:'),
        const SizedBox(height: 12),
        TextField(controller: nameController, textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(border: OutlineInputBorder(), prefixIcon: Icon(Icons.architecture)),
          autofocus: true),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.brown.shade600, foregroundColor: Colors.white),
          child: const Text('Save')),
      ],
    ));
    if (confirm != true) return;
    final data = {
      'name': nameController.text.trim().isNotEmpty ? nameController.text.trim() : autoName,
      'savedAt': DateTime.now().toIso8601String(),
      'span': _spanController.text,
      'pitch': _pitchController.text,
      'eaves': _eavesController.text,
      'spacing': _spacingController.text,
      'buildingLength': _buildingLengthController.text,
      'isHip': _isHip,
      'rafterLength': _rafterLength,
      'ridgeHeight': _ridgeHeight,
      'halfSpan': _halfSpan,
      'numberOfRafters': _numberOfRafters,
      'hipLength': _hipLength,
      'hipPlumbCut': _hipPlumbCut,
      'hipSeatCut': _hipSeatCut,
      'hipDihedral': _hipDihedral,
    };
    await RafterSaveService.save(data);
    await _loadSavedCount();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('✓ Saved: ${data['name']}'),
      backgroundColor: Colors.brown.shade600,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  void dispose() {
    _spanController.dispose();
    _pitchController.dispose();
    _eavesController.dispose();
    _spacingController.dispose();
    _buildingLengthController.dispose();
    super.dispose();
  }

  void _calculate() {
    final span = double.tryParse(_spanController.text);
    final pitch = double.tryParse(_pitchController.text);
    final eaves = double.tryParse(_eavesController.text) ?? 0.3;
    final spacing = double.tryParse(_spacingController.text) ?? 600;
    final buildingLength = double.tryParse(_buildingLengthController.text);

    if (span == null || pitch == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter span and pitch angle to calculate')));
      return;
    }

    final double pitchRad = pitch * math.pi / 180;
    final double half = span / 2;
    final double rafterRun = half + eaves;
    final double rafterLen = rafterRun / math.cos(pitchRad);
    final double ridgeHt = half * math.tan(pitchRad);

    int? numRafters;
    if (buildingLength != null && spacing > 0) {
      numRafters = ((buildingLength * 1000 / spacing).ceil() + 1) * 2;
    }

    final double hipRun = half * math.sqrt(2) + eaves;
    final double hipPitchRad = math.atan(ridgeHt / (half * math.sqrt(2)));
    final double hipLen = hipRun / math.cos(hipPitchRad);
    final double hipPlumb = hipPitchRad * 180 / math.pi;
    final double hipSeat = 90 - hipPlumb;
    final double dihedral = math.atan(math.sin(pitchRad) / math.tan(math.pi / 4)) * 180 / math.pi;

    setState(() {
      _rafterLength = rafterLen;
      _ridgeHeight = ridgeHt;
      _halfSpan = half;
      _numberOfRafters = numRafters;
      _hipLength = hipLen;
      _hipPlumbCut = hipPlumb;
      _hipSeatCut = hipSeat;
      _hipDihedral = dihedral;
    });
  }

  void _clear() {
    _spanController.clear();
    _pitchController.clear();
    _eavesController.text = '0.3';
    _spacingController.text = '600';
    _buildingLengthController.clear();
    setState(() {
      _rafterLength = null;
      _ridgeHeight = null;
      _halfSpan = null;
      _numberOfRafters = null;
      _hipLength = null;
      _hipPlumbCut = null;
      _hipSeatCut = null;
      _hipDihedral = null;
    });
  }

  void _shareRafterCalculation() {
    if (_rafterLength == null || _ridgeHeight == null) return;
    final pitch = double.tryParse(_pitchController.text) ?? 0;
    final seatCut = 90 - pitch;
    String text = '📐 Rafter Calculation\n'
      'Span: ${_spanController.text}m  |  Pitch: ${_pitchController.text}°\n'
      'Eaves: ${_eavesController.text}m\n\n'
      'Common Rafter Length: ${_rafterLength!.toStringAsFixed(3)} m\n'
      'Ridge Height: ${_ridgeHeight!.toStringAsFixed(3)} m\n'
      'Plumb Cut: ${pitch.toStringAsFixed(1)}°\n'
      'Seat Cut: ${seatCut.toStringAsFixed(1)}°\n';
    if (_isHip && _hipLength != null) {
      text += '\nHip Rafter Length: ${_hipLength!.toStringAsFixed(3)} m\n'
        'Hip Plumb Cut: ${_hipPlumbCut!.toStringAsFixed(1)}°\n'
        'Hip Seat Cut: ${_hipSeatCut!.toStringAsFixed(1)}°\n'
        'Backing Angle: ${_hipDihedral!.toStringAsFixed(1)}°\n';
    }
    if (_numberOfRafters != null) text += '\nRafters needed: $_numberOfRafters\n';
    text += '\nCalculated by Roof Profile Finder';
    Share.share(text, sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1));
  }

  Widget _inputField(String label, TextEditingController controller, {String? suffix, String? hint, IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint ?? '0.0',
          suffixText: suffix,
          prefixIcon: icon == null ? null : Icon(icon),
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade400)),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        ),
      ),
    );
  }


  void _setPitchPreset(String value) {
    setState(() {
      _pitchController.text = value;
    });
  }

  Widget _buildPitchPresetChips() {
    const presets = <String>['15', '22.5', '30', '35', '40', '45'];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Quick pitch presets', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.brown.shade800)),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: presets.map((p) {
          final selected = _pitchController.text.trim() == p;
          return ChoiceChip(
            label: Text('$p°'),
            selected: selected,
            visualDensity: VisualDensity.compact,
            selectedColor: Colors.brown.shade100,
            onSelected: (_) => _setPitchPreset(p),
          );
        }).toList(),
      ),
      const SizedBox(height: 14),
    ]);
  }

  Widget _responsivePair(Widget left, Widget right) {
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 430) {
        return Column(children: [left, right]);
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: left),
        const SizedBox(width: 12),
        Expanded(child: right),
      ]);
    });
  }

  Widget _buildCalculateButtons() {
    return LayoutBuilder(builder: (context, constraints) {
      final calculateButton = ElevatedButton.icon(
        onPressed: _calculate,
        icon: const Icon(Icons.calculate),
        label: const Text('Calculate'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.brown.shade600,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      final clearButton = OutlinedButton.icon(
        onPressed: _clear,
        icon: const Icon(Icons.clear),
        label: const Text('Clear'),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      if (constraints.maxWidth < 360) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          calculateButton,
          const SizedBox(height: 10),
          clearButton,
        ]);
      }
      return Row(children: [
        Expanded(child: calculateButton),
        const SizedBox(width: 12),
        clearButton,
      ]);
    });
  }

  Widget _buildHowToUseCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.brown.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.brown.shade100),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.tips_and_updates_outlined, color: Colors.brown.shade700, size: 22),
        const SizedBox(width: 10),
        Expanded(child: Text(
          'Enter the full wall-to-wall span and roof pitch. Add building length only if you want the app to estimate rafter quantity.',
          style: TextStyle(fontSize: 12.5, height: 1.35, color: Colors.brown.shade900),
        )),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F2E8),
      appBar: AppBar(
        title: const Text('Rafter Calculator'),
        backgroundColor: Colors.brown.shade600,
        foregroundColor: Colors.white,
        actions: [
          Stack(children: [
            IconButton(
              tooltip: 'Saved calculations',
              icon: const Icon(Icons.folder_outlined),
              onPressed: _showSavedCalculations,
            ),
            if (_savedCount > 0)
              Positioned(right: 6, top: 6, child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle),
                child: Text('$_savedCount', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
              )),
          ]),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _buildRafterHeroCard(),
          const SizedBox(height: 16),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('Rafter Type:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                    ChoiceChip(
                      label: const Text('Common'),
                      avatar: !_isHip ? const Icon(Icons.check, size: 18) : null,
                      selected: !_isHip,
                      onSelected: (_) => setState(() { _isHip = false; }),
                    ),
                    ChoiceChip(
                      label: const Text('Hip'),
                      avatar: _isHip ? const Icon(Icons.check, size: 18) : const Icon(Icons.architecture, size: 18),
                      selected: _isHip,
                      onSelected: (_) => setState(() { _isHip = true; }),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Text('Measurements', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                _buildHowToUseCard(),
                const SizedBox(height: 14),
                _buildPitchPresetChips(),
                _inputField('Full Span (wall to wall)', _spanController, suffix: 'm', icon: Icons.swap_horiz),
                _responsivePair(
                  _inputField('Pitch Angle', _pitchController, suffix: '°', icon: Icons.architecture),
                  _inputField('Eaves Overhang', _eavesController, suffix: 'm', icon: Icons.keyboard_double_arrow_right),
                ),
                _responsivePair(
                  _inputField('Rafter Spacing', _spacingController, suffix: 'mm', icon: Icons.format_line_spacing),
                  _inputField('Building Length', _buildingLengthController, suffix: 'm', hint: 'optional', icon: Icons.home_work),
                ),
                const SizedBox(height: 4),
                _buildCalculateButtons(),
              ]),
            ),
          ),
          if (_rafterLength != null && _ridgeHeight != null && _halfSpan != null) ...[
            const SizedBox(height: 20),
            const Text('Results', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.55,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              children: [
                _resultTile(Icons.straighten, 'Half Span', '${_halfSpan!.toStringAsFixed(3)} m', Colors.grey.shade700),
                _resultTile(Icons.architecture, _isHip ? 'Hip Rafter' : 'Common Rafter', '${(_isHip ? _hipLength! : _rafterLength!).toStringAsFixed(3)} m', Colors.brown.shade700),
                _resultTile(Icons.height, 'Ridge Height', '${_ridgeHeight!.toStringAsFixed(3)} m', Colors.brown.shade700),
                _resultTile(Icons.view_week, 'Rafters', _numberOfRafters == null ? 'Optional' : '$_numberOfRafters', Colors.blue.shade700),
              ],
            ),
            const SizedBox(height: 18),
            Text(_isHip ? 'Hip Rafter Cut Sheet' : 'Common Rafter Cut Sheet', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            _buildCutSheet(),
            const SizedBox(height: 18),
            Text(_isHip ? 'Hip Rafter Diagram' : 'Common Rafter Diagram', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: RafterDiagram(
                  halfSpan: _halfSpan!,
                  rafterLength: _isHip ? _hipLength! : _rafterLength!,
                  ridgeHeight: _ridgeHeight!,
                  pitchDegrees: _isHip ? _hipPlumbCut! : double.tryParse(_pitchController.text) ?? 0,
                  eavesOverhang: double.tryParse(_eavesController.text) ?? 0.3,
                  isHip: _isHip,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: ElevatedButton.icon(
                onPressed: _saveCalculation,
                icon: const Icon(Icons.save),
                label: const Text('Save Result'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.brown.shade600,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              )),
              const SizedBox(width: 10),
              Expanded(child: OutlinedButton.icon(
                onPressed: _shareRafterCalculation,
                icon: const Icon(Icons.share),
                label: const Text('Share'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              )),
            ]),
          ],
          const SizedBox(height: 30),
        ]),
      ),
    );
  }

  Widget _buildRafterHeroCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [Colors.brown.shade800, Colors.brown.shade600]),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 12, offset: const Offset(0, 6))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.16), borderRadius: BorderRadius.circular(14)),
            child: const Icon(Icons.carpenter, color: Colors.white, size: 30),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Rafter calculator', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            SizedBox(height: 4),
            Text('Common and hip rafters with span, rise, pitch, eaves and cut angles.', style: TextStyle(color: Colors.white70, fontSize: 13)),
          ])),
        ]),
        const SizedBox(height: 16),
        Container(
          height: 150,
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.12), borderRadius: BorderRadius.circular(14)),
          child: CustomPaint(painter: _RafterHeroTrussPainter()),
        ),
      ]),
    );
  }

  Widget _resultTile(IconData icon, String label, String value, Color color) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Icon(icon, color: color, size: 24),
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          FittedBox(child: Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color))),
        ]),
      ),
    );
  }

  Widget _buildCutSheet() {
    final pitch = double.tryParse(_pitchController.text) ?? 0;
    final seatCut = 90 - pitch;
    final pitchRad = pitch * math.pi / 180;
    final double birdWidth = pitchRad > 0 ? 50.0 / math.tan(pitchRad) : 50.0;

    if (_isHip && _hipLength != null) {
      return Card(
        elevation: 2,
        color: Colors.orange.shade50,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Icon(Icons.content_cut, color: Colors.orange.shade700, size: 20), const SizedBox(width: 8),
            Text('Hip Rafter Cuts', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.orange.shade800))]),
          const SizedBox(height: 12),
          _cutRow('🔝 Ridge Plumb Cut', '${_hipPlumbCut!.toStringAsFixed(1)}°', 'Set bevel to ${_hipPlumbCut!.toStringAsFixed(1)}° from vertical'),
          _cutRow('📐 Cheek Cut (Side)', '45°', 'Cut both sides at 45° in plan'),
          _cutRow('🪚 Seat Cut', '${_hipSeatCut!.toStringAsFixed(1)}°', 'Horizontal cut at wall plate'),
          _cutRow('📏 Seat Depth', '50mm', 'Standard seat depth'),
          _cutRow('🔄 Backing Angle', '${_hipDihedral!.toStringAsFixed(1)}°', 'Bevel top of hip for jack rafters'),
          _cutRow('⬇️ Tail Plumb Cut', '${_hipPlumbCut!.toStringAsFixed(1)}°', 'Same angle as ridge plumb cut'),
          const SizedBox(height: 8),
          Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.orange.shade100, borderRadius: BorderRadius.circular(10)),
            child: Text('Set compound mitre saw to ${_hipPlumbCut!.toStringAsFixed(1)}° bevel and 45° mitre for cheek cuts.', style: TextStyle(fontSize: 12, color: Colors.orange.shade900))),
        ])),
      );
    }

    return Card(
      elevation: 2,
      color: Colors.brown.shade50,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(Icons.content_cut, color: Colors.brown.shade700, size: 20), const SizedBox(width: 8),
          Text('Common Rafter Cuts', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.brown.shade800))]),
        const SizedBox(height: 12),
        _cutRow('🔝 Ridge Plumb Cut', '${pitch.toStringAsFixed(1)}°', 'Set bevel to ${pitch.toStringAsFixed(1)}° from vertical'),
        _cutRow('🪚 Seat Cut (Bird\'s Mouth)', '${seatCut.toStringAsFixed(1)}°', 'Set square to ${seatCut.toStringAsFixed(1)}°'),
        _cutRow('📏 Bird\'s Mouth Depth', '50mm', 'Plumb depth at wall plate'),
        _cutRow('📐 Bird\'s Mouth Width', '${birdWidth.toStringAsFixed(0)}mm', 'Horizontal seat width'),
        _cutRow('⬇️ Tail Plumb Cut', '${pitch.toStringAsFixed(1)}°', 'Same angle as ridge plumb cut'),
        _cutRow('📏 Rafter Length', '${_rafterLength!.toStringAsFixed(3)}m', 'Ridge centre to tail cut'),
        const SizedBox(height: 8),
        Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.brown.shade100, borderRadius: BorderRadius.circular(10)),
          child: Text('Set circular saw bevel to ${pitch.toStringAsFixed(1)}° for plumb cuts. Bird\'s mouth seat cut is ${seatCut.toStringAsFixed(1)}°.', style: TextStyle(fontSize: 12, color: Colors.brown.shade900))),
      ])),
    );
  }

  Widget _cutRow(String label, String value, String note) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: 3, child: Text(label, style: const TextStyle(fontSize: 13))),
        const SizedBox(width: 8),
        Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.brown.shade800)),
          Text(note, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ])),
      ]),
    );
  }

  Future<void> _showSavedCalculations() async {
    final all = await RafterSaveService.loadAll();
    if (!mounted) return;
    if (all.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No saved rafter calculations yet.')));
      return;
    }
    await showModalBottomSheet<void>(context: context, showDragHandle: true, builder: (ctx) => ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: all.length,
      separatorBuilder: (_, __) => const Divider(),
      itemBuilder: (_, index) {
        final item = all[index];
        final name = (item['name'] ?? 'Saved calculation').toString();
        final span = (item['span'] ?? '').toString();
        final pitch = (item['pitch'] ?? '').toString();
        return ListTile(
          leading: CircleAvatar(backgroundColor: Colors.brown.shade100, child: Icon(Icons.architecture, color: Colors.brown.shade700)),
          title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('Span ${span.isEmpty ? '-' : span}m • Pitch ${pitch.isEmpty ? '-' : pitch}°'),
          onTap: () {
            Navigator.pop(ctx);
            setState(() {
              _spanController.text = span;
              _pitchController.text = pitch;
              _eavesController.text = (item['eaves'] ?? '0.3').toString();
              _spacingController.text = (item['spacing'] ?? '600').toString();
              _buildingLengthController.text = (item['buildingLength'] ?? '').toString();
              _isHip = item['isHip'] == true;
            });
            _calculate();
          },
        );
      },
    ));
  }
}

class RafterDiagram extends StatefulWidget {
  final double halfSpan;
  final double rafterLength;
  final double ridgeHeight;
  final double pitchDegrees;
  final double eavesOverhang;
  final bool isHip;

  const RafterDiagram({
    super.key,
    required this.halfSpan,
    required this.rafterLength,
    required this.ridgeHeight,
    required this.pitchDegrees,
    required this.eavesOverhang,
    this.isHip = false,
  });

  @override
  State<RafterDiagram> createState() => _RafterDiagramState();
}

class _RafterDiagramState extends State<RafterDiagram> {
  String? _zoomedSection;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      if (_zoomedSection == null)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.touch_app, size: 14, color: Colors.grey.shade500),
            const SizedBox(width: 4),
            Text('Tap ridge, bird\'s mouth or tail to zoom in',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ]),
        )
      else
        TextButton.icon(
          onPressed: () => setState(() { _zoomedSection = null; }),
          icon: const Icon(Icons.zoom_out, size: 16),
          label: const Text('Back to full view', style: TextStyle(fontSize: 12)),
          style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
        ),

      if (_zoomedSection == null)
        GestureDetector(
          onTapDown: (details) => _handleTap(details.localPosition, context),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: CustomPaint(
              painter: _RafterPainter(
                halfSpan: widget.halfSpan,
                rafterLength: widget.rafterLength,
                ridgeHeight: widget.ridgeHeight,
                pitchDegrees: widget.pitchDegrees,
                eavesOverhang: widget.eavesOverhang,
                isHip: widget.isHip,
                showTapHints: true,
              ),
            ),
          ),
        )
      else
        _buildZoomedView(),

      const SizedBox(height: 12),
      Wrap(spacing: 16, runSpacing: 6, children: [
        _legendItem(widget.isHip ? Colors.orange.shade700 : Colors.brown.shade700, widget.isHip ? 'Hip Rafter' : 'Rafter'),
        _legendItem(Colors.blue.shade700, 'Ridge'),
        _legendItem(Colors.grey.shade600, 'Wall plate'),
        _legendItem(Colors.red.shade600, 'Bird\'s mouth'),
      ]),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: widget.isHip ? Colors.orange.shade50 : Colors.brown.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: widget.isHip ? Colors.orange.shade200 : Colors.brown.shade200),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          _cutInfo('Plumb Cut', '${widget.pitchDegrees.toStringAsFixed(1)}°', Icons.architecture),
          _cutInfo('Seat Cut', '${(90 - widget.pitchDegrees).toStringAsFixed(1)}°', Icons.architecture),
          if (widget.isHip) _cutInfo('Cheek Cut', '45°', Icons.rotate_90_degrees_ccw),
          _cutInfo('Eaves', '${(widget.eavesOverhang * 1000).toStringAsFixed(0)}mm', Icons.straighten),
        ]),
      ),
    ]);
  }

  void _handleTap(Offset pos, BuildContext context) {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final double width = box.size.width;
    final double relX = pos.dx / width;
    if (relX < 0.25) {
      setState(() { _zoomedSection = 'tail'; });
    } else if (relX > 0.75) {
      setState(() { _zoomedSection = 'ridge'; });
    } else {
      setState(() { _zoomedSection = 'birdmouth'; });
    }
  }

  Widget _buildZoomedView() {
    final pitch = widget.pitchDegrees;
    final seatCut = 90 - pitch;
    final pitchRad = pitch * math.pi / 180;
    final birdWidth = pitchRad > 0 ? 50.0 / math.tan(pitchRad) : 50.0;

    switch (_zoomedSection) {
      case 'ridge':
        return _zoomCard('Ridge / Plumb Cut', Colors.blue.shade700, [
          AspectRatio(aspectRatio: 2,
            child: CustomPaint(painter: _RidgeZoomPainter(pitchDegrees: pitch, isHip: widget.isHip))),
          const SizedBox(height: 8),
          _zoomDetail('Plumb Cut Angle', '${pitch.toStringAsFixed(1)}°'),
          _zoomDetail('Set bevel to', '${pitch.toStringAsFixed(1)}° from vertical'),
          if (widget.isHip) _zoomDetail('Cheek Cut', '45° both sides'),
        ]);
      case 'birdmouth':
        return _zoomCard('Bird\'s Mouth Cut', Colors.red.shade700, [
          AspectRatio(aspectRatio: 2,
            child: CustomPaint(painter: _BirdMouthZoomPainter(pitchDegrees: pitch))),
          const SizedBox(height: 8),
          _zoomDetail('Plumb Cut Depth', '50mm'),
          _zoomDetail('Seat Cut Width', '${birdWidth.toStringAsFixed(0)}mm'),
          _zoomDetail('Seat Angle', '${seatCut.toStringAsFixed(1)}°'),
          _zoomDetail('Plumb Angle', '${pitch.toStringAsFixed(1)}°'),
        ]);
      case 'tail':
        return _zoomCard('Tail / Eaves Cut', Colors.green.shade700, [
          AspectRatio(aspectRatio: 2,
            child: CustomPaint(painter: _TailZoomPainter(pitchDegrees: pitch, eavesOverhang: widget.eavesOverhang))),
          const SizedBox(height: 8),
          _zoomDetail('Tail Plumb Cut', '${pitch.toStringAsFixed(1)}°'),
          _zoomDetail('Eaves Overhang', '${(widget.eavesOverhang * 1000).toStringAsFixed(0)}mm'),
          _zoomDetail('Fascia Cut', 'Square or plumb to suit'),
        ]);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _zoomCard(String title, Color color, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 8),
        ...children,
      ]),
    );
  }

  Widget _zoomDetail(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Expanded(child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade700))),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
      ]),
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 20, height: 3, color: color),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 11)),
    ]);
  }

  Widget _cutInfo(String label, String value, IconData icon) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 16, color: Colors.brown.shade600),
      const SizedBox(height: 2),
      Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.brown.shade700)),
      Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
    ]);
  }
}


class _RafterHeroTrussPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final dimPaint = Paint()
      ..color = Colors.orange.shade100
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final fillPaint = Paint()
      ..color = Colors.white.withOpacity(0.14)
      ..style = PaintingStyle.fill;

    final w = size.width;
    final h = size.height;
    final left = Offset(w * 0.13, h * 0.76);
    final right = Offset(w * 0.87, h * 0.76);
    final ridge = Offset(w * 0.50, h * 0.22);
    final tieLeft = Offset(w * 0.25, h * 0.76);
    final tieRight = Offset(w * 0.75, h * 0.76);

    final roofPath = Path()
      ..moveTo(left.dx, left.dy)
      ..lineTo(ridge.dx, ridge.dy)
      ..lineTo(right.dx, right.dy)
      ..lineTo(left.dx, left.dy);
    canvas.drawPath(roofPath, fillPaint);

    canvas.drawLine(left, ridge, paint);
    canvas.drawLine(ridge, right, paint);
    canvas.drawLine(left, right, paint..strokeWidth = 4);
    canvas.drawLine(ridge, Offset(w * 0.50, h * 0.76), paint..strokeWidth = 3);
    canvas.drawLine(tieLeft, ridge, paint..strokeWidth = 3);
    canvas.drawLine(tieRight, ridge, paint..strokeWidth = 3);

    final baseY = h * 0.90;
    canvas.drawLine(Offset(left.dx, baseY), Offset(right.dx, baseY), dimPaint);
    canvas.drawLine(Offset(left.dx, baseY - 5), Offset(left.dx, baseY + 5), dimPaint);
    canvas.drawLine(Offset(right.dx, baseY - 5), Offset(right.dx, baseY + 5), dimPaint);

    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    void label(String text, Offset pos, {double size = 12, FontWeight weight = FontWeight.w600}) {
      textPainter.text = TextSpan(
        text: text,
        style: TextStyle(color: Colors.orange.shade100, fontSize: size, fontWeight: weight),
      );
      textPainter.layout();
      textPainter.paint(canvas, pos);
    }

    label('span', Offset(w * 0.45, baseY - 22));
    label('pitch', Offset(w * 0.66, h * 0.38));
    label('rafter length', Offset(w * 0.18, h * 0.34));
    label('rise', Offset(w * 0.52, h * 0.48));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _RafterPainter extends CustomPainter {
  final double halfSpan;
  final double rafterLength;
  final double ridgeHeight;
  final double pitchDegrees;
  final double eavesOverhang;
  final bool isHip;
  final bool showTapHints;

  _RafterPainter({
    required this.halfSpan,
    required this.rafterLength,
    required this.ridgeHeight,
    required this.pitchDegrees,
    required this.eavesOverhang,
    this.isHip = false,
    this.showTapHints = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double margin = 40.0;
    final double w = size.width - margin * 2;
    final double h = size.height - margin * 2;
    final double totalRun = halfSpan + eavesOverhang;
    final double scaleX = w / (totalRun * 1.2);
    final double scaleY = h / (ridgeHeight * 1.4);
    final double scale = math.min(scaleX, scaleY);

    final double ox = margin + 10;
    final double oy = size.height - margin;
    final double eavesX = ox;
    final double wallX = ox + eavesOverhang * scale;
    final double ridgeX = wallX + halfSpan * scale;
    final double ridgeY = oy - ridgeHeight * scale;
    final double wallY = oy;

    final double birdDepth = math.min(ridgeHeight * scale * 0.12, 18);
    final double pitchRad = pitchDegrees * math.pi / 180;
    final double birdWidth = pitchRad > 0 ? birdDepth / math.tan(pitchRad) : birdDepth;

    final rafterColor = isHip ? Colors.orange.shade700 : Colors.brown.shade700;
    final rafterPaint = Paint()..color = rafterColor..strokeWidth = 5..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
    final wallPaint = Paint()..color = Colors.grey.shade600..strokeWidth = 3..style = PaintingStyle.stroke;
    final ridgePaint = Paint()..color = Colors.blue.shade700..strokeWidth = 4..style = PaintingStyle.stroke;
    final birdPaint = Paint()..color = Colors.red.shade600..strokeWidth = 2..style = PaintingStyle.stroke;
    final dashPaint = Paint()..color = Colors.blue.shade200..strokeWidth = 1;
    final dimPaint = Paint()..color = Colors.grey.shade500..strokeWidth = 1..style = PaintingStyle.stroke;
    final textStyle = TextStyle(color: Colors.grey.shade700, fontSize: 10);
    final boldStyle = TextStyle(color: rafterColor, fontSize: 11, fontWeight: FontWeight.bold);

    canvas.drawLine(Offset(eavesX - 5, wallY), Offset(ridgeX + 10, wallY), wallPaint);
    canvas.drawLine(Offset(eavesX, wallY), Offset(ridgeX, ridgeY), rafterPaint);
    canvas.drawLine(Offset(ridgeX - 15, ridgeY), Offset(ridgeX + 15, ridgeY), ridgePaint);

    final birdPath = Path();
    birdPath.moveTo(wallX - birdWidth, wallY - birdDepth * 2);
    birdPath.lineTo(wallX, wallY);
    birdPath.lineTo(wallX + birdDepth, wallY - birdDepth);
    canvas.drawPath(birdPath, birdPaint);

    double dashY = ridgeY;
    while (dashY < wallY) {
      canvas.drawLine(Offset(ridgeX, dashY), Offset(ridgeX, math.min(dashY + 6, wallY)), dashPaint);
      dashY += 10;
    }
    double dashX = wallX;
    while (dashX < ridgeX) {
      canvas.drawLine(Offset(dashX, wallY + 15), Offset(math.min(dashX + 6, ridgeX), wallY + 15), dashPaint);
      dashX += 10;
    }

    canvas.drawLine(Offset(eavesX, wallY + 8), Offset(wallX, wallY + 8), dimPaint);

    final arcRect = Rect.fromCenter(center: Offset(wallX, wallY), width: 40, height: 40);
    canvas.drawArc(arcRect, -math.pi, pitchDegrees * math.pi / 180, false,
      Paint()..color = Colors.orange.shade400..strokeWidth = 1.5..style = PaintingStyle.stroke);

    if (showTapHints) {
      final hintPaint = Paint()..color = Colors.blue.shade100.withOpacity(0.4)..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(ridgeX, ridgeY + 10), 20, hintPaint);
      canvas.drawCircle(Offset(wallX, wallY - 12), 20, hintPaint);
      canvas.drawCircle(Offset(eavesX + 5, wallY - 10), 20, hintPaint);
    }

    void drawText(String text, Offset pos, {bool bold = false}) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: bold ? boldStyle : textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos);
    }

    drawText('${rafterLength.toStringAsFixed(2)}m', Offset((eavesX + ridgeX) / 2 - 30, (wallY + ridgeY) / 2 - 16), bold: true);
    drawText('H: ${ridgeHeight.toStringAsFixed(2)}m', Offset(ridgeX + 8, (ridgeY + wallY) / 2), bold: true);
    drawText('Run: ${halfSpan.toStringAsFixed(2)}m', Offset(wallX + (ridgeX - wallX) / 2 - 25, wallY + 18));
    if (eavesOverhang > 0) drawText('${(eavesOverhang * 1000).toStringAsFixed(0)}mm', Offset(eavesX, wallY + 18));
    drawText('${pitchDegrees.toStringAsFixed(0)}°', Offset(wallX + 22, wallY - 14));
    drawText('Ridge', Offset(ridgeX - 15, ridgeY - 16));
    drawText("Bird's\nmouth", Offset(wallX - 38, wallY - birdDepth * 3 - 10));
    if (showTapHints) {
      final hintStyle = TextStyle(color: Colors.blue.shade600, fontSize: 9);
      void drawHint(String t, Offset pos) {
        final tp = TextPainter(text: TextSpan(text: t, style: hintStyle), textDirection: TextDirection.ltr)..layout();
        tp.paint(canvas, pos);
      }
      drawHint('tap', Offset(ridgeX - 8, ridgeY + 22));
      drawHint('tap', Offset(wallX - 8, wallY - 8));
      drawHint('tap', Offset(eavesX - 4, wallY - 28));
    }
  }

  @override
  bool shouldRepaint(_RafterPainter old) => true;
}

class _RidgeZoomPainter extends CustomPainter {
  final double pitchDegrees;
  final bool isHip;
  _RidgeZoomPainter({required this.pitchDegrees, this.isHip = false});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.7;
    final len = size.height * 0.55;
    final pitchRad = pitchDegrees * math.pi / 180;
    final paint = Paint()..color = isHip ? Colors.orange.shade700 : Colors.brown.shade700..strokeWidth = 6..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
    final ridgePaint = Paint()..color = Colors.blue.shade700..strokeWidth = 4..style = PaintingStyle.stroke;

    canvas.drawLine(Offset(cx - len * math.cos(pitchRad), cy + len * math.sin(pitchRad)), Offset(cx, cy), paint);
    canvas.drawLine(Offset(cx - 20, cy), Offset(cx + 20, cy), ridgePaint);
    canvas.drawLine(Offset(cx, cy), Offset(cx, cy - 30),
      Paint()..color = Colors.red.shade600..strokeWidth = 1.5..style = PaintingStyle.stroke);

    final arcRect = Rect.fromCenter(center: Offset(cx, cy), width: 50, height: 50);
    canvas.drawArc(arcRect, -math.pi / 2, -pitchRad, false,
      Paint()..color = Colors.orange.shade500..strokeWidth = 2..style = PaintingStyle.stroke);

    void label(String t, Offset pos, Color c, {bool bold = false}) {
      final tp = TextPainter(text: TextSpan(text: t, style: TextStyle(color: c, fontSize: bold ? 12 : 10, fontWeight: bold ? FontWeight.bold : FontWeight.normal)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, pos);
    }
    label('${pitchDegrees.toStringAsFixed(1)}°', Offset(cx + 10, cy - 30), Colors.orange.shade700, bold: true);
    label('Plumb cut', Offset(cx - 25, cy - 50), Colors.grey.shade600);
    label('Ridge board', Offset(cx + 22, cy - 8), Colors.blue.shade700);
    if (isHip) label('+ 45° cheek cut', Offset(cx - 60, cy + 10), Colors.orange.shade600);
  }

  @override
  bool shouldRepaint(_) => true;
}

class _BirdMouthZoomPainter extends CustomPainter {
  final double pitchDegrees;
  _BirdMouthZoomPainter({required this.pitchDegrees});

  @override
  void paint(Canvas canvas, Size size) {
    final pitchRad = pitchDegrees * math.pi / 180;
    final cx = size.width * 0.4;
    final cy = size.height * 0.55;
    final len = size.height * 0.45;

    final rafterPaint = Paint()..color = Colors.brown.shade700..strokeWidth = 6..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
    final wallPaint = Paint()..color = Colors.grey.shade600..strokeWidth = 3..style = PaintingStyle.stroke;
    final birdPaint = Paint()..color = Colors.red.shade600..strokeWidth = 2.5..style = PaintingStyle.stroke;
    final dimPaint = Paint()..color = Colors.blue.shade400..strokeWidth = 1..style = PaintingStyle.stroke;

    canvas.drawLine(Offset(0, cy), Offset(size.width, cy), wallPaint);
    canvas.drawLine(
      Offset(cx - len * math.cos(pitchRad), cy - len * math.sin(pitchRad)),
      Offset(cx + len * math.cos(pitchRad), cy + len * math.sin(pitchRad)), rafterPaint);

    final depth = 35.0;
    final width = pitchRad > 0 ? depth / math.tan(pitchRad) : depth;
    final birdPath = Path();
    birdPath.moveTo(cx - width, cy - depth * 2.2);
    birdPath.lineTo(cx, cy);
    birdPath.lineTo(cx + depth * 0.7, cy - depth);
    canvas.drawPath(birdPath, birdPaint);

    canvas.drawLine(Offset(cx + 22, cy), Offset(cx + 22, cy - depth * 2.2), dimPaint);
    canvas.drawLine(Offset(cx - width, cy + 8), Offset(cx, cy + 8), dimPaint);

    void label(String t, Offset pos, Color c) {
      final tp = TextPainter(text: TextSpan(text: t, style: TextStyle(color: c, fontSize: 10, fontWeight: FontWeight.bold)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, pos);
    }
    label('50mm', Offset(cx + 24, cy - depth), Colors.blue.shade700);
    label('${width.toStringAsFixed(0)}mm', Offset(cx - width / 2 - 15, cy + 12), Colors.blue.shade700);
    label('${(90 - pitchDegrees).toStringAsFixed(0)}°', Offset(cx + 5, cy - 18), Colors.orange.shade700);
    label('${pitchDegrees.toStringAsFixed(0)}°', Offset(cx - width - 25, cy - depth * 1.5), Colors.orange.shade700);
    label('Wall plate', Offset(size.width * 0.65, cy - 14), Colors.grey.shade600);
  }

  @override
  bool shouldRepaint(_) => true;
}

class _TailZoomPainter extends CustomPainter {
  final double pitchDegrees;
  final double eavesOverhang;
  _TailZoomPainter({required this.pitchDegrees, required this.eavesOverhang});

  @override
  void paint(Canvas canvas, Size size) {
    final pitchRad = pitchDegrees * math.pi / 180;
    final cx = size.width * 0.45;
    final cy = size.height * 0.45;
    final len = size.height * 0.4;

    final rafterPaint = Paint()..color = Colors.brown.shade700..strokeWidth = 6..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
    final wallPaint = Paint()..color = Colors.grey.shade600..strokeWidth = 3..style = PaintingStyle.stroke;
    final dimPaint = Paint()..color = Colors.blue.shade400..strokeWidth = 1..style = PaintingStyle.stroke;
    final cutPaint = Paint()..color = Colors.red.shade600..strokeWidth = 2..style = PaintingStyle.stroke;

    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), wallPaint);
    canvas.drawLine(
      Offset(cx - len * math.cos(pitchRad), cy - len * math.sin(pitchRad)),
      Offset(cx + len * math.cos(pitchRad), cy + len * math.sin(pitchRad)), rafterPaint);

    final eavesPixels = math.min(eavesOverhang * 120, 70.0);
    canvas.drawLine(Offset(cx, cy + 28), Offset(cx + eavesPixels, cy + 28), dimPaint);
    canvas.drawLine(Offset(cx, cy + 22), Offset(cx, cy + 34), dimPaint);
    canvas.drawLine(Offset(cx + eavesPixels, cy + 22), Offset(cx + eavesPixels, cy + 34), dimPaint);
    canvas.drawLine(Offset(cx + eavesPixels, cy - 28), Offset(cx + eavesPixels, cy + 22), cutPaint);

    void label(String t, Offset pos, Color c) {
      final tp = TextPainter(text: TextSpan(text: t, style: TextStyle(color: c, fontSize: 10, fontWeight: FontWeight.bold)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, pos);
    }
    label('${(eavesOverhang * 1000).toStringAsFixed(0)}mm', Offset(cx + 4, cy + 32), Colors.blue.shade700);
    label('Tail cut ${pitchDegrees.toStringAsFixed(0)}°', Offset(cx + eavesPixels + 4, cy - 24), Colors.red.shade700);
    label('Wall plate', Offset(cx + 4, cy - 45), Colors.grey.shade600);
  }

  @override
  bool shouldRepaint(_) => true;
}


// ═══════════════════════════════════════════════════════════════
// Saved Rafter Calculations Screen
// ═══════════════════════════════════════════════════════════════

class SavedRafterScreen extends StatefulWidget {
  const SavedRafterScreen({super.key});
  @override
  State<SavedRafterScreen> createState() => _SavedRafterScreenState();
}

class _SavedRafterScreenState extends State<SavedRafterScreen> {
  List<Map<String, dynamic>> _calcs = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final all = await RafterSaveService.loadAll();
    if (mounted) setState(() { _calcs = all; _loading = false; });
  }

  Future<void> _backup() async {
    try {
      if (AuthService.isLoggedIn) {
        final uid = AuthService.currentUser!.uid;
        final all = await RafterSaveService.loadAll();
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          'rafterCalculations': all,
          'rafterBackupAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('✓ ${all.length} calculations backed up to cloud!'),
          backgroundColor: Colors.green.shade700));
      } else {
        final backup = await RafterSaveService.exportBackup();
        await Share.shareXFiles(
          [XFile.fromData(utf8.encode(backup), name: 'rafter_backup_${DateTime.now().millisecondsSinceEpoch}.json', mimeType: 'application/json')],
          subject: 'Rafter Calculations Backup',
          sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Backup failed: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _restore() async {
    if (AuthService.isLoggedIn) {
      final choice = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
        title: const Row(children: [Icon(Icons.restore, color: Colors.brown), SizedBox(width: 8), Text('Restore')]),
        content: const Text('Restore from cloud or paste JSON?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Cancel')),
          OutlinedButton.icon(onPressed: () => Navigator.pop(ctx, 'paste'), icon: const Icon(Icons.paste), label: const Text('Paste JSON')),
          ElevatedButton.icon(onPressed: () => Navigator.pop(ctx, 'cloud'),
            icon: const Icon(Icons.cloud_download), label: const Text('From Cloud'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.brown.shade600, foregroundColor: Colors.white)),
        ],
      ));
      if (choice == 'cloud') {
        try {
          final uid = AuthService.currentUser!.uid;
          final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
          final calcs = doc.data()?['rafterCalculations'] as List<dynamic>? ?? [];
          final prefs = await SharedPreferences.getInstance();
          await prefs.setStringList('saved_rafter_calculations', calcs.map((c) => json.encode(c)).toList());
          await _load();
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('✓ Restored ${calcs.length} calculations!'),
            backgroundColor: Colors.green.shade700));
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restore failed: $e'), backgroundColor: Colors.red));
        }
        return;
      }
      if (choice != 'paste') return;
    }
    // Paste JSON restore
    final pasteController = TextEditingController();
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Paste Backup JSON'),
      content: TextField(controller: pasteController, maxLines: 5,
        decoration: const InputDecoration(hintText: 'Paste backup JSON here...', border: OutlineInputBorder())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.brown.shade600, foregroundColor: Colors.white),
          child: const Text('Restore')),
      ],
    ));
    if (confirm != true || pasteController.text.trim().isEmpty) return;
    try {
      final count = await RafterSaveService.importBackup(pasteController.text.trim());
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('✓ Restored $count calculations!'),
        backgroundColor: Colors.green.shade700));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restore failed: $e'), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Saved Calculations (${_calcs.length})'),
        backgroundColor: Colors.brown.shade600,
        foregroundColor: Colors.white,
        actions: [
          IconButton(tooltip: 'Backup', icon: const Icon(Icons.backup), onPressed: _backup),
          IconButton(tooltip: 'Restore', icon: const Icon(Icons.restore), onPressed: _restore),
        ],
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _calcs.isEmpty
          ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.architecture, size: 64, color: Colors.grey),
              SizedBox(height: 12),
              Text('No saved calculations yet.\nTap Save after calculating.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
            ]))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _calcs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, index) {
                final c = _calcs[index];
                final name = c['name'] as String? ?? 'Unnamed';
                final savedAt = c['savedAt'] as String? ?? '';
                DateTime? dt; try { dt = DateTime.parse(savedAt); } catch (_) {}
                final dateStr = dt != null ? '${dt.day.toString().padLeft(2,'0')}/${dt.month.toString().padLeft(2,'0')}/${dt.year}' : '';
                final isHip = c['isHip'] as bool? ?? false;
                final rafterLen = (c['rafterLength'] as num?)?.toDouble();
                final hipLen = (c['hipLength'] as num?)?.toDouble();
                final pitch = c['pitch'] as String? ?? '';
                final span = c['span'] as String? ?? '';

                return ListTile(
                  leading: Container(width: 44, height: 44,
                    decoration: BoxDecoration(
                      color: isHip ? Colors.orange.shade100 : Colors.brown.shade100,
                      borderRadius: BorderRadius.circular(8)),
                    child: Icon(Icons.architecture,
                      color: isHip ? Colors.orange.shade700 : Colors.brown.shade700, size: 24)),
                  title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${isHip ? 'Hip' : 'Common'} • Span: ${span}m • Pitch: ${pitch}°',
                      style: const TextStyle(fontSize: 12)),
                    if (rafterLen != null)
                      Text('Rafter: ${rafterLen.toStringAsFixed(3)}m${hipLen != null ? ' | Hip: ${hipLen.toStringAsFixed(3)}m' : ''}',
                        style: TextStyle(fontSize: 11, color: Colors.brown.shade600)),
                    Text(dateStr, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  ]),
                  isThreeLine: true,
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                    onPressed: () async {
                      final confirm = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
                        title: const Text('Delete Calculation'),
                        content: Text('Delete "$name"?'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                          TextButton(onPressed: () => Navigator.pop(d, true),
                            child: const Text('Delete', style: TextStyle(color: Colors.red))),
                        ],
                      ));
                      if (confirm == true) {
                        await RafterSaveService.delete(index);
                        setState(() { _calcs.removeAt(index); });
                      }
                    },
                  ),
                );
              },
            ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Perimeter Area Tool
// ═══════════════════════════════════════════════════════════════

class _Wall {
  final TextEditingController lengthController;
  _Wall() : lengthController = TextEditingController();
  void dispose() { lengthController.dispose(); }
}

class PerimeterAreaTool extends StatefulWidget {
  const PerimeterAreaTool({super.key});
  @override
  State<PerimeterAreaTool> createState() => _PerimeterAreaToolState();
}

class _PerimeterAreaToolState extends State<PerimeterAreaTool> {
  final List<Offset> _points = [];
  final List<_Wall> _walls = [];
  final _pitchController = TextEditingController();
  final _wastageController = TextEditingController(text: '10');
  bool _isClosed = false;
  bool _showResults = false;

  @override
  void dispose() {
    for (final w in _walls) { w.dispose(); }
    _pitchController.dispose();
    _wastageController.dispose();
    super.dispose();
  }

  void _addPoint(Offset point) {
    if (_isClosed) return;
    setState(() {
      _points.add(point);
      if (_points.length > 1) _walls.add(_Wall());
      _showResults = false;
    });
  }

  void _closeShape() {
    if (_points.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add at least 3 corners first')));
      return;
    }
    setState(() { _isClosed = true; _showResults = false; });
  }

  void _undoLastPoint() {
    if (_isClosed || _points.isEmpty) return;
    setState(() {
      _points.removeLast();
      if (_walls.isNotEmpty) {
        _walls.removeLast().dispose();
      }
      _showResults = false;
    });
  }

  void _reset() {
    for (final w in _walls) { w.dispose(); }
    setState(() { _points.clear(); _walls.clear(); _isClosed = false; _showResults = false; });
  }

  double? get _enteredPerimeter {
    if (_walls.isEmpty) return null;
    double total = 0;
    for (final w in _walls) {
      final v = double.tryParse(w.lengthController.text);
      if (v == null || v <= 0) return null;
      total += v;
    }
    return total;
  }

  double? _calculateFlatArea() {
    if (_points.length < 3 || _walls.isEmpty) return null;
    final List<double> realLengths = [];
    for (final w in _walls) {
      final v = double.tryParse(w.lengthController.text);
      if (v == null || v <= 0) return null;
      realLengths.add(v);
    }

    double screenArea = 0;
    double screenPerimeter = 0;
    for (int i = 0; i < _points.length; i++) {
      final j = (i + 1) % _points.length;
      screenArea += _points[i].dx * _points[j].dy;
      screenArea -= _points[j].dx * _points[i].dy;
      final dx = _points[j].dx - _points[i].dx;
      final dy = _points[j].dy - _points[i].dy;
      screenPerimeter += math.sqrt(dx * dx + dy * dy);
    }
    screenArea = screenArea.abs() / 2;

    final closingDx = _points[0].dx - _points[_points.length - 1].dx;
    final closingDy = _points[0].dy - _points[_points.length - 1].dy;
    final closingScreenLen = math.sqrt(closingDx * closingDx + closingDy * closingDy);
    final enteredScreenLen = screenPerimeter - closingScreenLen;
    final realEntered = realLengths.reduce((a, b) => a + b);
    final scale = enteredScreenLen > 0 ? realEntered / enteredScreenLen : 1.0;
    return screenArea * scale * scale;
  }

  void _calculate() {
    final area = _calculateFlatArea();
    if (area == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter all wall lengths to calculate')));
      return;
    }
    setState(() { _showResults = true; });
  }

  double? get _pitchedArea {
    final flat = _calculateFlatArea();
    if (flat == null) return null;
    final pitch = double.tryParse(_pitchController.text);
    if (pitch == null || pitch <= 0) return flat;
    return flat / math.cos(pitch * math.pi / 180);
  }

  double? get _totalWithWastage {
    final pitched = _pitchedArea;
    if (pitched == null) return null;
    final wastage = double.tryParse(_wastageController.text) ?? 10;
    return pitched * (1 + wastage / 100);
  }

  @override
  Widget build(BuildContext context) {
    final flat = _showResults ? _calculateFlatArea() : null;
    final pitched = _showResults ? (_pitchedArea ?? flat) : null;
    final total = _showResults ? (_totalWithWastage ?? flat) : null;
    final perimeter = _showResults ? _enteredPerimeter : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Perimeter Area Tool'),
        backgroundColor: Colors.indigo.shade700,
        foregroundColor: Colors.white,
        actions: [
          if (!_isClosed && _points.isNotEmpty)
            IconButton(tooltip: 'Undo point', icon: const Icon(Icons.undo), onPressed: _undoLastPoint),
          if (_points.isNotEmpty)
            IconButton(tooltip: 'Reset', icon: const Icon(Icons.refresh), onPressed: _reset),
        ],
      ),
      body: Column(children: [
        Container(
          color: Colors.indigo.shade50,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            Icon(Icons.info_outline, color: Colors.indigo.shade700, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(
              _isClosed
                ? 'Shape complete. Enter each wall length, pitch and wastage, then calculate.'
                : _points.isEmpty
                  ? 'Tap the drawing area to add each corner of the roof shape.'
                  : '${_points.length} corners added. ${_points.length < 3 ? 'Add at least 3 corners.' : 'Tap Close Shape when finished.'}',
              style: const TextStyle(fontSize: 12, height: 1.25),
            )),
            if (!_isClosed && _points.length >= 3)
              TextButton(
                onPressed: _closeShape,
                child: Text('Close Shape', style: TextStyle(color: Colors.indigo.shade700, fontWeight: FontWeight.bold)),
              ),
          ]),
        ),

        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: _isClosed
                ? InteractiveViewer(
                    boundaryMargin: const EdgeInsets.all(120),
                    minScale: 0.65,
                    maxScale: 3.0,
                    panEnabled: true,
                    scaleEnabled: true,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.vertical,
                        child: SizedBox(
                          width: 650,
                          height: 650,
                          child: _perimeterCanvasContent(),
                        ),
                      ),
                    ),
                  )
                : GestureDetector(
                    onTapUp: (details) => _addPoint(details.localPosition),
                    child: _perimeterCanvasContent(),
                  ),
            ),
          ),
        ),

        if (_isClosed)
          Expanded(
            flex: 3,
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 56 + MediaQuery.of(context).viewPadding.bottom),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.straighten, color: Colors.indigo.shade700),
                  const SizedBox(width: 8),
                  const Text('Wall Lengths', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 6),
                Text('Enter the real measured length for each wall section shown above.', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 12),

                ..._walls.asMap().entries.map((entry) {
                  final i = entry.key;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(children: [
                      _wallNumber(i + 1),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.arrow_forward, size: 16, color: Colors.grey.shade400),
                      ),
                      _wallNumber(i + 2 > _points.length ? 1 : i + 2),
                      const SizedBox(width: 12),
                      Expanded(child: TextField(
                        controller: entry.value.lengthController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (_) { if (_showResults) setState(() { _showResults = false; }); },
                        decoration: InputDecoration(
                          labelText: 'Wall ${i + 1}',
                          hintText: 'Length',
                          suffixText: 'm',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                        ),
                      )),
                    ]),
                  );
                }),

                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: TextField(
                    controller: _pitchController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) { if (_showResults) setState(() { _showResults = false; }); },
                    decoration: InputDecoration(
                      labelText: 'Roof Pitch',
                      suffixText: '°',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      helperText: 'Optional',
                      isDense: true,
                    ),
                  )),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(
                    controller: _wastageController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) { if (_showResults) setState(() { _showResults = false; }); },
                    decoration: InputDecoration(
                      labelText: 'Wastage',
                      suffixText: '%',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      helperText: 'Allowance',
                      isDense: true,
                    ),
                  )),
                ]),
                const SizedBox(height: 14),
                SizedBox(width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _calculate,
                    icon: const Icon(Icons.calculate),
                    label: const Text('Calculate Area & Perimeter'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.indigo.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),

                if (_showResults && flat != null) ...[
                  const SizedBox(height: 20),
                  Row(children: [
                    Icon(Icons.analytics_outlined, color: Colors.indigo.shade700),
                    const SizedBox(width: 8),
                    const Text('Calculation Results', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ]),
                  const SizedBox(height: 12),
                  GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 1.35,
                    children: [
                      _resultCard('Flat Area', '${flat.toStringAsFixed(2)} m²', Icons.crop_square, Colors.grey.shade700),
                      _resultCard('Pitched Area', '${(pitched ?? flat).toStringAsFixed(2)} m²', Icons.roofing, Colors.indigo.shade700),
                      _resultCard('Total + Waste', '${(total ?? flat).toStringAsFixed(2)} m²', Icons.add_chart, Colors.blue.shade700),
                      _resultCard('Perimeter', '${(perimeter ?? 0).toStringAsFixed(2)} m', Icons.timeline, Colors.green.shade700),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Area ready to use with your material list workflow')),
                        );
                      },
                      icon: const Icon(Icons.list_alt),
                      label: const Text('Use Area For Material List'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Share.share(
                          '📐 Perimeter Area Calculation\n\n'
                          'Walls measured: ${_walls.length}\n'
                          'Perimeter: ${(perimeter ?? 0).toStringAsFixed(2)} m\n'
                          'Flat Area: ${flat.toStringAsFixed(2)} m²\n'
                          'Pitched Area: ${(pitched ?? flat).toStringAsFixed(2)} m²\n'
                          'Total + ${_wastageController.text}% wastage: ${(total ?? flat).toStringAsFixed(2)} m²\n\n'
                          'Calculated by Roof Profile Finder',
                          sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
                        );
                      },
                      icon: const Icon(Icons.share),
                      label: const Text('Share Results'),
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    ),
                  ),
                ],
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _perimeterCanvasContent() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.indigo.shade100),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: CustomPaint(
        painter: _PerimeterPainter(points: _points, isClosed: _isClosed),
        child: _points.isEmpty
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.touch_app, size: 46, color: Colors.indigo.shade200),
              const SizedBox(height: 8),
              Text('Tap to draw roof outline', style: TextStyle(color: Colors.indigo.shade400, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('Add corners around the building shape', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
            ]))
          : Stack(children: [
              ..._points.asMap().entries.map((e) => Positioned(
                left: e.value.dx + 8,
                top: e.value.dy - 22,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Colors.indigo.shade700,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 4)],
                  ),
                  child: Center(child: Text('${e.key + 1}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold))),
                ),
              )),
              if (_isClosed)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.92),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.indigo.shade100),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.open_with, size: 15, color: Colors.indigo.shade700),
                      const SizedBox(width: 5),
                      Text('Pan / pinch to view large shapes', style: TextStyle(fontSize: 11, color: Colors.indigo.shade700, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
            ]),
      ),
    );
  }

  Widget _wallNumber(int number) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: Colors.indigo.shade700,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Center(child: Text('$number', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold))),
    );
  }

  Widget _resultCard(String title, String value, IconData icon, Color color) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 8),
            Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 5),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
            ),
          ],
        ),
      ),
    );
  }
}

class _PerimeterPainter extends CustomPainter {
  final List<Offset> points;
  final bool isClosed;
  _PerimeterPainter({required this.points, required this.isClosed});

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.indigo.withOpacity(0.05)
      ..strokeWidth = 1;
    const double grid = 28;
    for (double x = 0; x <= size.width; x += grid) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y <= size.height; y += grid) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (points.isEmpty) return;

    final linePaint = Paint()
      ..color = Colors.indigo.shade700
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fillPaint = Paint()
      ..color = Colors.indigo.withOpacity(0.08)
      ..style = PaintingStyle.fill;
    final dotPaint = Paint()
      ..color = Colors.indigo.shade700
      ..style = PaintingStyle.fill;

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    if (isClosed && points.length > 2) {
      path.close();
      canvas.drawPath(path, fillPaint);
    }
    canvas.drawPath(path, linePaint);

    for (final p in points) {
      canvas.drawCircle(p, 10, Paint()..color = Colors.white..style = PaintingStyle.fill);
      canvas.drawCircle(p, 8, dotPaint);
      canvas.drawCircle(p, 10, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(covariant _PerimeterPainter old) => old.points != points || old.isClosed != isClosed;
}


// ═══════════════════════════════════════════════════════════════
// Account Screen
// ═══════════════════════════════════════════════════════════════

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  late bool _isLoggedIn;
  StreamSubscription<dynamic>? _accountAuthSub;

  @override
  void initState() {
    super.initState();
    _isLoggedIn = AuthService.isLoggedIn;
    _tabController = TabController(length: 3, vsync: this);
    _accountAuthSub = AuthService.authStateChanges.listen((user) {
      if (mounted) setState(() => _isLoggedIn = user != null);
    });
  }

  @override
  void dispose() {
    _accountAuthSub?.cancel();
    _tabController.dispose();
    _emailController.dispose(); _passwordController.dispose();
    _nameController.dispose(); _confirmController.dispose();
    super.dispose();
  }

  Future<void> _loginEmail() async {
    setState(() { _busy = true; _error = null; });
    try {
      await AuthService.loginWithEmail(_emailController.text.trim(), _passwordController.text);
      if (mounted) {
        setState(() { _busy = false; });
        Navigator.pop(context, true);
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() { _error = _friendlyError(e.code); _busy = false; });
    }
  }

  Future<void> _registerEmail() async {
    if (_passwordController.text != _confirmController.text) {
      setState(() { _error = 'Passwords do not match'; }); return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await AuthService.registerWithEmail(_emailController.text.trim(), _passwordController.text, _nameController.text.trim());
      if (mounted) {
        setState(() { _busy = false; });
        Navigator.pop(context, true);
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() { _error = _friendlyError(e.code); _busy = false; });
    }
  }

  Future<void> _googleSignIn() async {
    setState(() { _busy = true; _error = null; });
    try {
      final result = await AuthService.signInWithGoogle();
      if (result != null && mounted) {
        setState(() { _busy = false; });
        Navigator.pop(context, true);
      } else {
        if (mounted) setState(() { _busy = false; });
      }
    } catch (e) {
      if (mounted) setState(() { _error = 'Google sign in failed. Please try again.'; _busy = false; });
    }
  }

  Future<void> _appleSignIn() async {
    setState(() { _busy = true; _error = null; });
    try {
      final result = await AuthService.signInWithApple();
      if (result != null && mounted) {
        setState(() { _busy = false; });
        Navigator.pop(context, true);
      } else {
        if (mounted) setState(() { _busy = false; });
      }
    } catch (e) {
      if (mounted) setState(() { _error = 'Apple sign in failed. Please try again.'; _busy = false; });
    }
  }

  Future<void> _signOut() async {
    await AuthService.signOut();
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _syncNow() async {
    setState(() { _busy = true; });
    try {
      final history = await HistoryService.loadHistory();
      await AuthService.syncHistoryToCloud(history);
      if (mounted) _showSnack('✓ History synced to cloud!', Colors.green);
    } catch (e) {
      if (mounted) _showSnack('Sync failed: $e', Colors.red);
    } finally { if (mounted) setState(() { _busy = false; }); }
  }

  Future<void> _restoreFromCloud() async {
    setState(() { _busy = true; });
    try {
      final cloudHistory = await AuthService.loadHistoryFromCloud();
      if (cloudHistory.isEmpty) { _showSnack('No cloud history found', Colors.orange); return; }
      for (final entry in cloudHistory.reversed) { await HistoryService.saveEntry(entry); }
      if (mounted) _showSnack('✓ Restored ${cloudHistory.length} entries!', Colors.green);
    } catch (e) {
      if (mounted) _showSnack('Restore failed: $e', Colors.red);
    } finally { if (mounted) setState(() { _busy = false; }); }
  }

  void _showSnack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  String _friendlyError(String code) {
    switch (code) {
      case 'user-not-found': return 'No account found with this email';
      case 'wrong-password': return 'Incorrect password';
      case 'email-already-in-use': return 'Email already registered';
      case 'weak-password': return 'Password must be at least 6 characters';
      case 'invalid-email': return 'Invalid email address';
      default: return 'Something went wrong. Please try again';
    }
  }

  Widget _textField(String label, TextEditingController controller, {bool obscure = false, TextInputType? keyboard}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        obscureText: obscure && _obscure,
        keyboardType: keyboard,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: obscure ? IconButton(
            icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() { _obscure = !_obscure; }),
          ) : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isLoggedIn ? 'My Account' : 'Sign In / Register'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        bottom: _isLoggedIn ? null : TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [Tab(text: 'Sign In'), Tab(text: 'Register')],
        ),
      ),
      body: _isLoggedIn ? _buildLoggedIn() : _buildAuth(),
    );
  }

  Widget _buildLoggedIn() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(children: [
        const SizedBox(height: 20),
        CircleAvatar(
          radius: 40,
          backgroundColor: Colors.blue.shade100,
          child: Icon(Icons.account_circle, size: 60, color: Colors.blue.shade700),
        ),
        const SizedBox(height: 16),
        Text(AuthService.displayName ?? 'User', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(AuthService.userEmail ?? '', style: TextStyle(color: Colors.grey.shade600)),
        const SizedBox(height: 32),
        Card(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
            const Text('Cloud Sync', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Keep your history backed up and accessible across devices.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: ElevatedButton.icon(
              onPressed: _busy ? null : _syncNow,
              icon: const Icon(Icons.cloud_upload),
              label: const Text('Sync History to Cloud'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
            )),
            const SizedBox(height: 8),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(
              onPressed: _busy ? null : _restoreFromCloud,
              icon: const Icon(Icons.cloud_download),
              label: const Text('Restore from Cloud'),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
            )),
          ])),
        ),
        const SizedBox(height: 16),
        if (_busy) const CircularProgressIndicator(),
        const SizedBox(height: 24),
        SizedBox(width: double.infinity, child: OutlinedButton.icon(
          onPressed: _signOut,
          icon: const Icon(Icons.logout, color: Colors.red),
          label: const Text('Sign Out', style: TextStyle(color: Colors.red)),
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
        )),
      ]),
    );
  }

  Widget _buildAuth() {
    return TabBarView(
      controller: _tabController,
      children: [
        // Sign In tab
        SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            const SizedBox(height: 16),
            if (_error != null) ...[
              Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red.shade200)),
                child: Row(children: [const Icon(Icons.error_outline, color: Colors.red, size: 18), const SizedBox(width: 8), Expanded(child: Text(_error!, style: const TextStyle(color: Colors.red)))])),
              const SizedBox(height: 12),
            ],
            _textField('Email', _emailController, keyboard: TextInputType.emailAddress),
            _textField('Password', _passwordController, obscure: true),
            const SizedBox(height: 4),
            SizedBox(width: double.infinity, child: ElevatedButton(
              onPressed: _busy ? null : _loginEmail,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
              child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Sign In'),
            )),
            const SizedBox(height: 16),
            const Row(children: [Expanded(child: Divider()), Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('or')), Expanded(child: Divider())]),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(
              onPressed: _busy ? null : _googleSignIn,
              icon: const Icon(Icons.g_mobiledata, size: 24),
              label: const Text('Continue with Google'),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
            )),
            const SizedBox(height: 10),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(
              onPressed: _busy ? null : _appleSignIn,
              icon: const Icon(Icons.apple, size: 24),
              label: const Text('Continue with Apple'),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
            )),
            const SizedBox(height: 20),
            Text('Sign in to sync your history across devices.\nCompletely optional — the app works without an account.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ]),
        ),
        // Register tab
        SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            const SizedBox(height: 16),
            if (_error != null) ...[
              Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red.shade200)),
                child: Row(children: [const Icon(Icons.error_outline, color: Colors.red, size: 18), const SizedBox(width: 8), Expanded(child: Text(_error!, style: const TextStyle(color: Colors.red)))])),
              const SizedBox(height: 12),
            ],
            _textField('Full Name', _nameController),
            _textField('Email', _emailController, keyboard: TextInputType.emailAddress),
            _textField('Password', _passwordController, obscure: true),
            _textField('Confirm Password', _confirmController, obscure: true),
            const SizedBox(height: 4),
            SizedBox(width: double.infinity, child: ElevatedButton(
              onPressed: _busy ? null : _registerEmail,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
              child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Create Account'),
            )),
            const SizedBox(height: 16),
            const Row(children: [Expanded(child: Divider()), Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('or')), Expanded(child: Divider())]),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(
              onPressed: _busy ? null : _googleSignIn,
              icon: const Icon(Icons.g_mobiledata, size: 24),
              label: const Text('Continue with Google'),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
            )),
            const SizedBox(height: 10),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(
              onPressed: _busy ? null : _appleSignIn,
              icon: const Icon(Icons.apple, size: 24),
              label: const Text('Continue with Apple'),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
            )),
            const SizedBox(height: 20),
            Text('Create a free account to sync your history across devices.\nCompletely optional — the app works without an account.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ]),
        ),
      ],
    );
  }
}


// ═══════════════════════════════════════════════════════════════
// ═══════════════════════════════════════════════════════════════
// Admin Screen
// ═══════════════════════════════════════════════════════════════

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin — Upload Profile'),
        backgroundColor: Colors.red.shade700,
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(icon: Icon(Icons.factory_outlined), text: 'Sheet Profile'),
            Tab(icon: Icon(Icons.home_outlined), text: 'Tile Profile'),
            Tab(icon: Icon(Icons.pending_actions_outlined), text: 'Corrections'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _AdminSheetForm(),
          _AdminTileForm(),
          _AdminCorrectionsTab(),
        ],
      ),
    );
  }
}

class _AdminSheetForm extends StatefulWidget {
  const _AdminSheetForm();
  @override
  State<_AdminSheetForm> createState() => _AdminSheetFormState();
}

class _AdminSheetFormState extends State<_AdminSheetForm> {
  final _nameController = TextEditingController();
  final _codeController = TextEditingController();
  final _manufacturerController = TextEditingController();
  final _pitchController = TextEditingController();
  final _depthController = TextEditingController();
  final _crownController = TextEditingController();
  final _troughController = TextEditingController();
  final _coverWidthController = TextEditingController();
  final _overallWidthController = TextEditingController();
  String _category = 'steel';
  XFile? _imageFile;
  bool _uploading = false;

  @override
  void dispose() {
    for (final c in [_nameController, _codeController, _manufacturerController,
      _pitchController, _depthController, _crownController, _troughController,
      _coverWidthController, _overallWidthController]) { c.dispose(); }
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (file != null) setState(() { _imageFile = file; });
  }

  Future<void> _upload() async {
    if (_nameController.text.isEmpty || _manufacturerController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name and manufacturer required'), backgroundColor: Colors.red));
      return;
    }
    setState(() { _uploading = true; });
    try {
      String? imageUrl;
      if (_imageFile != null) {
        final ref = FirebaseStorage.instance.ref()
          .child('profiles')
          .child('${DateTime.now().millisecondsSinceEpoch}_${_imageFile!.name}');
        await ref.putFile(File(_imageFile!.path));
        imageUrl = await ref.getDownloadURL();
      }

      final data = {
        'name': _nameController.text.trim(),
        'code': _codeController.text.trim(),
        'manufacturer': _manufacturerController.text.trim(),
        'category': _category,
        'pitch': double.tryParse(_pitchController.text) ?? 0,
        'depth': double.tryParse(_depthController.text) ?? 0,
        'crown': double.tryParse(_crownController.text) ?? 0,
        'trough': double.tryParse(_troughController.text) ?? 0,
        'coverWidth': double.tryParse(_coverWidthController.text) ?? 0,
        'overallWidth': double.tryParse(_overallWidthController.text) ?? 0,
        'imageUrl': imageUrl ?? '',
        'addedAt': FieldValue.serverTimestamp(),
        'type': 'sheet',
      };

      await FirebaseFirestore.instance.collection('new_profiles').add(data);

      // Send push notification
      await FirebaseFirestore.instance.collection('notifications').add({
        'title': 'New Profile Added! 🎉',
        'body': '${_nameController.text.trim()} by ${_manufacturerController.text.trim()} has been added.',
        'sentAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('✓ ${_nameController.text} uploaded successfully!'),
          backgroundColor: Colors.green.shade700));
        // Clear form
        for (final c in [_nameController, _codeController, _manufacturerController,
          _pitchController, _depthController, _crownController, _troughController,
          _coverWidthController, _overallWidthController]) { c.clear(); }
        setState(() { _imageFile = null; });
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Upload failed: $e'), backgroundColor: Colors.red));
    }
    if (mounted) setState(() { _uploading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Category
        Row(children: [
          const Text('Category:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 12),
          ChoiceChip(label: const Text('Steel'), selected: _category == 'steel',
            onSelected: (_) => setState(() { _category = 'steel'; }),
            selectedColor: Colors.blue.shade200),
          const SizedBox(width: 8),
          ChoiceChip(label: const Text('Cement'), selected: _category == 'cement',
            onSelected: (_) => setState(() { _category = 'cement'; }),
            selectedColor: Colors.grey.shade300),
        ]),
        const SizedBox(height: 12),
        _field('Profile Name *', _nameController),
        _field('Code', _codeController),
        _field('Manufacturer *', _manufacturerController),
        _field('Pitch (mm)', _pitchController, isNumber: true),
        _field('Depth (mm)', _depthController, isNumber: true),
        _field('Crown (mm)', _crownController, isNumber: true),
        _field('Trough (mm)', _troughController, isNumber: true),
        _field('Cover Width (mm)', _coverWidthController, isNumber: true),
        _field('Overall Width (mm)', _overallWidthController, isNumber: true),
        const SizedBox(height: 12),
        // Image picker
        GestureDetector(
          onTap: _pickImage,
          child: Container(
            height: 120,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade400, width: 2),
              borderRadius: BorderRadius.circular(8),
              color: Colors.grey.shade100,
            ),
            child: _imageFile == null
              ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.add_photo_alternate, size: 40, color: Colors.grey),
                  Text('Tap to add image', style: TextStyle(color: Colors.grey)),
                ]))
              : ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(File(_imageFile!.path), fit: BoxFit.contain)),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _uploading ? null : _upload,
            icon: _uploading
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.cloud_upload),
            label: Text(_uploading ? 'Uploading...' : 'Upload Profile'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade700, foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14)),
          )),
      ]),
    );
  }

  Widget _field(String label, TextEditingController c, {bool isNumber = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: c,
        keyboardType: isNumber ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
        textCapitalization: isNumber ? TextCapitalization.none : TextCapitalization.words,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      ),
    );
  }
}

class _AdminTileForm extends StatefulWidget {
  const _AdminTileForm();
  @override
  State<_AdminTileForm> createState() => _AdminTileFormState();
}

class _AdminTileFormState extends State<_AdminTileForm> {
  final _nameController = TextEditingController();
  final _manufacturerController = TextEditingController();
  final _lengthController = TextEditingController();
  final _widthController = TextEditingController();
  final _minPitchController = TextEditingController();
  final _coverWidthController = TextEditingController();
  String _material = 'Concrete';
  String _type = 'Plain';
  XFile? _imageFile;
  bool _uploading = false;

  @override
  void dispose() {
    for (final c in [_nameController, _manufacturerController, _lengthController,
      _widthController, _minPitchController, _coverWidthController]) { c.dispose(); }
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (file != null) setState(() { _imageFile = file; });
  }

  Future<void> _upload() async {
    if (_nameController.text.isEmpty || _manufacturerController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name and manufacturer required'), backgroundColor: Colors.red));
      return;
    }
    setState(() { _uploading = true; });
    try {
      String? imageUrl;
      if (_imageFile != null) {
        final ref = FirebaseStorage.instance.ref()
          .child('profiles')
          .child('${DateTime.now().millisecondsSinceEpoch}_${_imageFile!.name}');
        await ref.putFile(File(_imageFile!.path));
        imageUrl = await ref.getDownloadURL();
      }

      final data = {
        'name': _nameController.text.trim(),
        'manufacturer': _manufacturerController.text.trim(),
        'material': _material,
        'tileType': _type,
        'nominalLength': double.tryParse(_lengthController.text) ?? 0,
        'nominalWidth': double.tryParse(_widthController.text) ?? 0,
        'minPitch': double.tryParse(_minPitchController.text) ?? 0,
        'coverWidth': double.tryParse(_coverWidthController.text) ?? 0,
        'imageUrl': imageUrl ?? '',
        'addedAt': FieldValue.serverTimestamp(),
        'type': 'tile',
      };

      await FirebaseFirestore.instance.collection('new_profiles').add(data);

      await FirebaseFirestore.instance.collection('notifications').add({
        'title': 'New Tile Added! 🏠',
        'body': '${_nameController.text.trim()} by ${_manufacturerController.text.trim()} has been added.',
        'sentAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('✓ ${_nameController.text} uploaded successfully!'),
          backgroundColor: Colors.green.shade700));
        for (final c in [_nameController, _manufacturerController, _lengthController,
          _widthController, _minPitchController, _coverWidthController]) { c.clear(); }
        setState(() { _imageFile = null; });
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Upload failed: $e'), backgroundColor: Colors.red));
    }
    if (mounted) setState(() { _uploading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Material:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          for (final m in ['Concrete', 'Clay', 'Slate', 'Other'])
            Padding(padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(label: Text(m), selected: _material == m,
                onSelected: (_) => setState(() { _material = m; }),
                selectedColor: Colors.orange.shade200)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          const Text('Type:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          for (final t in ['Plain', 'Interlocking', 'Roman', 'Pantile', 'Other'])
            Padding(padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(label: Text(t), selected: _type == t,
                onSelected: (_) => setState(() { _type = t; }),
                selectedColor: Colors.orange.shade200)),
        ]),
        const SizedBox(height: 12),
        _field('Tile Name *', _nameController),
        _field('Manufacturer *', _manufacturerController),
        _field('Nominal Length (mm)', _lengthController, isNumber: true),
        _field('Nominal Width (mm)', _widthController, isNumber: true),
        _field('Min Pitch (°)', _minPitchController, isNumber: true),
        _field('Cover Width (mm)', _coverWidthController, isNumber: true),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: _pickImage,
          child: Container(
            height: 120,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade400, width: 2),
              borderRadius: BorderRadius.circular(8),
              color: Colors.grey.shade100,
            ),
            child: _imageFile == null
              ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.add_photo_alternate, size: 40, color: Colors.grey),
                  Text('Tap to add image', style: TextStyle(color: Colors.grey)),
                ]))
              : ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(File(_imageFile!.path), fit: BoxFit.contain)),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _uploading ? null : _upload,
            icon: _uploading
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.cloud_upload),
            label: Text(_uploading ? 'Uploading...' : 'Upload Tile'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange.shade700, foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14)),
          )),
      ]),
    );
  }

  Widget _field(String label, TextEditingController c, {bool isNumber = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: c,
        keyboardType: isNumber ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
        textCapitalization: isNumber ? TextCapitalization.none : TextCapitalization.words,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Welcome Screen — shown on first boot
// ═══════════════════════════════════════════════════════════════

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _dontShowAgain = true;

  Future<void> _dismiss({bool goToLogin = false}) async {
    if (_dontShowAgain) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('seen_welcome', true);
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) => const ProfileSearchScreen(homeHubMode: true)));
    if (goToLogin) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AccountScreen()));
      });
    }
  }

  Widget _benefit(IconData icon, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Container(width: 36, height: 36,
          decoration: BoxDecoration(color: Colors.blue.shade700, borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, color: Colors.white, size: 18)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ])),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.of(context).size.height
                - MediaQuery.of(context).padding.top
                - MediaQuery.of(context).padding.bottom),
            child: IntrinsicHeight(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(children: [
                  const SizedBox(height: 8),
                  Container(width: 90, height: 90,
                    decoration: BoxDecoration(color: Colors.blue.shade700, borderRadius: BorderRadius.circular(22)),
                    child: const Icon(Icons.roofing, size: 50, color: Colors.white)),
                  const SizedBox(height: 20),
                  const Text('Welcome to\nRoof Profile Finder!',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, height: 1.3)),
                  const SizedBox(height: 10),
                  Text('The UK\'s most comprehensive roofing profile identification app.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.blue.shade200)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Create a free account to unlock:',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.blue.shade800)),
                      const SizedBox(height: 10),
                      _benefit(Icons.cloud_upload, 'Cloud backup', 'Never lose your saved profiles'),
                      _benefit(Icons.sync, 'Sync across devices', 'Access from any phone'),
                      _benefit(Icons.restore, 'Auto restore', 'Restore if you change phone'),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  Text('The app works completely without an account.\nSign in anytime from the account icon.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  const Spacer(),
                  SizedBox(width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => _dismiss(goToLogin: true),
                      icon: const Icon(Icons.account_circle),
                      label: const Text('Sign In / Create Account'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade700, foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    )),
                  const SizedBox(height: 10),
                  SizedBox(width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => _dismiss(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      child: const Text('Maybe Later'),
                    )),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () => setState(() { _dontShowAgain = !_dontShowAgain; }),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Checkbox(value: _dontShowAgain,
                        onChanged: (v) => setState(() { _dontShowAgain = v ?? true; }),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      const Text("Don't show this again", style: TextStyle(fontSize: 13)),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Favourites Screen
// ═══════════════════════════════════════════════════════════════

class FavouritesScreen extends StatefulWidget {
  const FavouritesScreen({super.key});
  @override
  State<FavouritesScreen> createState() => _FavouritesScreenState();
}

class _FavouritesScreenState extends State<FavouritesScreen> {
  List<ProfileRecord> _favourites = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final favs = await FavouritesService.loadAll();
    if (mounted) setState(() { _favourites = favs; _loading = false; });
  }

  Future<void> _remove(ProfileRecord p) async {
    await FavouritesService.remove(p);
    setState(() { _favourites.removeWhere((f) => f.profileName == p.profileName && f.manufacturer == p.manufacturer); });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Favourites (${_favourites.length})'),
        backgroundColor: Colors.amber.shade700,
        foregroundColor: Colors.white,
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _favourites.isEmpty
          ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.star_border, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text('No favourites yet.\nTap ⭐ on any profile to add it here.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey)),
            ]))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _favourites.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, index) {
                final p = _favourites[index];
                return ListTile(
                  leading: p.imageFile != null
                    ? ClipRRect(borderRadius: BorderRadius.circular(6),
                        child: Image.asset(p.imageFile!, width: 48, height: 48, fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => Icon(Icons.roofing, size: 40, color: Colors.amber.shade700)))
                    : Icon(Icons.roofing, size: 40, color: Colors.amber.shade700),
                  title: Text(p.displayTitle, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${p.manufacturer} • ${p.isTileCategory ? p.tileTypeLabel : p.category}',
                    style: const TextStyle(fontSize: 12)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      icon: Icon(Icons.star, color: Colors.amber.shade700),
                      onPressed: () async {
                        await _remove(p);
                        if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('Removed from favourites'), duration: Duration(seconds: 1)));
                      },
                    ),
                    const Icon(Icons.arrow_forward_ios, size: 16),
                  ]),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => ResultsScreen(title: p.displayTitle,
                      results: [SearchResult(profile: p, score: 0)]))),
                );
              },
            ),
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
      appBar: AppBar(title: const Text('How to Measure'), backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Center(child: InteractiveViewer(panEnabled: true, minScale: 0.8, maxScale: 4,
        child: Image.asset('assets/images/how_to_use.png', fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => const Padding(padding: EdgeInsets.all(24),
            child: Text('Help image not found.\n\nMake sure the file is in:\nassets/images/how_to_use.png', textAlign: TextAlign.center, style: TextStyle(color: Colors.white)))))),
    );
  }
}
