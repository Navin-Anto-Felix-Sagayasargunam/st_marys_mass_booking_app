import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart'; // FIX #1/#2: replaces Firebase
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'dart:convert';
import 'dart:io';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (context) => AppState(),
      child: const StMarysApp(),
    ),
  );
}

// ─── CONVEX API CONFIGURATION ────────────────────────────────
class ConvexConfig {
  static const String baseUrl = "https://next-mouse-406.eu-west-1.convex.site/mobile/v1";
  static const Map<String, String> headers = {
    "X-Mobile-Auth": "UIYhkjasd09812ajsdasd143",
    "Content-Type": "application/json",
  };
  static const String googleOAuthWebClientId = "299520186917-hsrup359ckb81ud1g565o2kh83oa3boa.apps.googleusercontent.com";
}

// ─── MODELS ──────────────────────────────────────────────────
class FamilyMember {
  final String id;
  final String fullName;
  final String relation;
  final String mobile;
  final String dob;
  final String idNumber;
  final bool active;
  final String parishNumber;

  FamilyMember({
    required this.id,
    required this.fullName,
    required this.relation,
    required this.mobile,
    required this.dob,
    required this.idNumber,
    this.active = true,
    this.parishNumber = '',
  });

  factory FamilyMember.fromJson(Map<String, dynamic> json) => FamilyMember(
        id: json['_id'],
        fullName: json['fullName'],
        relation: json['relation'],
        mobile: json['mobile'] ?? '',
        dob: json['dob'],
        idNumber: json['idNumber'],
        active: json['active'] ?? true,
        parishNumber: json['parishNumber'] ?? '',
      );
}

class MassBooking {
  final String id;
  final String qrToken; // FIX #4: added qrToken field (used in QR code display)
  final String profileFullName;
  final String massLabel;
  final DateTime startDateTime;
  final String status;
  final String bookingCode;
  final String parishBookingId;

  MassBooking({
    required this.id,
    required this.qrToken,
    required this.profileFullName,
    required this.massLabel,
    required this.startDateTime,
    required this.status,
    required this.bookingCode,
    required this.parishBookingId,
  });

  factory MassBooking.fromJson(Map<String, dynamic> json) => MassBooking(
        id: json['bookingId'] ?? json['_id'] ?? '',
        qrToken: json['qrToken'] ?? json['bookingId'] ?? '',
        profileFullName: json['profileFullName'] ?? json['fullName'] ?? 'Unknown',
        massLabel: json['massLabel'] ?? 'Mass',
        startDateTime: DateTime.fromMillisecondsSinceEpoch(
            json['startDateTime'] ?? json['slotStartDateTime'] ?? 0),
        status: json['status'] ?? 'booked',
        bookingCode: json['bookingCode'] ?? '',
        parishBookingId: json['displayBookingId']?.toString() ?? 'N/A',
      );

  // FIX #3: needed for shared_preferences persistence
  Map<String, dynamic> toJson() => {
        'bookingId': id,
        'qrToken': qrToken,
        'profileFullName': profileFullName,
        'massLabel': massLabel,
        'startDateTime': startDateTime.millisecondsSinceEpoch,
        'status': status,
        'bookingCode': bookingCode,
        'displayBookingId': parishBookingId,
      };
}

// ─── STATE MANAGEMENT ────────────────────────────────────────
class AppState extends ChangeNotifier {
  String? userId;
  String? userName;
  String? userEmail;
  String? userPhoto;
  String role = "user";

  List<FamilyMember> familyMembers = [];
  List<MassBooking> myBookings = [];
  List<Map<String, String>> localScanHistory = [];

  bool isLoading = false;
  String? loginError; // shown on LoginScreen when sign-in fails

  List<String> relations = [
    "Father", "Mother", "Son", "Daughter",
    "Grandfather", "Grandmother", "Aunty", "Uncle", "Other"
  ];

  // Fetch canonical family role labels from the server
  Future<void> _fetchRelations() async {
    try {
      final res = await http.get(
        Uri.parse('${ConvexConfig.baseUrl}/family/relations'),
        headers: ConvexConfig.headers,
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final fetched = (data['relations'] as List).cast<String>();
        if (fetched.isNotEmpty) {
          relations = fetched;
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('_fetchRelations error: $e');
    }
  }

  // ── FIX #3: Persistence helpers (replaces Firestore reads) ─
  Future<void> _loadBookings() async {
    if (userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('bookings_$userId') ?? [];
    myBookings = raw
        .map((s) => MassBooking.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
    notifyListeners();
  }

  Future<void> _saveBookings() async {
    if (userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'bookings_$userId',
      myBookings.map((b) => jsonEncode(b.toJson())).toList(),
    );
  }

  Future<void> _loadHistory() async {
    if (userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('history_$userId') ?? [];
    localScanHistory = raw
        .map((s) => Map<String, String>.from(jsonDecode(s) as Map))
        .toList();
    notifyListeners();
  }

  Future<void> _saveHistory() async {
    if (userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'history_$userId',
      localScanHistory.map((h) => jsonEncode(h)).toList(),
    );
  }

  Future<void> logScan(String code, String status, String time) async {
    localScanHistory.insert(0, {'code': code, 'status': status, 'time': time});
    if (localScanHistory.length > 200) localScanHistory.removeLast();
    await _saveHistory();
    notifyListeners();
  }

  // 1. Google Auth -> Convex Auth
  Future<void> signInWithGoogle() async {
    isLoading = true;
    loginError = null;
    notifyListeners();
    try {
      // serverClientId MUST match AUTH_GOOGLE_ID on Convex so Android
      // mints an idToken with the correct audience.
      final GoogleSignInAccount? googleUser = await GoogleSignIn(
        serverClientId: ConvexConfig.googleOAuthWebClientId,
      ).signIn();

      if (googleUser == null) {
        // User cancelled the picker
        loginError = null;
        return;
      }

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      debugPrint('idToken present: ${googleAuth.idToken != null}');

      if (googleAuth.idToken == null) {
        loginError =
            'Google did not return an ID token. Check that the OAuth client ID is correct for this app.';
        return;
      }

      http.Response res = await http.post(
        Uri.parse('${ConvexConfig.baseUrl}/auth/google'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'idToken': googleAuth.idToken}),
      );

      debugPrint('Convex /auth/google status: ${res.statusCode}');
      
      // --- AUTO REGISTRATION TRIGGER ---
      // If the user doesn't exist in the Convex DB, register them seamlessly
      if (res.statusCode == 404) {
        debugPrint('User not found. Attempting auto-registration...');
        final regRes = await http.post(
          Uri.parse('${ConvexConfig.baseUrl}/users/register'),
          headers: ConvexConfig.headers,
          body: jsonEncode({
            'name': googleUser.displayName ?? 'New User',
            'email': googleUser.email,
          }),
        );
        
        if (regRes.statusCode == 200) {
          debugPrint('Registration successful! Retrying Google Auth...');
          // Retry the auth call now that the user exists
          res = await http.post(
            Uri.parse('${ConvexConfig.baseUrl}/auth/google'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'idToken': googleAuth.idToken}),
          );
        } else {
          loginError = 'Could not auto-register account. Try registering on the web.';
          isLoading = false;
          notifyListeners();
          return;
        }
      }
      // ---------------------------------

      debugPrint('Convex /auth/google body: ${res.body}');

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        userId = data['userId'] as String?;
        role = (data['user'] as Map<String, dynamic>)['role'] as String? ?? 'user';
        userName = (data['user'] as Map<String, dynamic>)['name'] as String?;
        userEmail = (data['user'] as Map<String, dynamic>)['email'] as String?;
        userPhoto = googleUser.photoUrl;
        await refreshData();
      } else {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        loginError = body['message'] as String? ??
            body['error'] as String? ??
            'Sign-in failed (HTTP ${res.statusCode})';
      }
    } catch (e) {
      debugPrint('Login Error: $e');
      loginError = 'Sign-in error: $e';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  void logout() {
    GoogleSignIn().signOut();
    userId = null;
    familyMembers = [];
    myBookings = [];
    notifyListeners();
  }

  // 2. Fetch Data from Convex
  Future<void> refreshData() async {
    // Always refresh the canonical family role list first
    await _fetchRelations();
    if (userId == null) return;

    // 1. Get Primary Profile (the user themselves)
    final meRes = await http.get(
      Uri.parse('${ConvexConfig.baseUrl}/me?userId=$userId'),
      headers: ConvexConfig.headers,
    );
    
    debugPrint("Convex /me status: ${meRes.statusCode}");
    debugPrint("Convex /me body: ${meRes.body}");

    List<FamilyMember> loaded = [];
    if (meRes.statusCode == 200) {
      final data = jsonDecode(meRes.body)['data'];
      if (data['primary'] != null) {
        loaded.add(FamilyMember.fromJson(data['primary'] as Map<String, dynamic>));
      } else {
        debugPrint("Warning: /me returned no primary profile! The user never successfully saved their profile on the web.");
      }
    }

    // 2. Get Family Members (dependents)
    final famRes = await http.get(
      Uri.parse('${ConvexConfig.baseUrl}/family?userId=$userId'),
      headers: ConvexConfig.headers,
    );
    if (famRes.statusCode == 200) {
      final data = jsonDecode(famRes.body);
      loaded.addAll((data['rows'] as List)
          .map((m) => FamilyMember.fromJson(m as Map<String, dynamic>)));
    }
    
    familyMembers = loaded;

    // Fetch bookings from backend so web-created bookings appear in the app
    await _refreshBookings();

    // Load local volunteer scan history
    await _loadHistory();

    notifyListeners();
  }

  /// Fetches bookings from the server. Falls back to local cache if the
  /// endpoint is not yet deployed on the target backend.
  Future<void> _refreshBookings() async {
    if (userId == null) return;
    try {
      final res = await http.get(
        Uri.parse('${ConvexConfig.baseUrl}/bookings?userId=$userId'),
        headers: ConvexConfig.headers,
      );
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body) as Map<String, dynamic>;
        if (decoded['ok'] == true && decoded['rows'] is List) {
          final serverBookings = (decoded['rows'] as List)
              .map((b) => MassBooking.fromJson(b as Map<String, dynamic>))
              .toList();
          myBookings = serverBookings;
          await _saveBookings(); // keep local cache in sync
          return;
        }
      }
    } catch (_) {}
    // Fallback: load from local SharedPreferences
    await _loadBookings();
  }

  // 3. Profile Actions
  Future<String?> addFamilyMember(
      String name, String rel, String dob, String idNum, String mobile, {String parishNumber = ''}) async {
    
    final res = await http.post(
      Uri.parse('${ConvexConfig.baseUrl}/family'),
      headers: ConvexConfig.headers,
      body: jsonEncode({
        'userId': userId,
        'fullName': name,
        'relation': rel,
        'dob': dob,
        'idType': 'uaeId',
        'idNumber': idNum,
        'mobile': mobile,
        'active': true,
        if (parishNumber.trim().isNotEmpty) 'parishNumber': parishNumber.trim(),
      }),
    );
    
    if (res.statusCode == 200) {
      await refreshData();
      return null;
    } else {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return body['message']?.toString() ?? body['error']?.toString() ?? 'Unknown error';
    }
  }

  // 4. Edit Existing Profile Action
  Future<String?> editFamilyMember(
      String profileId, String name, String rel, String dob, String idNum, String mobile, {bool isPrimary = false, String parishNumber = ''}) async {
    final endpoint = isPrimary ? '/me' : '/family';
    final res = await http.patch(
      Uri.parse('${ConvexConfig.baseUrl}$endpoint'),
      headers: ConvexConfig.headers,
      body: jsonEncode({
        'userId': userId,
        if (!isPrimary) 'profileId': profileId,
        'fullName': name,
        'relation': rel,
        'dob': dob,
        'idType': 'uaeId',
        'idNumber': idNum,
        'mobile': mobile,
        'active': true,
        if (parishNumber.trim().isNotEmpty) 'parishNumber': parishNumber.trim(),
      }),
    );
    
    if (res.statusCode == 200) {
      await refreshData();
      return null;
    } else {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return body['message']?.toString() ?? body['error']?.toString() ?? 'Unknown error';
    }
  }

  // 5. Delete Family Member (non-primary only)
  Future<String?> deleteFamilyMember(String profileId) async {
    // http.delete() drops the body in some Dart versions — use Request instead
    final request = http.Request(
      'DELETE',
      Uri.parse('${ConvexConfig.baseUrl}/family'),
    );
    request.headers.addAll(ConvexConfig.headers);
    request.body = jsonEncode({
      'userId': userId,
      'profileId': profileId,
    });

    final streamed = await request.send();
    final resBody = await streamed.stream.bytesToString();

    if (streamed.statusCode == 200) {
      await refreshData();
      return null;
    } else {
      // Backend may return plain text (e.g. "No matching routes found") when
      // the endpoint doesn't exist yet — handle both JSON and raw text safely.
      try {
        final parsed = jsonDecode(resBody) as Map<String, dynamic>;
        return parsed['error']?.toString() ?? parsed['message']?.toString() ?? 'Delete failed';
      } catch (_) {
        return resBody.isNotEmpty ? resBody : 'Delete failed (server error)';
      }
    }
  }


  String _friendlyError(String raw) {
    final l = raw.toLowerCase();
    if (l.contains("already") && l.contains("booking")) {
      return "Oops! It seems someone you've selected is already booked for this weekend.";
    }
    if (l.contains("capacity") || l.contains("insufficient")) {
      return "We're really sorry, but this Mass time is now completely full. Please try another slot!";
    }
    if (l.contains("inactive")) {
      return "One of these profiles requires an update before we can secure a booking.";
    }
    if (l.contains("closed") || l.contains("window")) {
      return "Bookings for this weekend haven't opened yet! Please check back later.";
    }
    if (l.contains("limit")) {
      return "You've reached the maximum booking limit. Thank you for your understanding!";
    }
    return raw.length > 60 ? "We couldn't complete the booking right now. Please check your selections." : raw;
  }

  // 5. Booking Actions
  Future<String?> bookMass(
      List<String> profileIds, String parishDateYmd, String templateId) async {
    final res = await http.post(
      Uri.parse("${ConvexConfig.baseUrl}/bookings/by-home-template"),
      headers: ConvexConfig.headers,
      body: jsonEncode({
        "userId": userId,
        "parishDateYmd": parishDateYmd,
        "templateScheduleEntryId": templateId,
        "profileIds": profileIds
      }),
    );

    if (res.statusCode == 200) {
      final decoded = jsonDecode(res.body);
      if (decoded['ok'] == false) {
        final rawError = decoded['message']?.toString() ?? decoded['error']?.toString() ?? 'Check rules';
        return _friendlyError(rawError);
      }
      
      // FIX #3: Parse booking result and persist locally
      final data = decoded['result'] as Map<String, dynamic>;
      final massLabel = data['massLabel'] ?? 'Mass';
      final startMs = (data['slotStartDateTime'] ?? 0) as int;

      final newBookings = (data['bookings'] as List).map((b) {
        final bMap = b as Map<String, dynamic>;
        return MassBooking(
          id: bMap['bookingId'] ?? '',
          qrToken: bMap['qrToken'] ?? bMap['bookingId'] ?? '', // FIX #4: store qrToken
          profileFullName: bMap['fullName'] ?? bMap['profileFullName'] ?? 'Unknown',
          massLabel: massLabel,
          startDateTime: DateTime.fromMillisecondsSinceEpoch(startMs),
          status: 'booked',
          bookingCode: bMap['bookingCode'] ?? '',
          parishBookingId: bMap['displayBookingId']?.toString() ?? 'N/A',
        );
      }).toList();

      myBookings.addAll(newBookings);
      await _saveBookings();
      notifyListeners();
      return null;
    }
    
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final rawError = body['message']?.toString() ?? body['error']?.toString() ?? 'Server issue';
    return _friendlyError(rawError);
  }

  // 6. Cancel a booking — calls backend to set status=cancelled so rebooking is allowed
  Future<String?> cancelBooking(String bookingId) async {
    // Try to cancel on the backend first
    try {
      final request = http.Request(
        'DELETE',
        Uri.parse('${ConvexConfig.baseUrl}/bookings'),
      );
      request.headers.addAll(ConvexConfig.headers);
      request.body = jsonEncode({
        'userId': userId,
        'bookingId': bookingId,
      });
      final streamed = await request.send();
      final resBody = await streamed.stream.bytesToString();

      if (streamed.statusCode == 200) {
        // Remove from local list and refresh from server
        myBookings.removeWhere((b) => b.id == bookingId);
        await _saveBookings();
        notifyListeners();
        return null;
      } else {
        // Parse error safely
        try {
          final parsed = jsonDecode(resBody) as Map<String, dynamic>;
          final errMsg = parsed['error']?.toString() ?? 'Cancellation failed';
          return errMsg;
        } catch (_) {
          return resBody.isNotEmpty ? resBody : 'Cancellation failed (server error)';
        }
      }
    } catch (_) {
      // Endpoint not deployed yet — remove locally only
      myBookings.removeWhere((b) => b.id == bookingId);
      await _saveBookings();
      notifyListeners();
      return null;
    }
  }
}

// ─── THE APP ─────────────────────────────────────────────────
class StMarysApp extends StatelessWidget {
  const StMarysApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "St. Mary's Mass Booking",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E3A5F)),
          useMaterial3: true),
      home: Consumer<AppState>(builder: (context, s, child) {
        if (s.userId == null) return const LoginScreen();
        if (s.role == "admin") return const AdminMainScreen();
        if (s.role == "volunteer") return const VolunteerMainScreen();
        return const MainNavigation();
      }),
    );
  }
}

// ─── LOGIN SCREEN ──────────────────────────────────────────
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return Scaffold(
        backgroundColor: const Color(0xFF0A1628),
        body: Center(
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
          Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24, width: 4),
                  image: const DecorationImage(
                      image: AssetImage('assets/icon.jpg.jpg'),
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter))),
          const SizedBox(height: 30),
          const Text("St. Mary's Catholic Church",
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold)),
          const Text("Dubai",
              style: TextStyle(color: Colors.white, fontSize: 20)),
          const SizedBox(height: 10),
          const Text("Mass Booking App",
              style: TextStyle(color: Colors.white70, fontSize: 16)),
          const SizedBox(height: 60),
          if (s.isLoading)
            const CircularProgressIndicator(color: Colors.white)
          else
            ElevatedButton.icon(
                onPressed: () => s.signInWithGoogle(),
                icon: const Icon(Icons.login, color: Color(0xFF1E3A5F)),
                label: const Text("Sign in with Google"),
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black87,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 30, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30)))),
          // Visible error message — no more silent failures
          if (s.loginError != null) ...[
            const SizedBox(height: 24),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 32),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade900.withOpacity(0.85),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                s.loginError!,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ])));
  }
}

// ─── USER NAVIGATION ─────────────────────────────────────────
class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _idx = 0;
  bool _instr = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_instr) {
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const InstructionsScreen()));
        _instr = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
          title: const Text("St. Mary's Catholic Church, Dubai"),
          actions: [
            IconButton(
                onPressed: () => _showUserDetail(context, s),
                icon: CircleAvatar(
                    backgroundImage: s.userPhoto != null
                        ? NetworkImage(s.userPhoto!)
                        : null,
                    child: s.userPhoto == null
                        ? const Icon(Icons.person)
                        : null))
          ]),
      body: [
        const UserHomeScreen(),
        const BookMassScreen(),
        const MyListedMassesScreen()
      ][_idx],
      bottomNavigationBar: NavigationBar(
          selectedIndex: _idx,
          onDestinationSelected: (i) => setState(() => _idx = i),
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.home_outlined), label: 'Home'),
            NavigationDestination(
                icon: Icon(Icons.add_circle_outline), label: 'Book'),
            NavigationDestination(
                icon: Icon(Icons.qr_code_outlined), label: 'Tickets'),
          ]),
    );
  }

  void _showUserDetail(BuildContext c, AppState s) {
    showDialog(
        context: c,
        builder: (c) => AlertDialog(
                content: Column(mainAxisSize: MainAxisSize.min, children: [
              CircleAvatar(
                  radius: 40,
                  backgroundImage: s.userPhoto != null
                      ? NetworkImage(s.userPhoto!)
                      : null),
              const SizedBox(height: 10),
              Text(s.userName ?? "User"),
              const Divider(),
              Text("ID: ${s.userId}",
                  style: const TextStyle(fontSize: 10)),
              const SizedBox(height: 20),
              OutlinedButton(
                  onPressed: () {
                    s.logout();
                    Navigator.pop(c);
                  },
                  child: const Text("Logout",
                      style: TextStyle(color: Colors.red)))
            ])));
  }
}

class InstructionsScreen extends StatelessWidget {
  const InstructionsScreen({super.key});

  static const _instructions = [
    "All Masses will be celebrated in English (Latin Rite).",
    "Registration is strictly individual.",
    "Only adults aged 18+ permitted.",
    "Access pass required on Sat/Sun.",
    "Only one Mass per day per person.",
    "Arrive 30 mins early.",
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F4F8),
      appBar: AppBar(
        title: const Text("Instructions"),
        backgroundColor: const Color(0xFF1E3A5F),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E3A5F).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.info_outline,
                      color: Color(0xFF1E3A5F), size: 26),
                ),
                const SizedBox(width: 14),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Important Instructions",
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1E3A5F))),
                    Text("Please read before proceeding",
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                )
              ]),
              const SizedBox(height: 20),

              // Instruction Cards
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDFBF5), // light ivory
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      )
                    ],
                  ),
                  child: ListView.separated(
                    itemCount: _instructions.length,
                    separatorBuilder: (_, __) => const Divider(height: 20, color: Color(0xFFE8E0D0)),
                    itemBuilder: (ctx, i) => Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Color(0xFF1E3A5F), // Oxford blue bullet
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            _instructions[i],
                            style: const TextStyle(
                                fontSize: 14.5, height: 1.5, color: Color(0xFF2D3748)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // I Agree Button — prominent and visible
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.check_circle_outline, size: 22),
                  label: const Text(
                    "I Agree & Continue",
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E3A5F),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    elevation: 4,
                    shadowColor: const Color(0xFF1E3A5F).withOpacity(0.4),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


class UserHomeScreen extends StatelessWidget {
  const UserHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return RefreshIndicator(
      onRefresh: () => s.refreshData(),
      child: ListView(
        padding: const EdgeInsets.all(20), 
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [Color(0xFF1E3A5F), Color(0xFF1565C0)]),
                  borderRadius: BorderRadius.circular(20)),
              child: const Text(
                  "Capacity Limit: 3185 members. Please book in advance.",
                  style: TextStyle(color: Colors.white, fontSize: 13))),
          const SizedBox(height: 30),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text("Family Profiles",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            FilledButton.tonal(
                onPressed: () => showDialog(
                    context: context,
                    builder: (c) => const FamilyMemberDialog()),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 18),
                    SizedBox(width: 6),
                    Text("Add Profile"),
                  ],
                ))
          ]),
          if (s.familyMembers.isEmpty)
             const Padding(
               padding: EdgeInsets.only(top: 20.0),
               child: Text("Swipe down to refresh profiles", style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic)),
             ),
          // FIX #6: was m.uaeId (non-existent field) → now m.idNumber
          ...s.familyMembers.asMap().entries.map((entry) {
            final idx = entry.key;
            final m = entry.value;
            final isPrimary = idx == 0;
            return Card(
              margin: const EdgeInsets.only(top: 10),
              child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isPrimary ? const Color(0xFF1E3A5F) : Colors.grey.shade300,
                    child: Icon(isPrimary ? Icons.admin_panel_settings : Icons.person, color: isPrimary ? Colors.white : Colors.black54),
                  ),
                  title: Text(m.fullName + (isPrimary ? " (Primary)" : "")),
                  subtitle: Text("${m.relation} \u2022 ${m.idNumber}"),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.blueGrey, size: 20),
                        tooltip: 'Edit profile',
                        onPressed: () => showDialog(
                          context: context,
                          builder: (_) => FamilyMemberDialog(member: m, isPrimary: isPrimary),
                        ),
                      ),
                      if (!isPrimary)
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                          tooltip: 'Remove profile',
                          onPressed: () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                title: const Text('Remove Profile'),
                                content: Text(
                                  'Are you sure you want to remove the profile for ${m.fullName}?\n\nNote: profiles with upcoming Mass bookings cannot be deleted.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('Cancel'),
                                  ),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red,
                                      foregroundColor: Colors.white,
                                    ),
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('Remove'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed == true && context.mounted) {
                              final error = await s.deleteFamilyMember(m.id);
                              if (error != null && context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(error),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            }
                          },
                        ),
                    ],
                  ),
              ),
            );
          })
        ]
      )
    );
  }
}

class FamilyMemberDialog extends StatefulWidget {
  final FamilyMember? member;
  final bool isPrimary;
  const FamilyMemberDialog({super.key, this.member, this.isPrimary = false});

  @override
  State<FamilyMemberDialog> createState() =>
      _FamilyMemberDialogState();
}

class _FamilyMemberDialogState extends State<FamilyMemberDialog> {
  final _f = GlobalKey<FormState>();
  final n = TextEditingController();
  final idS = TextEditingController();
  final m = TextEditingController();
  final pN = TextEditingController(); // parish number
  String? r;
  DateTime? d;

  // ── Emirates ID scan state ───────────────────────────────────
  bool _scanning = false;
  String? _scanError;
  File? _scannedImage;
  double? _scanConfidence;

  Future<void> _scanEmiratesId(ImageSource source) async {
    setState(() { _scanning = true; _scanError = null; _scannedImage = null; _scanConfidence = null; });
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        imageQuality: 90,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (picked == null) { setState(() => _scanning = false); return; }

      final imageFile = File(picked.path);
      setState(() => _scannedImage = imageFile);

      final uri = Uri.parse('${ConvexConfig.baseUrl}/extract-id');
      // Use multipart/form-data as required by backend
      final request = http.MultipartRequest('POST', uri)
        ..headers.addAll({
          'X-Mobile-Auth': 'UIYhkjasd09812ajsdasd143',
        })
        ..files.add(await http.MultipartFile.fromPath('image', imageFile.path));

      final streamed = await request.send();
      final body = await streamed.stream.bytesToString();
      final json = jsonDecode(body) as Map<String, dynamic>;

      if (streamed.statusCode != 200 || json['ok'] != true) {
        setState(() {
          _scanError = json['error']?.toString() ?? 'Could not extract ID details.';
          _scanning = false;
        });
        return;
      }

      // ── Auto-fill from response ──────────────────────────────
      final extractedName   = json['name']?.toString() ?? '';
      final extractedDob    = json['dob']?.toString() ?? '';   // YYYY-MM-DD
      final extractedEid    = json['emiratesId']?.toString() ?? ''; // 784-YYYY-XXXXXXX-X
      final confidence      = (json['confidence'] as num?)?.toDouble();

      if (extractedName.isNotEmpty) n.text = extractedName;

      if (extractedDob.isNotEmpty) {
        try { d = DateTime.parse(extractedDob); } catch (_) {}
      }

      // Parse suffix from full EID (e.g. "784-2000-1234567-8" → "1234567-8")
      if (extractedEid.isNotEmpty) {
        final parts = extractedEid.split('-');
        if (parts.length == 4) {
          idS.text = '${parts[2]}-${parts[3]}';
        }
      }

      setState(() {
        _scanning = false;
        _scanConfidence = confidence;
      });
    } catch (e) {
      setState(() {
        _scanError = 'Scan failed: ${e.toString()}';
        _scanning = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.member != null) {
      n.text = widget.member!.fullName;
      m.text = widget.member!.mobile;
      pN.text = widget.member!.parishNumber; // load for all profiles
      
      try { d = DateTime.parse(widget.member!.dob); } catch (_) {}
      
      // Map legacy/invalid relations (Child-1, Husband, Wife, etc.) to raw stored value;
      // build() will resolve it to the nearest valid option dynamically
      if (!widget.isPrimary && widget.member!.relation.isNotEmpty) {
        r = widget.member!.relation;
      }

      final parts = widget.member!.idNumber.split('-');
      if (parts.length >= 3) {
        idS.text = parts.sublist(2).join('-');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // watch so widget rebuilds when _fetchRelations() updates relations list
    final s = context.watch<AppState>();

    // Resolve stored relation: if stored value (e.g. "Child-4") isn't in the
    // new server-defined list, fall back to "Other" so the dropdown is valid
    final resolvedR = s.relations.contains(r)
        ? r
        : (s.relations.contains("Other")
            ? "Other"
            : (s.relations.isNotEmpty ? s.relations.first : null));

    Widget fieldLabel(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            text,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: Color(0xFF1E3A5F),
              letterSpacing: 0.2,
            ),
          ),
        );

    InputDecoration inputStyle({String? hint, String? helper, Color? fill}) =>
        InputDecoration(
          hintText: hint,
          helperText: helper,
          filled: true,
          fillColor: fill ?? Colors.grey.shade50,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  BorderSide(color: Theme.of(context).primaryColor, width: 1.5)),
          errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.red.shade300)),
          disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none),
        );

    return Dialog(
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: SingleChildScrollView(
          child: Form(
            key: _f,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Title ───────────────────────────────────────────
                Text(
                  widget.member == null ? "Add Profile" : "Update Profile",
                  style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E3A5F)),
                ),
                const SizedBox(height: 24),

                // ── Emirates ID Scan (Add mode only) ─────────────────
                if (widget.member == null) ...[
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFEEF2FF),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFBFCBF5)),
                    ),
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.credit_card, color: Color(0xFF1E3A5F), size: 18),
                            SizedBox(width: 8),
                            Text(
                              'Scan Emirates ID (optional)',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: Color(0xFF1E3A5F),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Take a photo or upload the front of the Emirates ID to auto-fill details.',
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                        const SizedBox(height: 10),
                        // Buttons row
                        if (!_scanning) Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.camera_alt, size: 16),
                                label: const Text('Camera', style: TextStyle(fontSize: 13)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF1E3A5F),
                                  side: const BorderSide(color: Color(0xFF1E3A5F)),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                                onPressed: () => _scanEmiratesId(ImageSource.camera),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.photo_library, size: 16),
                                label: const Text('Gallery', style: TextStyle(fontSize: 13)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF1E3A5F),
                                  side: const BorderSide(color: Color(0xFF1E3A5F)),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                                onPressed: () => _scanEmiratesId(ImageSource.gallery),
                              ),
                            ),
                          ],
                        ),
                        // Scanning indicator
                        if (_scanning) const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                              SizedBox(width: 10),
                              Text('Extracting details…', style: TextStyle(fontSize: 13, color: Color(0xFF1E3A5F))),
                            ],
                          ),
                        ),
                        // Preview of scanned image
                        if (_scannedImage != null && !_scanning) ...[  
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.file(_scannedImage!, height: 120, fit: BoxFit.cover, width: double.infinity),
                          ),
                        ],
                        // Confidence indicator
                        if (_scanConfidence != null && !_scanning) ...[  
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(Icons.check_circle, color: Colors.green, size: 14),
                              const SizedBox(width: 4),
                              Text(
                                'Auto-filled with ${(_scanConfidence! * 100).toStringAsFixed(0)}% confidence. Please verify.',
                                style: const TextStyle(fontSize: 11, color: Colors.green),
                              ),
                            ],
                          ),
                        ],
                        // Error
                        if (_scanError != null) ...[  
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(Icons.warning_amber, color: Colors.red, size: 14),
                              const SizedBox(width: 4),
                              Expanded(child: Text(_scanError!, style: const TextStyle(fontSize: 11, color: Colors.red))),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // ── Full Name ────────────────────────────────────────
                fieldLabel("Full Name"),
                TextFormField(
                  controller: n,
                  decoration: inputStyle(hint: "Enter full name"),
                  validator: (v) =>
                      v == null || v.isEmpty ? "Required field" : null,
                ),
                const SizedBox(height: 20),

                // ── Parish Number (all profiles) ─────────────────────
                fieldLabel("Parish Number (optional)"),
                TextFormField(
                  controller: pN,
                  decoration: inputStyle(
                      hint: "e.g. envelope or register number"),
                  keyboardType: TextInputType.text,
                  textCapitalization: TextCapitalization.characters,
                ),
                const SizedBox(height: 20),

                // ── Date of Birth ────────────────────────────────────
                fieldLabel("Date of Birth"),
                InkWell(
                  onTap: widget.member != null
                      ? null
                      : () async {
                          final dt = await showDatePicker(
                            context: context,
                            initialDate: d ?? DateTime(2000),
                            firstDate: DateTime(1920),
                            lastDate: DateTime.now(),
                          );
                          if (dt != null) setState(() => d = dt);
                        },
                  borderRadius: BorderRadius.circular(12),
                  child: InputDecorator(
                    decoration: inputStyle(
                      fill: widget.member != null ? Colors.grey.shade200 : Colors.grey.shade50,
                    ).copyWith(
                      errorText: (d == null &&
                              _f.currentState != null &&
                              !(_f.currentState!.validate())) &&
                          d == null
                          ? "Please select a date"
                          : null,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          d == null
                              ? "Select Date"
                              : DateFormat('dd/MM/yyyy').format(d!),
                          style: TextStyle(
                              color: (d == null || widget.member != null)
                                  ? Colors.grey.shade600
                                  : Colors.black87,
                              fontSize: 16),
                        ),
                        Icon(Icons.calendar_month,
                            color: Colors.grey.shade600),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // ── UAE ID ───────────────────────────────────────────
                fieldLabel("UAE ID (Emirates ID)"),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        key: ValueKey(d?.year),
                        initialValue: "784-${d?.year ?? 'YYYY'}-",
                        enabled: false,
                        decoration:
                            inputStyle(fill: Colors.grey.shade200),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 5,
                      child: TextFormField(
                        controller: idS,
                        enabled: widget.member == null ||
                            widget.member!.idNumber.trim().isEmpty,
                        decoration: inputStyle(
                          hint: "1234567-1",
                          fill: (widget.member != null &&
                                  widget.member!.idNumber.trim().isNotEmpty)
                              ? Colors.grey.shade200
                              : Colors.grey.shade50,
                        ),
                        keyboardType: TextInputType.number,
                        maxLength: 9,
                        validator: (v) =>
                            RegExp(r'^[0-9]{7}-[0-9]{1}$').hasMatch(v ?? "")
                                ? null
                                : "Must be XXXXXXX-X",
                        onChanged: (v) {
                          if (v.length == 7 && !v.contains("-")) {
                            idS.text = "$v-";
                            idS.selection = TextSelection.fromPosition(
                                TextPosition(offset: idS.text.length));
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // ── Relationship ─────────────────────────────────────
                fieldLabel("Relationship"),
                if (widget.isPrimary)
                  TextFormField(
                    initialValue: widget.member?.relation ?? "Self",
                    enabled: false,
                    decoration: inputStyle(fill: Colors.grey.shade200),
                  )
                else
                  DropdownButtonFormField<String>(
                    value: resolvedR,
                    decoration: inputStyle(),
                    items: s.relations
                        .map((rel) => DropdownMenuItem(
                            value: rel, child: Text(rel)))
                        .toList(),
                    onChanged: (v) => setState(() => r = v),
                    validator: (v) =>
                        v == null ? "Please select a relationship" : null,
                  ),
                const SizedBox(height: 20),

                // ── Mobile Number ────────────────────────────────────
                fieldLabel("Mobile Number"),
                TextFormField(
                  controller: m,
                  decoration: inputStyle(
                    hint: "e.g., 971501234567",
                    helper: "12-digit UAE number starting with 9715",
                  ),
                  keyboardType: TextInputType.phone,
                  maxLength: 12,
                  validator: (v) {
                    if (v == null || v.isEmpty) return "Required field";
                    if (!v.startsWith('9715') || v.length != 12)
                      return "Must be 12 digits starting with 9715";
                    return null;
                  },
                ),
                const SizedBox(height: 32),

                // ── Action Buttons ───────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 14),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: const Text("Cancel"),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1E3A5F),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 14),
                        elevation: 0,
                      ),
                      onPressed: () async {
                        setState(() {});
                        if (!_f.currentState!.validate() || d == null) return;

                        final resolvedRForSubmit = widget.isPrimary 
                                ? (widget.member?.relation ?? 'Self') 
                                : (r ?? resolvedR ?? s.relations.first);
                        final dobStr = DateFormat('yyyy-MM-dd').format(d!);
                        final uaeIdStr = "784-${d!.year}-${idS.text}";
                        final parishStr = pN.text.trim();

                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (ctx) {
                            bool checked = false;
                            return StatefulBuilder(
                              builder: (ctx, setDialogState) {
                                return AlertDialog(
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  title: const Text("Confirm Details"),
                                  content: SingleChildScrollView(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text("Do you really want to save this profile? Please verify the information entered:"),
                                        const SizedBox(height: 12),
                                        Text("Full Name: ${n.text}", style: const TextStyle(fontWeight: FontWeight.bold)),
                                        if (parishStr.isNotEmpty)
                                          Text("Parish Number: $parishStr", style: const TextStyle(fontWeight: FontWeight.bold)),
                                        Text("Relation: $resolvedRForSubmit", style: const TextStyle(fontWeight: FontWeight.bold)),
                                        Text("Date of Birth: $dobStr", style: const TextStyle(fontWeight: FontWeight.bold)),
                                        Text("UAE ID: $uaeIdStr", style: const TextStyle(fontWeight: FontWeight.bold)),
                                        Text("Mobile: ${m.text}", style: const TextStyle(fontWeight: FontWeight.bold)),
                                        const SizedBox(height: 16),
                                        Row(
                                          children: [
                                            Checkbox(
                                              value: checked,
                                              onChanged: (val) {
                                                setDialogState(() => checked = val ?? false);
                                              },
                                            ),
                                            const Expanded(
                                              child: Text(
                                                "I confirm that the above information is true to my knowledge.",
                                                style: TextStyle(fontSize: 13),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, false),
                                      child: const Text("Reject"),
                                    ),
                                    ElevatedButton(
                                      onPressed: checked ? () => Navigator.pop(ctx, true) : null,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF1E3A5F),
                                        foregroundColor: Colors.white,
                                        disabledBackgroundColor: Colors.grey.shade300,
                                      ),
                                      child: const Text("Confirm"),
                                    ),
                                  ],
                                );
                              },
                            );
                          },
                        );

                        if (confirmed != true) return;

                        final String? error;

                        if (widget.member == null) {
                          error = await s.addFamilyMember(
                            n.text,
                            resolvedRForSubmit,
                            dobStr,
                            uaeIdStr,
                            m.text,
                            parishNumber: parishStr,
                          );
                        } else {
                          error = await s.editFamilyMember(
                            widget.member!.id,
                            n.text,
                            resolvedRForSubmit,
                            dobStr,
                            uaeIdStr,
                            m.text,
                            isPrimary: widget.isPrimary,
                            parishNumber: parishStr,
                          );
                        }

                        if (context.mounted) {
                          if (error == null)
                            Navigator.pop(context);
                          else
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text('Error: $error'),
                                  backgroundColor: Colors.red),
                            );
                        }
                      },
                      child: Text(
                        widget.member == null ? "Save Profile" : "Update Profile",
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class BookMassScreen extends StatefulWidget {
  const BookMassScreen({super.key});

  @override
  State<BookMassScreen> createState() => _BookMassScreenState();
}

class _BookMassScreenState extends State<BookMassScreen> {
  // Selected date — defaults to today; corrected once flag is loaded
  DateTime dt = DateTime.now();
  String? templateId;
  List<String> selectedProfiles = [];
  List<dynamic> availableSlots = [];

  // ── New state for parity with web ────────────────────────────
  List<dynamic> _publishedMasses = [];  // concrete slots for the selected date
  bool _allowAnyDay = false;            // mirrors allowAnyDayWeekendScheduleBooking
  bool _flagLoading = true;             // shows spinner until flag is fetched
  List<dynamic> _availabilityRules = []; // mirrors massAvailability rules

  @override
  void initState() {
    super.initState();
    _fetchInitialFlagThenSlots();
  }

  /// Probes the API with the upcoming Saturday to get allowAnyDay flag,
  /// then sets the correct initial date and fetches slots for it.
  Future<void> _fetchInitialFlagThenSlots() async {
    final now = DateTime.now();
    int daysToSat = DateTime.saturday - now.weekday;
    if (daysToSat <= 0) daysToSat += 7;
    final probeSat = now.add(Duration(days: daysToSat));
    try {
      final res = await http.get(
        Uri.parse("${ConvexConfig.baseUrl}/mass-schedule/times?parishDateYmd=${DateFormat('yyyy-MM-dd').format(probeSat)}"),
        headers: ConvexConfig.headers,
      );
      if (res.statusCode == 200 && mounted) {
        final body = jsonDecode(res.body);
        if (body['ok'] == true) {
          final allowAny = body['allowAnyDayWeekendScheduleBooking'] == true;
          // When any day is allowed, default to today; otherwise upcoming Saturday
          final initialDate = allowAny
              ? now
              : (now.weekday == DateTime.saturday || now.weekday == DateTime.sunday)
                  ? now
                  : now.add(Duration(days: DateTime.saturday - now.weekday));
          if (mounted) {
            setState(() {
              _allowAnyDay = allowAny;
              _availabilityRules = List<dynamic>.from(body['availabilityRules'] ?? []);
              _flagLoading = false;
              dt = initialDate;
            });
          }
        }
      }
    } catch (_) {}
    if (mounted && _flagLoading) setState(() => _flagLoading = false);
    await _fetchSlots();
  }

  int _timeToMinutes(String timeStr) {
    try {
      final parts = timeStr.trim().split(RegExp(r'\s+'));
      if (parts.isEmpty) return 0;
      final hm = parts[0].split(':');
      int h = int.parse(hm[0]);
      int m = hm.length > 1 ? int.parse(hm[1]) : 0;
      final amPm = parts.length > 1 ? parts[1].toUpperCase() : '';
      if (amPm == 'PM' && h != 12) h += 12;
      if (amPm == 'AM' && h == 12) h = 0;
      return h * 60 + m;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _fetchSlots() async {
    final res = await http.get(
      Uri.parse("${ConvexConfig.baseUrl}/mass-schedule/times?parishDateYmd=${DateFormat('yyyy-MM-dd').format(dt)}"),
      headers: ConvexConfig.headers,
    );
    if (res.statusCode == 200 && mounted) {
      final body = jsonDecode(res.body);
      if (body['ok'] == true) {
        final List<dynamic> slots = body['templateTimesForDay'] ?? [];
        slots.sort((a, b) => _timeToMinutes(a['time']?.toString() ?? '')
            .compareTo(_timeToMinutes(b['time']?.toString() ?? '')));
        setState(() {
          availableSlots = slots;
          _publishedMasses = List<dynamic>.from(body['publishedMasses'] ?? []);
          _allowAnyDay = body['allowAnyDayWeekendScheduleBooking'] == true;
          _availabilityRules = List<dynamic>.from(body['availabilityRules'] ?? []);
        });
      }
    }
  }

  /// Finds the published mass slot matching a template entry by language + time.
  dynamic _findPublishedMass(String language, String templateTime) {
    for (final pm in _publishedMasses) {
      if (pm['language']?.toString() != language) continue;
      final startMs = pm['startDateTime'];
      if (startMs is int) {
        final pmLocal = DateTime.fromMillisecondsSinceEpoch(startMs).toLocal();
        final h = pmLocal.hour;
        final m = pmLocal.minute;
        final period = h >= 12 ? 'PM' : 'AM';
        final h12 = h > 12 ? h - 12 : (h == 0 ? 12 : h);
        final formatted = "${h12.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')} $period";
        if (formatted == templateTime) return pm;
      }
      if ((pm['label']?.toString() ?? '').contains(templateTime)) return pm;
    }
    return null;
  }

  /// Returns true if the mass time has already passed.
  bool _isTimePassed(dynamic publishedMass) {
    if (publishedMass == null) return false;
    final startMs = publishedMass['startDateTime'];
    if (startMs is int) return DateTime.fromMillisecondsSinceEpoch(startMs).isBefore(DateTime.now());
    return false;
  }

  /// Returns true if the user already has a booking for this slot.
  bool _isAlreadyBooked(dynamic publishedMass, List<MassBooking> myBookings) {
    if (publishedMass == null) return false;
    final startMs = publishedMass['startDateTime'];
    if (startMs == null) return false;
    return myBookings.any((b) => b.startDateTime.millisecondsSinceEpoch == startMs);
  }

  List<Widget> _buildGroupedTimeSlots(List<dynamic> slots, List<MassBooking> myBookings) {
    if (slots.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            "No Mass times available for this date.",
            style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
          ),
        )
      ];
    }

    Color langColor(String lang) {
      switch (lang.toLowerCase()) {
        case 'english':   return const Color(0xFF1E3A5F);
        case 'tamil':     return const Color(0xFF2E7D32);
        case 'malayalam': return const Color(0xFF6A1B9A);
        case 'hindi':     return const Color(0xFFE65100);
        case 'arabic':    return const Color(0xFF00695C);
        case 'konkani':   return const Color(0xFF4527A0);
        default:          return const Color(0xFF37474F);
      }
    }

    String categoryLabel(String cat) {
      switch (cat.toLowerCase()) {
        case 'weekend': return '⛪  Weekend Masses';
        case 'weekday': return '🕐  Weekday Masses';
        default:        return '✨  Special Services';
      }
    }

    Color categoryColor(String cat) {
      switch (cat.toLowerCase()) {
        case 'weekend': return const Color(0xFFF9A825);
        case 'weekday': return const Color(0xFF1565C0);
        default:        return const Color(0xFF6A1B9A);
      }
    }

    // Group by category → language → location
    final Map<String, Map<String, Map<String, List<dynamic>>>> grouped = {};
    for (final slot in slots) {
      final cat  = slot['category']?.toString() ?? 'Other';
      final lang = slot['language']?.toString() ?? 'English';
      final loc  = slot['location']?.toString() ?? '';
      grouped.putIfAbsent(cat, () => {});
      grouped[cat]!.putIfAbsent(lang, () => {});
      grouped[cat]![lang]!.putIfAbsent(loc, () => []);
      grouped[cat]![lang]![loc]!.add(slot);
    }

    final catOrder = ['Weekend', 'Weekday', 'Other'];
    final sortedCats = grouped.keys.toList()
      ..sort((a, b) {
        final ai = catOrder.indexWhere((c) => c.toLowerCase() == a.toLowerCase());
        final bi = catOrder.indexWhere((c) => c.toLowerCase() == b.toLowerCase());
        return (ai < 0 ? 99 : ai).compareTo(bi < 0 ? 99 : bi);
      });

    final widgets = <Widget>[];

    for (final cat in sortedCats) {
      final languages  = grouped[cat]!;
      final catColor   = categoryColor(cat);
      final catLabel   = categoryLabel(cat);

      // ── Category divider header ─────────────────────────────
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 10),
        child: Row(children: [
          Expanded(child: Divider(color: catColor.withOpacity(0.3), thickness: 1)),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: catColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: catColor.withOpacity(0.4)),
            ),
            child: Text(catLabel,
                style: TextStyle(color: catColor, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.4)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Divider(color: catColor.withOpacity(0.3), thickness: 1)),
        ]),
      ));

      languages.forEach((language, locations) {
        final lColor = langColor(language);

        // ── Language pill with globe icon ───────────────────────
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: lColor,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color: lColor.withOpacity(0.3), blurRadius: 6, offset: const Offset(0, 2))],
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.language, color: Colors.white, size: 12),
                const SizedBox(width: 5),
                Text(language,
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.3)),
              ]),
            ),
          ]),
        ));

        locations.forEach((location, locSlots) {
          // ── Location chip ─────────────────────────────────────
          if (location.isNotEmpty) {
            widgets.add(Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.apartment_rounded, size: 13, color: Colors.grey.shade600),
                  const SizedBox(width: 5),
                  Text(location,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontWeight: FontWeight.w600)),
                ]),
              ),
            ));
          }

          // ── Time cards ────────────────────────────────────────
          widgets.add(Wrap(
            spacing: 10,
            runSpacing: 10,
            children: locSlots.map((slot) {
              final slotId     = slot['id']?.toString() ?? '';
              final time       = slot['time']?.toString() ?? '';
              final obligatory = slot['obligatory']?.toString() ?? '';
              final event      = slot['event']?.toString();
              final repeat     = slot['repeat']?.toString();
              final type       = slot['type']?.toString();
              final isSelected    = templateId != null && templateId == slotId;
              final isObligatory  = obligatory == 'Obligatory';
              final isOneTime     = type == 'one-time';
              final showRepeat    = repeat != null && repeat != 'None' && !isOneTime;

              // ── Availability checks — all from API response ───
              final publishedMass      = _findPublishedMass(language, time);
              final timePassed         = _isTimePassed(publishedMass);
              final alreadyBooked      = _isAlreadyBooked(publishedMass, myBookings);
              final isFullyBooked      = publishedMass?['isFullyBooked'] == true;
              final isWindowOpen       = publishedMass == null
                  ? true  // template-only slot: always open
                  : publishedMass['isBookingWindowOpen'] != false;
              final remaining          = publishedMass?['remaining'] as int?;
              final bookingOpenAt      = publishedMass?['bookingOpenAt'] as int?;
              final isDisabled         = timePassed || alreadyBooked || isFullyBooked || !isWindowOpen;
              final showLowSeats       = !isDisabled && remaining != null && remaining <= 10 && remaining > 0;

              // Opens-on date string for closed-window slots
              String? opensOnLabel;
              if (!isWindowOpen && bookingOpenAt != null && bookingOpenAt > 0) {
                final opensDate = DateTime.fromMillisecondsSinceEpoch(bookingOpenAt).toLocal();
                opensOnLabel = "Opens ${opensDate.day}/${opensDate.month} ${opensDate.hour.toString().padLeft(2,'0')}:${opensDate.minute.toString().padLeft(2,'0')}";
              }

              // Card color based on state priority
              final cardColor = timePassed
                  ? Colors.grey.shade100
                  : isFullyBooked
                      ? Colors.red.shade50
                      : !isWindowOpen
                          ? Colors.orange.shade50
                          : alreadyBooked
                              ? Colors.green.shade50
                              : isSelected
                                  ? lColor
                                  : Colors.white;
              final borderColor = timePassed
                  ? Colors.grey.shade300
                  : isFullyBooked
                      ? Colors.red.shade300
                      : !isWindowOpen
                          ? Colors.orange.shade300
                          : alreadyBooked
                              ? Colors.green.shade300
                              : isSelected
                                  ? lColor
                                  : (isOneTime ? Colors.purple.shade200 : Colors.grey.shade300);
              final textColor = timePassed
                  ? Colors.grey.shade400
                  : isFullyBooked
                      ? Colors.red.shade400
                      : !isWindowOpen
                          ? Colors.orange.shade700
                          : alreadyBooked
                              ? Colors.green.shade700
                              : isSelected
                                  ? Colors.white
                                  : lColor;

              return GestureDetector(
                onTap: isDisabled ? null : () => setState(() => templateId = isSelected ? null : slotId),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  decoration: BoxDecoration(
                    color: cardColor,
                    border: Border.all(color: borderColor, width: isSelected ? 2 : (isOneTime ? 1.5 : 1)),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: isSelected
                        ? [BoxShadow(color: lColor.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4))]
                        : [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(0, 2))],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Already booked badge (Gap 4)
                      if (alreadyBooked)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          margin: const EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(
                            color: Colors.green.shade100,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.check_circle, size: 10, color: Colors.green.shade700),
                            const SizedBox(width: 3),
                            Text('Booked ✓', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.green.shade800)),
                          ]),
                        ),
                      // Fully booked badge (new — from API capacity)
                      if (isFullyBooked && !alreadyBooked)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          margin: const EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(
                            color: Colors.red.shade100,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.block, size: 10, color: Colors.red.shade700),
                            const SizedBox(width: 3),
                            Text('Full', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.red.shade800)),
                          ]),
                        ),
                      // Booking window not yet open badge (new — from API bookingOpenAt)
                      if (!isWindowOpen && !isFullyBooked && !alreadyBooked)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          margin: const EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade100,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.lock_clock, size: 10, color: Colors.orange.shade800),
                            const SizedBox(width: 3),
                            Text(opensOnLabel ?? 'Not open yet',
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.orange.shade900)),
                          ]),
                        ),
                      // Time passed badge (Gap 3)
                      if (timePassed && !alreadyBooked && !isFullyBooked)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          margin: const EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('Passed', style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                        ),
                      if (isOneTime)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          margin: const EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.purple.shade200 : Colors.purple.shade50,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('One-Time',
                              style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold,
                                  color: Colors.purple.shade800, letterSpacing: 0.3)),
                        ),
                      Text(time,
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16,
                              color: textColor, letterSpacing: 0.2,
                              decoration: timePassed ? TextDecoration.lineThrough : null)),
                      if (showRepeat) ...[
                        const SizedBox(height: 3),
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.repeat, size: 10,
                              color: isSelected ? Colors.white60 : Colors.grey.shade400),
                          const SizedBox(width: 3),
                          Text(repeat,
                              style: TextStyle(fontSize: 10,
                                  color: isSelected ? Colors.white60 : Colors.grey.shade400)),
                        ]),
                      ],
                      // Low seats warning (new — from API remaining count)
                      if (showLowSeats) ...[
                        const SizedBox(height: 3),
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.event_seat, size: 10, color: Colors.amber.shade700),
                          const SizedBox(width: 3),
                          Text('$remaining left',
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                                  color: Colors.amber.shade800)),
                        ]),
                      ],
                      if (isObligatory || event != null) ...[
                        const SizedBox(height: 6),
                        Wrap(spacing: 4, runSpacing: 3, children: [
                          if (isObligatory)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isSelected ? Colors.amber.shade300 : Colors.amber.shade100,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text('Obligatory',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold,
                                      color: Colors.amber.shade900)),
                            ),
                          if (event != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isSelected ? Colors.orange.shade300 : Colors.orange.shade100,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.star_rounded, size: 9, color: Colors.orange.shade800),
                                const SizedBox(width: 3),
                                Text(event,
                                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold,
                                        color: Colors.orange.shade900)),
                              ]),
                            ),
                        ]),
                      ],
                    ],
                  ),
                ),
              );
            }).toList(),
          ));
          widgets.add(const SizedBox(height: 10));
        });
      });
    }

    return widgets;
  }

  @override

  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text("Book a Mass",
              style:
                  TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          const Text("1. Select Attendee(s)",
              style: TextStyle(fontWeight: FontWeight.bold)),
          if (s.familyMembers.isEmpty)
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.shade300),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700, size: 22),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      "You need to save your profile first before booking a Mass.\n\nGo to the \"Profiles\" tab and tap \"Add Profile\" to set up your details.",
                      style: TextStyle(fontSize: 13, color: Colors.black87),
                    ),
                  ),
                ],
              ),
            ),
          ...s.familyMembers.map((m) => CheckboxListTile(
              title: Text(m.fullName),
              value: selectedProfiles.contains(m.id),
              onChanged: (v) {
                setState(() {
                  if (v!) {
                    selectedProfiles.add(m.id);
                  } else {
                    selectedProfiles.remove(m.id);
                  }
                });
              })),
          const SizedBox(height: 20),
          const Text("2. Select Date",
              style: TextStyle(fontWeight: FontWeight.bold)),
          if (_flagLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            CalendarDatePicker(
                initialDate: dt,
                firstDate: DateTime.now(),
                // Gap 2: 60-day window matches web default (was hardcoded 30)
                lastDate: DateTime.now().add(const Duration(days: 60)),
                // Gap 1: when allowAnyDay=true, all days selectable (weekday masses)
                //         when false, only Sat/Sun (weekend masses)
                selectableDayPredicate: (DateTime day) {
                  // 1. Basic day of week validation
                  if (!_allowAnyDay && day.weekday != DateTime.saturday && day.weekday != DateTime.sunday) {
                    return false;
                  }
                  // 2. Validate against Mass Availability rules
                  if (_availabilityRules.isEmpty) {
                    return true;
                  }
                  final ymd = DateFormat('yyyy-MM-dd').format(day);
                  bool allowed = false;
                  for (var rule in _availabilityRules) {
                    final start = rule['startDate'] as String;
                    final end = rule['endDate'] as String;
                    if (ymd.compareTo(start) >= 0 && ymd.compareTo(end) <= 0) {
                      allowed = true;
                      break;
                    }
                  }
                  return allowed;
                },
                onDateChanged: (d) {
                  setState(() {
                    dt = d;
                    templateId = null;
                    availableSlots = [];
                    _publishedMasses = [];
                  });
                  _fetchSlots();
                }),
          const SizedBox(height: 20),
          const Text("3. Select Time",
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          // Gap 3 & 4: pass myBookings to enable availability checks
          ..._buildGroupedTimeSlots(availableSlots, s.myBookings),
          const SizedBox(height: 40),
          SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                  onPressed:
                      (selectedProfiles.isNotEmpty && templateId != null)
                          ? () async {
                              final error = await s.bookMass(
                                  selectedProfiles,
                                  DateFormat('yyyy-MM-dd').format(dt),
                                  templateId!);
                              if (error == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text(
                                            "Mass Booked Successfully!")));
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        duration: const Duration(seconds: 4),
                                        backgroundColor: Colors.red,
                                        content: Text(error)));
                              }
                            }
                          : null,
                  child: const Text("Confirm")))
        ]));
  }
}

// ─── MY TICKETS SCREEN ──────────────────────────────────────
class MyListedMassesScreen extends StatelessWidget {
  const MyListedMassesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();

    // FIX #3: show placeholder when list is empty (was silently empty before)
    if (s.myBookings.isEmpty) {
      return const Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.qr_code, size: 64, color: Colors.grey),
        SizedBox(height: 16),
        Text("No tickets yet.",
            style: TextStyle(color: Colors.grey, fontSize: 16)),
        SizedBox(height: 8),
        Text("Book a Mass to see your QR passes here.",
            style: TextStyle(color: Colors.grey, fontSize: 12)),
      ]));
    }

    final sortedBookings = List.of(s.myBookings);
    sortedBookings.sort((a, b) {
      int nameComp = a.profileFullName.toLowerCase().compareTo(b.profileFullName.toLowerCase());
      if (nameComp != 0) return nameComp;
      return b.startDateTime.compareTo(a.startDateTime); // Descending by date
    });

    return ListView.builder(
        padding: const EdgeInsets.all(15),
        itemCount: sortedBookings.length,
        itemBuilder: (c, i) {
          final b = sortedBookings[i];
          return Card(
              margin: const EdgeInsets.only(bottom: 15),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15)),
              child: ExpansionTile(
                leading: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                        border:
                            Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(10)),
                    // FIX #4: use b.qrToken (not b.id) for QR code
                    child: QrImageView(
                        data: b.qrToken,
                        version: QrVersions.auto,
                        size: 50,
                        backgroundColor: Colors.white)),
                title: Text(b.profileFullName,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                subtitle: Text(
                    "${DateFormat('EEEE, dd MMM yyyy').format(b.startDateTime)} — ${b.massLabel}"),
                children: [
                  Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(children: [
                        // FIX #4: full-size QR also uses qrToken
                        QrImageView(
                            data: b.qrToken,
                            version: QrVersions.auto,
                            size: 250,
                            backgroundColor: Colors.white),
                        const SizedBox(height: 10),
                        const Text("Scan at Church Entrance",
                            style: TextStyle(color: Colors.grey)),
                        const SizedBox(height: 4),
                        Text(
                            "Code: ${b.bookingCode}   •   #${b.parishBookingId}",
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey)),
                        const Divider(height: 30),
                        Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceEvenly,
                            children: [
                              // FIX #5: cancelBooking now exists; shows confirm dialog
                              TextButton.icon(
                                  icon: const Icon(Icons.cancel,
                                      color: Colors.red),
                                  label: const Text("Cancel Booking",
                                      style:
                                          TextStyle(color: Colors.red)),
                                  onPressed: () =>
                                      _confirmCancel(c, s, b))
                            ])
                      ]))
                ],
              ));
        });
  }

  void _confirmCancel(BuildContext context, AppState s, MassBooking b) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Cancel Booking"),
        content: Text(
          "Cancel the Mass booking for \"${b.profileFullName}\"?\n\n"
          "This will free the seat so you can rebook on the same day if needed.",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Keep")),
          ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                Navigator.pop(ctx);
                final error = await s.cancelBooking(b.id);
                if (error != null && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(error),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              child: const Text("Cancel Booking")),
        ],
      ),
    );
  }
}

// ─── ADMIN SECTION ──────────────────────────────────────────
class AdminMainScreen extends StatefulWidget {
  const AdminMainScreen({super.key});

  @override
  State<AdminMainScreen> createState() => _AdminMainScreenState();
}

class _AdminMainScreenState extends State<AdminMainScreen> {
  int _idx = 0;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  static const List<String> _titles = ["Live Operations", "Gate Scanner", "App Settings"];

  Widget _buildDrawer(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 56, 20, 28),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF1E3A5F), Color(0xFF2D5F8A)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.admin_panel_settings_rounded, color: Colors.white, size: 30),
                ),
                const SizedBox(height: 14),
                const Text("Admin Tools",
                    style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text("Parish management portal",
                    style: TextStyle(color: Colors.white60, fontSize: 13)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _drawerItem(
            context,
            icon: Icons.category_rounded,
            iconColor: const Color(0xFF1E3A5F),
            iconBg: const Color(0xFFEAF0F8),
            title: "Mass Masters",
            subtitle: "Languages, Locations & Events",
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminMastersScreen()));
            },
          ),
          _drawerItem(
            context,
            icon: Icons.calendar_month_rounded,
            iconColor: Colors.amber.shade800,
            iconBg: Colors.amber.shade50,
            title: "Mass Schedule",
            subtitle: "Manage recurring & one-time templates",
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminScheduleScreen()));
            },
          ),
          _drawerItem(
            context,
            icon: Icons.person_add_rounded,
            iconColor: Colors.green.shade700,
            iconBg: Colors.green.shade50,
            title: "Book for Member",
            subtitle: "Create account & book a Mass",
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminBookForUserScreen()));
            },
          ),
          const Spacer(),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              const Icon(Icons.church_rounded, size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              Text("St. Mary's Catholic Church, Dubai",
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _drawerItem(BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      subtitle: Text(subtitle, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
      trailing: const Icon(Icons.chevron_right, color: Colors.grey),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: _idx == 0 ? _buildDrawer(context) : null,
      appBar: AppBar(
        title: Text(_titles[_idx]),
        backgroundColor: const Color(0xFF1E3A5F),
        foregroundColor: Colors.white,
        leading: _idx == 0
            ? IconButton(
                icon: const Icon(Icons.menu_rounded),
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              )
            : null,
        actions: [
          IconButton(
            onPressed: () => context.read<AppState>().logout(),
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: [
        const AdminDashboardTab(),
        const AdminScannerTab(),
        const AdminSettingsTab(),
      ][_idx],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _idx,
        onDestinationSelected: (i) => setState(() => _idx = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard_rounded),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.qr_code_scanner_outlined),
            selectedIcon: Icon(Icons.qr_code_scanner),
            label: 'Scanner',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class AdminDashboardTab extends StatefulWidget {
  const AdminDashboardTab({super.key});
  @override
  State<AdminDashboardTab> createState() => _AdminDashboardTabState();
}

class _AdminDashboardTabState extends State<AdminDashboardTab> {
  Map<String, dynamic> summary = {"totalVisitors": 0, "totalRejected": 0};
  bool _loadingSummary = true;

  DateTime _selectedDate = DateTime.now();
  List<dynamic> _slotStats = [];
  bool _loadingStats = true;

  @override
  void initState() {
    super.initState();
    _fetchSummary();
    _fetchDetailedStats();
  }

  Future<void> _fetchSummary() async {
    setState(() => _loadingSummary = true);
    try {
      final res = await http.get(
          Uri.parse("${ConvexConfig.baseUrl}/dashboard/summary"),
          headers: ConvexConfig.headers);
      if (res.statusCode == 200) {
        if (mounted) {
          setState(() {
            summary = jsonDecode(res.body)['data'] ?? summary;
            _loadingSummary = false;
          });
        }
      }
    } catch (_) {
      if (mounted) setState(() => _loadingSummary = false);
    }
  }

  Future<void> _fetchDetailedStats() async {
    setState(() => _loadingStats = true);
    final dateStr =
        "${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}";
    try {
      final res = await http.get(
          Uri.parse(
              "${ConvexConfig.baseUrl}/dashboard/stats-by-date?date=$dateStr"),
          headers: ConvexConfig.headers);
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded['ok'] == true && mounted) {
          setState(() {
            _slotStats = decoded['data'] ?? [];
            _loadingStats = false;
          });
        } else if (mounted) {
           setState(() => _loadingStats = false);
        }
      } else {
        if (mounted) setState(() => _loadingStats = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingStats = false);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 60)),
    );
    if (picked != null && picked != _selectedDate) {
      setState(() => _selectedDate = picked);
      _fetchDetailedStats();
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        await _fetchSummary();
        await _fetchDetailedStats();
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Gradient banner ──────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF1E3A5F), Color(0xFF2D5F8A)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      width: 8, height: 8,
                      decoration: const BoxDecoration(
                          color: Colors.greenAccent,
                          shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      "LIVE  •  ${DateFormat('EEEE, d MMM y').format(DateTime.now())}",
                      style: const TextStyle(color: Colors.white70, fontSize: 11, letterSpacing: 1.2),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: () async { await _fetchSummary(); await _fetchDetailedStats(); },
                      child: const Icon(Icons.refresh_rounded, color: Colors.white70, size: 20),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  const Text("Parish Operations",
                      style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text("Real-time attendance & statistics",
                      style: TextStyle(color: Colors.white60, fontSize: 13)),
                ],
              ),
            ),

            // ── KPI Cards ─────────────────────────────────────────
            Transform.translate(
              offset: const Offset(0, -20),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _loadingSummary
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(20),
                          child: CircularProgressIndicator(color: Colors.white),
                        ))
                    : Row(children: [
                        Expanded(child: _kpiCard(
                          "Verified Today",
                          summary['totalVisitors']?.toString() ?? '0',
                          Icons.check_circle_rounded,
                          const Color(0xFF2E7D32),
                          Colors.green.shade50,
                        )),
                        const SizedBox(width: 12),
                        Expanded(child: _kpiCard(
                          "Rejected Today",
                          summary['totalRejected']?.toString() ?? '0',
                          Icons.cancel_rounded,
                          const Color(0xFFC62828),
                          Colors.red.shade50,
                        )),
                      ]),
              ),
            ),

            // ── Statistics Section ────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(children: [
                const Icon(Icons.bar_chart_rounded, color: Color(0xFF1E3A5F), size: 20),
                const SizedBox(width: 8),
                const Text("Mass Statistics",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E3A5F))),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today_rounded, size: 13),
                  label: Text(DateFormat('d MMM y').format(_selectedDate),
                      style: const TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    side: const BorderSide(color: Color(0xFF1E3A5F)),
                    foregroundColor: const Color(0xFF1E3A5F),
                  ),
                ),
              ]),
            ),

            if (_loadingStats)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_slotStats.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Column(children: [
                    Icon(Icons.event_busy_rounded, size: 48, color: Colors.grey.shade300),
                    const SizedBox(height: 12),
                    Text("No mass slots for this date",
                        style: TextStyle(color: Colors.grey.shade500)),
                  ]),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade200),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        headingRowColor: WidgetStateProperty.all(const Color(0xFFF0F4F8)),
                        headingTextStyle: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF1E3A5F)),
                        dataTextStyle: const TextStyle(fontSize: 12),
                        columnSpacing: 20,
                        columns: const [
                          DataColumn(label: Text("Date")),
                          DataColumn(label: Text("Mass")),
                          DataColumn(label: Text("Cap/Eff"), numeric: true),
                          DataColumn(label: Text("Booked"), numeric: true),
                          DataColumn(label: Text("Attended"), numeric: true),
                          DataColumn(label: Text("Cancelled"), numeric: true),
                          DataColumn(label: Text("Expired"), numeric: true),
                          DataColumn(label: Text("No-show"), numeric: true),
                          DataColumn(label: Text("Remaining"), numeric: true),
                          DataColumn(label: Text("Util %"), numeric: true),
                          DataColumn(label: Text("Att. Rate")),
                        ],
                        rows: _slotStats.map((slot) {
                          final counts = slot['counts'] ?? {};
                          final cap = slot['capacity'] ?? 0;
                          final eff = slot['effectiveSeats'] ?? cap;
                          final rem = slot['remainingSeats'] ?? 0;
                          final util = slot['utilizationPercentOfEffective'];
                          final att = slot['attendanceRate'];
                          final utilStr = util != null ? '${util.toStringAsFixed(1)}%' : '—';
                          final attStr = att != null ? '${(att * 100).toStringAsFixed(1)}%' : '—';
                          final booked = counts['booked'] ?? 0;
                          final isNearFull = rem <= 5 && rem > 0;
                          final isFull = booked >= eff && eff > 0;
                          return DataRow(
                            color: WidgetStateProperty.resolveWith((states) {
                              if (isFull) return Colors.red.shade50;
                              if (isNearFull) return Colors.orange.shade50;
                              return null;
                            }),
                            cells: [
                              DataCell(Text(slot['date']?.toString() ?? '')),
                              DataCell(Text(slot['label']?.toString() ?? '',
                                  overflow: TextOverflow.ellipsis)),
                              DataCell(Text('$cap/$eff')),
                              DataCell(Text(booked.toString(),
                                  style: booked > 0
                                      ? const TextStyle(fontWeight: FontWeight.bold)
                                      : null)),
                              DataCell(Text((counts['attended'] ?? 0).toString())),
                              DataCell(Text((counts['cancelled'] ?? 0).toString())),
                              DataCell(Text((counts['expired'] ?? 0).toString())),
                              DataCell(Text((counts['no_show'] ?? 0).toString())),
                              DataCell(Text(rem.toString(),
                                  style: TextStyle(
                                    color: isFull ? Colors.red.shade700
                                        : isNearFull ? Colors.orange.shade700
                                        : Colors.green.shade700,
                                    fontWeight: FontWeight.w600,
                                  ))),
                              DataCell(Text(utilStr)),
                              DataCell(Text(attStr)),
                            ],
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _kpiCard(String label, String value, IconData icon, Color accent, Color bg) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: accent.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: accent, size: 20),
            ),
            Text(value,
                style: TextStyle(
                    fontSize: 32, fontWeight: FontWeight.bold, color: accent)),
          ]),
          const SizedBox(height: 10),
          Text(label,
              style: TextStyle(
                  color: Colors.grey.shade700, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}


class AdminScannerTab extends StatefulWidget {
  const AdminScannerTab({super.key});
  @override
  State<AdminScannerTab> createState() => _AdminScannerTabState();
}

class _AdminScannerTabState extends State<AdminScannerTab> {
  int _mode = 0; // 0 = Camera, 1 = Manual
  String res = "Admin Scanner Ready";
  Color col = Colors.grey;
  bool _isProcessing = false;
  final TextEditingController _manualCtrl = TextEditingController();

  DateTime dt = DateTime.now();
  String? selectedMassSlotId;
  List<dynamic> availableMasses = [];

  @override
  void initState() {
    super.initState();
    _fetchMasses();
  }

  Future<void> _fetchMasses() async {
    try {
      final resp = await http.get(
        Uri.parse("${ConvexConfig.baseUrl}/mass-schedule/times?parishDateYmd=${DateFormat('yyyy-MM-dd').format(dt)}"),
        headers: ConvexConfig.headers,
      );
      if (resp.statusCode == 200) {
        final List<dynamic> rows = jsonDecode(resp.body)['publishedMasses'] ?? [];
        rows.sort((a, b) {
          final dA = DateTime.fromMillisecondsSinceEpoch((a['startDateTime'] as num).toInt());
          final dB = DateTime.fromMillisecondsSinceEpoch((b['startDateTime'] as num).toInt());
          return dA.compareTo(dB);
        });
        setState(() {
          availableMasses = rows;
          // Maintain selection if still valid, otherwise reset
          if (selectedMassSlotId == null && rows.isNotEmpty) {
             selectedMassSlotId = rows.first['_id'];
          } else if (!rows.any((e) => e['_id'] == selectedMassSlotId)) {
             selectedMassSlotId = rows.isNotEmpty ? rows.first['_id'] : null;
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _checkCloud(BuildContext context, String id) async {
    if (selectedMassSlotId == null) return;
    
    final s = context.read<AppState>();
    setState(() { _isProcessing = true; res = "Verifying with Admin Privilege..."; col = Colors.blueAccent; });
    try {
      final resp = await http.post(
          Uri.parse("${ConvexConfig.baseUrl}/scan/admin"), 
          headers: ConvexConfig.headers,
          body: jsonEncode({
            "scannerUserId": s.userId, 
            "token": id,
            "massSlotId": selectedMassSlotId
          }));
      if (resp.statusCode == 200) {
        final out = jsonDecode(resp.body)['result'];
        setState(() {
          if (out['outcome'] == 'success') { res = "ADMIN OVERRIDE: ALLOWED"; col = Colors.green; } 
          else if (out['reason'] == 'already_used') { res = "ALREADY SCANNED"; col = Colors.orange; } 
          else { res = "DENIED: ${out['reason']}"; col = Colors.red; }
        });
      } else { setState(() { res = "NETWORK ERROR"; col = Colors.red; }); }
    } catch (e) { setState(() { res = "ERROR"; col = Colors.red; }); }

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() { _isProcessing = false; res = "Admin Scanner Ready"; col = Colors.grey; });
    });
  }

  @override
  void dispose() {
    _manualCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        color: Colors.white,
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.calendar_today, size: 20, color: Colors.blue),
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: dt,
                        firstDate: DateTime.now().subtract(const Duration(days: 30)),
                        lastDate: DateTime.now().add(const Duration(days: 30)),
                      );
                      if (d != null && d != dt) {
                        setState(() => dt = d);
                        _fetchMasses();
                      }
                    },
                    child: Text(DateFormat('EEEE, MMM d, yyyy').format(dt), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFFF0F2F5),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
              ),
              hint: const Text('Select a Mass...'),
              value: selectedMassSlotId,
              isExpanded: true,
              items: availableMasses.map((m) {
                 final d = DateTime.fromMillisecondsSinceEpoch((m['startDateTime'] as num).toInt());
                 String lbl = m['label']?.toString() ?? "";
                 if (lbl.toLowerCase().contains("weekend mass")) {
                   if (d.weekday == DateTime.saturday) lbl = lbl.replaceAll(RegExp("Weekend Mass", caseSensitive: false), "Saturday Mass");
                   if (d.weekday == DateTime.sunday) lbl = lbl.replaceAll(RegExp("Weekend Mass", caseSensitive: false), "Sunday Mass");
                 }
                 return DropdownMenuItem<String>(
                   value: m['_id'],
                   child: Text("$lbl – ${DateFormat('hh:mm a').format(d)}", overflow: TextOverflow.ellipsis),
                 );
              }).toList(),
              onChanged: (v) {
                setState(() => selectedMassSlotId = v);
              },
            ),
          ],
        )
      ),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton.icon(
            onPressed: () => setState(()=>_mode=0), 
            icon: Icon(Icons.camera_alt, color: _mode==0 ? Colors.blue:Colors.grey),
            label: Text("Live Camera", style: TextStyle(color: _mode==0 ? Colors.blue:Colors.grey))
          ),
          const SizedBox(width: 20),
          TextButton.icon(
            onPressed: () => setState(()=>_mode=1), 
            icon: Icon(Icons.keyboard, color: _mode==1 ? Colors.blue:Colors.grey),
            label: Text("Manual Entry", style: TextStyle(color: _mode==1 ? Colors.blue:Colors.grey))
          ),
        ],
      ),
      Expanded(
        child: selectedMassSlotId == null
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text("Please select a Date and Mass first to begin scanning.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 16)),
                ),
              )
            : _mode == 0 
                ? MobileScanner(onDetect: (c) {
                    if (_isProcessing) return;
                    for (final b in c.barcodes) {
                      if (b.rawValue != null && b.rawValue!.isNotEmpty) { _checkCloud(context, b.rawValue!); break; }
                    }
                  })
                : Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.security, size: 60, color: Colors.blueAccent),
                        const SizedBox(height: 20),
                        TextField(
                          controller: _manualCtrl,
                          decoration: InputDecoration(
                            labelText: "Admin Override Code", 
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(15))
                          ),
                          textCapitalization: TextCapitalization.characters,
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _isProcessing ? null : () {
                              if (_manualCtrl.text.isNotEmpty) {
                                _checkCloud(context, _manualCtrl.text);
                                _manualCtrl.clear();
                              }
                            },
                            style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(15)),
                            child: const Text("Process Admin Check-In")
                          ),
                        )
                      ]
                    )
                  )
      ),
      Container(width: double.infinity, height: 100, color: col, child: Center(child: Text(res, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))))
    ]);
  }
}

class AdminSettingsTab extends StatefulWidget {
  const AdminSettingsTab({super.key});
  @override
  State<AdminSettingsTab> createState() => _AdminSettingsTabState();
}

class _AdminSettingsTabState extends State<AdminSettingsTab> {
  Map<String, dynamic> settings = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchSettings();
  }

  Future<void> _fetchSettings() async {
    try {
      final res = await http.get(Uri.parse("${ConvexConfig.baseUrl}/settings"), headers: ConvexConfig.headers);
      if (res.statusCode == 200) {
        setState(() { settings = jsonDecode(res.body)['data'] ?? {}; _loading = false; });
      }
    } catch (_) { setState(() => _loading = false); }
  }

  Future<void> _updateSetting(String key, bool val) async {
    // Optimistic UI update
    setState(() => settings[key] = val);
    try {
      await http.patch(
        Uri.parse("${ConvexConfig.baseUrl}/settings"),
        headers: ConvexConfig.headers,
        body: jsonEncode({key: val}) // The dynamic key builds the precise JSON payload!
      );
    } catch (e) {
      // Rollback on fail
      setState(() => settings[key] = !val);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text("Global Master Switches", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1E3A5F))),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.red.shade200)),
          child: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.red),
              SizedBox(width: 10),
              Expanded(child: Text("WARNING: Flipping these toggles instantly alters server behavior for ALL users actively on the mobile and web systems.", style: TextStyle(color: Colors.red, fontSize: 12))),
            ],
          ),
        ),
        const SizedBox(height: 30),
        _toggle("allowOneMassPerDay", "Strict 1-Mass-Per-Day Limit", "Prevents parishioners from booking multiple masses on the exact same calendar day."),
        const Divider(),
        _toggle("manualCancellationEnabled", "Allow User Cancellations", "Permits users to manually cancel their bookings via the web portal."),
        const Divider(),
        _toggle("allowAnyDayWeekendScheduleBooking", "Open Weekly Scheduling", "Allows users to book for future weekends on any day of the week, bypassing the Monday unlock rule."),
        const Divider(),
        _toggle("allowFutureMassCheckInForTesting", "Developer Check-in Bypass", "Allows scanners to accept tickets for masses that happen in the future (Testing Only)."),
      ],
    );
  }

  Widget _toggle(String key, String title, String subtitle) {
    final val = settings[key] == true;
    return SwitchListTile(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
      subtitle: Padding(padding: const EdgeInsets.only(top: 4.0), child: Text(subtitle, style: const TextStyle(fontSize: 12))),
      value: val,
      onChanged: (v) => _updateSetting(key, v),
      activeColor: Colors.green,
      inactiveThumbColor: Colors.grey.shade400,
      inactiveTrackColor: Colors.grey.shade200,
    );
  }
}

// ─── ADMIN MASTERS SCREEN ───────────────────────────────────
class AdminMastersScreen extends StatefulWidget {
  const AdminMastersScreen({super.key});
  @override
  State<AdminMastersScreen> createState() => _AdminMastersScreenState();
}

class _AdminMastersScreenState extends State<AdminMastersScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tc;
  final List<String> _types = ['language', 'location', 'event'];
  final List<List<dynamic>> _data = [[], [], []];
  final List<bool> _loading = [true, true, true];

  @override
  void initState() {
    super.initState();
    _tc = TabController(length: 3, vsync: this);
    _fetchAll();
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  Future<void> _fetch(int idx) async {
    if (mounted) setState(() => _loading[idx] = true);
    try {
      final res = await http.get(
        Uri.parse('${ConvexConfig.baseUrl}/admin/masters?type=${_types[idx]}'),
        headers: ConvexConfig.headers,
      );
      if (res.statusCode == 200 && mounted) {
        final body = jsonDecode(res.body);
        if (body['ok'] == true) {
          setState(() {
            _data[idx] = List<dynamic>.from(body['data'] ?? []);
            _loading[idx] = false;
          });
        }
      }
    } catch (_) {
      if (mounted) setState(() => _loading[idx] = false);
    }
  }

  void _fetchAll() { for (int i = 0; i < 3; i++) _fetch(i); }

  Future<void> _upsert(int idx, {String? id, required String name, required bool active, required int order}) async {
    await http.post(
      Uri.parse('${ConvexConfig.baseUrl}/admin/masters'),
      headers: ConvexConfig.headers,
      body: jsonEncode({'type': _types[idx], if (id != null) 'id': id, 'name': name, 'active': active, 'displayOrder': order}),
    );
    _fetch(idx);
  }

  Future<void> _remove(int idx, String id) async {
    await http.delete(
      Uri.parse('${ConvexConfig.baseUrl}/admin/masters'),
      headers: ConvexConfig.headers,
      body: jsonEncode({'type': _types[idx], 'id': id}),
    );
    _fetch(idx);
  }

  void _showDialog(int idx, {Map<String, dynamic>? item}) {
    final nameCtrl = TextEditingController(text: item?['name'] ?? '');
    final orderCtrl = TextEditingController(text: (item?['displayOrder'] ?? _data[idx].length).toString());
    bool active = item?['active'] != false;
    final titles = ['Language', 'Location', 'Event'];
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, ss) => AlertDialog(
        title: Text(item == null ? 'Add ${titles[idx]}' : 'Edit ${titles[idx]}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: orderCtrl, decoration: const InputDecoration(labelText: 'Display Order', border: OutlineInputBorder()), keyboardType: TextInputType.number),
          const SizedBox(height: 4),
          SwitchListTile(title: const Text('Active'), value: active, onChanged: (v) => ss(() => active = v), contentPadding: EdgeInsets.zero),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E3A5F), foregroundColor: Colors.white),
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty) return;
              Navigator.pop(ctx);
              _upsert(idx, id: item?['_id'] as String?, name: nameCtrl.text.trim(), active: active, order: int.tryParse(orderCtrl.text) ?? 0);
            },
            child: const Text('Save'),
          ),
        ],
      )),
    );
  }

  void _confirmDelete(int idx, Map<String, dynamic> item) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete?'),
        content: Text('Remove "${item['name']}"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () { Navigator.pop(ctx); _remove(idx, item['_id'] as String); },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Widget _buildTab(int idx) {
    if (_loading[idx]) return const Center(child: CircularProgressIndicator());
    final items = _data[idx];
    if (items.isEmpty) return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.inbox_rounded, size: 56, color: Colors.grey.shade300),
      const SizedBox(height: 12),
      Text('No items yet. Tap + to add.', style: TextStyle(color: Colors.grey.shade500)),
    ]));
    return RefreshIndicator(
      onRefresh: () => _fetch(idx),
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final item = items[i] as Map<String, dynamic>;
          final active = item['active'] != false;
          return Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2))],
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              leading: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: active ? const Color(0xFF1E3A5F).withOpacity(0.1) : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(child: Text('${item['displayOrder'] ?? 0}',
                    style: TextStyle(fontWeight: FontWeight.bold,
                        color: active ? const Color(0xFF1E3A5F) : Colors.grey))),
              ),
              title: Text(item['name']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: active ? Colors.green.shade50 : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: active ? Colors.green.shade200 : Colors.grey.shade300),
                  ),
                  child: Text(active ? 'Active' : 'Inactive',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          color: active ? Colors.green.shade700 : Colors.grey.shade600)),
                ),
                const SizedBox(width: 4),
                IconButton(icon: const Icon(Icons.edit_rounded, size: 18), color: const Color(0xFF1E3A5F),
                    onPressed: () => _showDialog(idx, item: item)),
                IconButton(icon: const Icon(Icons.delete_rounded, size: 18), color: Colors.red,
                    onPressed: () => _confirmDelete(idx, item)),
              ]),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('Mass Masters'),
        backgroundColor: const Color(0xFF1E3A5F),
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tc,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          indicatorColor: Colors.amber,
          tabs: const [Tab(text: 'Languages'), Tab(text: 'Locations'), Tab(text: 'Events')],
        ),
      ),
      body: TabBarView(controller: _tc, children: [_buildTab(0), _buildTab(1), _buildTab(2)]),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF1E3A5F),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add'),
        onPressed: () => _showDialog(_tc.index),
      ),
    );
  }
}


// ─── ADMIN SCHEDULE SCREEN ──────────────────────────────────
class AdminScheduleScreen extends StatefulWidget {
  const AdminScheduleScreen({super.key});
  @override
  State<AdminScheduleScreen> createState() => _AdminScheduleScreenState();
}

class _AdminScheduleScreenState extends State<AdminScheduleScreen> {
  List<dynamic> _templates = [];
  bool _loading = true;
  List<String> _languages = [], _locations = [], _events = [];

  final _days = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
  final _categories = ['Weekend','Weekday'];
  final _repeats = ['None','Weekly','Monthly'];

  @override
  void initState() { super.initState(); _loadAll(); }

  Future<void> _loadAll() async {
    setState(() => _loading = true);
    await Future.wait([_fetchTemplates(), _fetchMasters()]);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _fetchTemplates() async {
    try {
      final r = await http.get(Uri.parse('${ConvexConfig.baseUrl}/admin/mass-templates'), headers: ConvexConfig.headers);
      if (r.statusCode == 200 && mounted) {
        final b = jsonDecode(r.body);
        if (b['ok'] == true) setState(() => _templates = List<dynamic>.from(b['data'] ?? []));
      }
    } catch (_) {}
  }

  Future<void> _fetchMasters() async {
    for (final type in ['language','location','event']) {
      try {
        final r = await http.get(Uri.parse('${ConvexConfig.baseUrl}/admin/masters?type=$type'), headers: ConvexConfig.headers);
        if (r.statusCode == 200) {
          final b = jsonDecode(r.body);
          if (b['ok'] == true) {
            final names = (List<dynamic>.from(b['data'] ?? [])).map((e) => e['name']?.toString() ?? '').where((s) => s.isNotEmpty).toList();
            if (mounted) setState(() { if (type == 'language') _languages = names; else if (type == 'location') _locations = names; else _events = names; });
          }
        }
      } catch (_) {}
    }
  }

  Future<void> _upsert(Map<String, dynamic> data) async {
    await http.post(Uri.parse('${ConvexConfig.baseUrl}/admin/mass-templates'), headers: ConvexConfig.headers, body: jsonEncode(data));
    _fetchTemplates();
  }

  Future<void> _delete(String id) async {
    await http.delete(Uri.parse('${ConvexConfig.baseUrl}/admin/mass-templates'), headers: ConvexConfig.headers, body: jsonEncode({'id': id}));
    _fetchTemplates();
  }

  void _openSheet({Map<String, dynamic>? item}) {
    String type = item?['type'] ?? 'recurring';
    String day = item?['day'] ?? 'Sunday';
    String date = item?['date'] ?? '';
    String time = item?['time'] ?? '08:00 AM';
    String lang = item?['language'] ?? (_languages.isNotEmpty ? _languages.first : '');
    String loc = item?['location'] ?? (_locations.isNotEmpty ? _locations.first : '');
    String obligatory = item?['obligatory'] ?? 'Non-Obligatory';
    String category = item?['category'] ?? 'Weekend';
    String repeat = item?['repeat'] ?? 'Weekly';
    String? event = item?['event'];
    bool active = item?['active'] != false;
    final timeCtrl = TextEditingController(text: time);
    final dateCtrl = TextEditingController(text: date);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, ss) => Container(
          height: MediaQuery.of(context).size.height * 0.88,
          decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
          child: Column(children: [
            Container(height: 4, width: 48, margin: const EdgeInsets.symmetric(vertical: 12), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2))),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Row(children: [
              Text(item == null ? 'Add Schedule' : 'Edit Schedule', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
            ])),
            const Divider(),
            Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Type toggle
              Row(children: ['recurring','one-time'].map((t) => Expanded(child: Padding(
                padding: EdgeInsets.only(right: t == 'recurring' ? 6 : 0, left: t == 'one-time' ? 6 : 0),
                child: ChoiceChip(label: Text(t == 'recurring' ? '🔁 Recurring' : '📅 One-Time'), selected: type == t,
                  onSelected: (_) => ss(() => type = t),
                  selectedColor: const Color(0xFF1E3A5F), labelStyle: TextStyle(color: type == t ? Colors.white : Colors.black87)),
              ))).toList()),
              const SizedBox(height: 16),
              if (type == 'recurring')
                DropdownButtonFormField<String>(value: _days.contains(day) ? day : _days.first, decoration: const InputDecoration(labelText: 'Day of Week', border: OutlineInputBorder()), items: _days.map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(), onChanged: (v) => ss(() => day = v!))
              else
                TextField(controller: dateCtrl, decoration: const InputDecoration(labelText: 'Date (YYYY-MM-DD)', border: OutlineInputBorder()), onChanged: (v) => date = v),
              const SizedBox(height: 12),
              TextField(controller: timeCtrl, decoration: const InputDecoration(labelText: 'Time (e.g. 08:00 AM)', border: OutlineInputBorder()), onChanged: (v) => time = v),
              const SizedBox(height: 12),
              if (_languages.isNotEmpty)
                DropdownButtonFormField<String>(value: _languages.contains(lang) ? lang : _languages.first, decoration: const InputDecoration(labelText: 'Language', border: OutlineInputBorder()), items: _languages.map((l) => DropdownMenuItem(value: l, child: Text(l))).toList(), onChanged: (v) => ss(() => lang = v!))
              else
                TextField(decoration: const InputDecoration(labelText: 'Language', border: OutlineInputBorder()), onChanged: (v) => lang = v),
              const SizedBox(height: 12),
              if (_locations.isNotEmpty)
                DropdownButtonFormField<String>(value: _locations.contains(loc) ? loc : _locations.first, decoration: const InputDecoration(labelText: 'Location', border: OutlineInputBorder()), items: _locations.map((l) => DropdownMenuItem(value: l, child: Text(l))).toList(), onChanged: (v) => ss(() => loc = v!))
              else
                TextField(decoration: const InputDecoration(labelText: 'Location', border: OutlineInputBorder()), onChanged: (v) => loc = v),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(value: category, decoration: const InputDecoration(labelText: 'Category', border: OutlineInputBorder()), items: _categories.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(), onChanged: (v) => ss(() => category = v!)),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(value: obligatory, decoration: const InputDecoration(labelText: 'Obligatory', border: OutlineInputBorder()), items: ['Obligatory','Non-Obligatory'].map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(), onChanged: (v) => ss(() => obligatory = v!)),
              const SizedBox(height: 12),
              if (type == 'recurring')
                DropdownButtonFormField<String>(value: repeat, decoration: const InputDecoration(labelText: 'Repeat', border: OutlineInputBorder()), items: _repeats.map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(), onChanged: (v) => ss(() => repeat = v!)),
              if (type == 'recurring') const SizedBox(height: 12),
              if (_events.isNotEmpty)
                DropdownButtonFormField<String?>(value: event, decoration: const InputDecoration(labelText: 'Special Event (optional)', border: OutlineInputBorder()),
                  items: [const DropdownMenuItem(value: null, child: Text('None')), ..._events.map((e) => DropdownMenuItem(value: e, child: Text(e)))],
                  onChanged: (v) => ss(() => event = v)),
              const SizedBox(height: 12),
              SwitchListTile(title: const Text('Active'), value: active, onChanged: (v) => ss(() => active = v), contentPadding: EdgeInsets.zero),
            ]))),
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), child: SizedBox(width: double.infinity, child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E3A5F), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
              onPressed: () {
                Navigator.pop(ctx);
                final payload = <String, dynamic>{
                  if (item != null) 'id': item['_id'],
                  'type': type, 'language': lang, 'location': loc,
                  'time': timeCtrl.text.trim(), 'obligatory': obligatory,
                  'category': category, 'active': active,
                  if (type == 'recurring') ...{'day': day, 'repeat': repeat},
                  if (type == 'one-time') ...{'date': dateCtrl.text.trim(), 'repeat': 'None'},
                  if (event != null) 'event': event,
                };
                _upsert(payload);
              },
              child: Text(item == null ? 'Create Schedule' : 'Update Schedule'),
            ))),
          ]),
        ),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> t) {
    final isRecurring = t['type'] == 'recurring';
    final active = t['active'] != false;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
        border: Border.all(color: active ? Colors.grey.shade200 : Colors.grey.shade300)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: isRecurring ? const Color(0xFFF9A825).withOpacity(0.15) : Colors.purple.shade50, borderRadius: BorderRadius.circular(12)),
          child: Icon(isRecurring ? Icons.repeat_rounded : Icons.event_rounded, color: isRecurring ? Colors.amber.shade800 : Colors.purple.shade700, size: 20)),
        title: Text('${t['time'] ?? ''} — ${t['language'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 4),
          Text('${isRecurring ? (t['day'] ?? '') : (t['date'] ?? '')} • ${t['location'] ?? ''}', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
          const SizedBox(height: 4),
          Wrap(spacing: 6, children: [
            _chip(t['category'] ?? '', Colors.blue.shade700, Colors.blue.shade50),
            if (t['obligatory'] == 'Obligatory') _chip('Obligatory', Colors.amber.shade800, Colors.amber.shade50),
            if (!active) _chip('Inactive', Colors.grey, Colors.grey.shade100),
          ]),
        ]),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(icon: const Icon(Icons.edit_rounded, size: 18), color: const Color(0xFF1E3A5F), onPressed: () => _openSheet(item: t)),
          IconButton(icon: const Icon(Icons.delete_rounded, size: 18), color: Colors.red, onPressed: () => showDialog(context: context, builder: (ctx) => AlertDialog(
            title: const Text('Delete Schedule?'),
            content: Text('Remove ${t['time']} ${t['language']} on ${isRecurring ? t['day'] : t['date']}?'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white), onPressed: () { Navigator.pop(ctx); _delete(t['_id'] as String); }, child: const Text('Delete'))],
          ))),
        ]),
      ),
    );
  }

  Widget _chip(String label, Color color, Color bg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
    child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
  );

  @override
  Widget build(BuildContext context) {
    final recurring = _templates.where((t) => t['type'] == 'recurring').toList();
    final oneTime = _templates.where((t) => t['type'] == 'one-time').toList();
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(title: const Text('Mass Schedule'), backgroundColor: const Color(0xFF1E3A5F), foregroundColor: Colors.white),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadAll,
              child: ListView(padding: const EdgeInsets.all(16), children: [
                if (recurring.isNotEmpty) ...[
                  _sectionHeader('🔁 Recurring Masses', recurring.length),
                  ...recurring.map((t) => _buildCard(t as Map<String, dynamic>)),
                  const SizedBox(height: 8),
                ],
                if (oneTime.isNotEmpty) ...[
                  _sectionHeader('📅 One-Time Masses', oneTime.length),
                  ...oneTime.map((t) => _buildCard(t as Map<String, dynamic>)),
                ],
                if (_templates.isEmpty) Center(child: Padding(padding: const EdgeInsets.all(48), child: Column(children: [
                  Icon(Icons.calendar_month_rounded, size: 64, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  Text('No schedules yet.\nTap + to add one.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade500)),
                ]))),
              ]),
            ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF1E3A5F), foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded), label: const Text('Add Schedule'),
        onPressed: _openSheet,
      ),
    );
  }

  Widget _sectionHeader(String title, int count) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      const SizedBox(width: 8),
      Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: const Color(0xFF1E3A5F).withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
        child: Text('$count', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF1E3A5F)))),
    ]),
  );
}

// ─── ADMIN BOOK FOR USER SCREEN ─────────────────────────────
class AdminBookForUserScreen extends StatefulWidget {
  const AdminBookForUserScreen({super.key});
  @override
  State<AdminBookForUserScreen> createState() => _AdminBookForUserScreenState();
}

class _AdminBookForUserScreenState extends State<AdminBookForUserScreen> {
  // Steps: 0=create-user 1=after-create 2=add-family 3=book-mass 4=success
  int _step = 0;
  String? _ownerUserId;
  String _memberName = '', _memberEmail = '', _memberMobile = '';
  bool _isExisting = false;
  List<dynamic> _profiles = [];
  List<dynamic> _slots = [];
  String? _selectedTemplateId;
  DateTime _selectedDate = DateTime.now();
  Set<String> _selectedProfileIds = {};
  bool _allowAnyDay = false;
  List<dynamic> _bookingResults = [];
  bool _loadingSlots = false, _submitting = false;
  String? _bookError;

  // Form controllers
  final _f = GlobalKey<FormState>();
  DateTime? _selectedDob;

  // ── Emirates ID scan state ───────────────────────────────────
  bool _scanning = false;
  String? _scanError;
  File? _scannedImage;
  double? _scanConfidence;

  Future<void> _scanEmiratesId(ImageSource source) async {
    setState(() { _scanning = true; _scanError = null; _scannedImage = null; _scanConfidence = null; });
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        imageQuality: 90,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (picked == null) { setState(() => _scanning = false); return; }

      final imageFile = File(picked.path);
      setState(() => _scannedImage = imageFile);

      final uri = Uri.parse('${ConvexConfig.baseUrl}/extract-id');
      final request = http.MultipartRequest('POST', uri)
        ..headers.addAll({
          'X-Mobile-Auth': 'UIYhkjasd09812ajsdasd143',
        })
        ..files.add(await http.MultipartFile.fromPath('image', imageFile.path));

      final streamed = await request.send();
      final body = await streamed.stream.bytesToString();
      final json = jsonDecode(body) as Map<String, dynamic>;

      if (streamed.statusCode != 200 || json['ok'] != true) {
        setState(() {
          _scanError = json['error']?.toString() ?? 'Could not extract ID details.';
          _scanning = false;
        });
        return;
      }

      final extractedName   = json['name']?.toString() ?? '';
      final extractedDob    = json['dob']?.toString() ?? '';   // YYYY-MM-DD
      final extractedEid    = json['emiratesId']?.toString() ?? ''; // 784-YYYY-XXXXXXX-X
      final confidence      = (json['confidence'] as num?)?.toDouble();

      if (extractedName.isNotEmpty) _nameCtrl.text = extractedName;

      if (extractedDob.isNotEmpty) {
        try { _selectedDob = DateTime.parse(extractedDob); } catch (_) {}
      }

      if (extractedEid.isNotEmpty) {
        final parts = extractedEid.split('-');
        if (parts.length == 4) {
          _eidCtrl.text = '${parts[2]}-${parts[3]}';
        }
      }

      setState(() {
        _scanning = false;
        _scanConfidence = confidence;
      });
    } catch (e) {
      setState(() {
        _scanError = 'Scan failed: ${e.toString()}';
        _scanning = false;
      });
    }
  }

  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _mobileCtrl = TextEditingController();
  final _eidCtrl = TextEditingController();
  final _parishCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  bool _creatingUser = false;
  String? _createError;
  bool _searching = false;
  String? _searchError;

  @override
  void dispose() {
    for (final c in [_nameCtrl,_emailCtrl,_mobileCtrl,_eidCtrl,_parishCtrl,_searchCtrl]) c.dispose();
    super.dispose();
  }

  void _reset() => setState(() {
    _step = 0; _ownerUserId = null; _memberName = ''; _memberEmail = ''; _memberMobile = '';
    _isExisting = false; _profiles = []; _slots = []; _selectedTemplateId = null;
    _selectedDate = DateTime.now(); _selectedProfileIds = {};
    _bookingResults = []; _bookError = null; _createError = null; _searchError = null;
    _selectedDob = null;
    _scanning = false; _scanError = null; _scannedImage = null; _scanConfidence = null;
    for (final c in [_nameCtrl,_emailCtrl,_mobileCtrl,_eidCtrl,_parishCtrl,_searchCtrl]) c.clear();
  });

  Future<void> _createUser() async {
    if (_f.currentState == null || !_f.currentState!.validate()) return;
    if (_selectedDob == null) {
      setState(() => _createError = 'Please select a Date of Birth.');
      return;
    }

    setState(() { _creatingUser = true; _createError = null; });
    try {
      final dobStr = DateFormat('yyyy-MM-dd').format(_selectedDob!);
      final fullEid = '784-${_selectedDob!.year}-${_eidCtrl.text}';

      final r = await http.post(Uri.parse('${ConvexConfig.baseUrl}/admin/create-user'),
        headers: ConvexConfig.headers,
        body: jsonEncode({'fullName': _nameCtrl.text.trim(), 'email': _emailCtrl.text.trim(),
          'mobile': _mobileCtrl.text.trim(), 'dob': dobStr,
          'idNumber': fullEid, 'parishNumber': _parishCtrl.text.trim()}));
      final b = jsonDecode(r.body);
      if (b['ok'] == true && mounted) {
        await _loadProfiles(b['ownerUserId'] as String);
        setState(() { _ownerUserId = b['ownerUserId']; _memberName = _nameCtrl.text.trim();
          _memberEmail = _emailCtrl.text.trim(); _memberMobile = _mobileCtrl.text.trim();
          _isExisting = b['existing'] == true; _step = 1; });
      } else {
        setState(() => _createError = b['error']?.toString() ?? 'Failed to create member.');
      }
    } catch (e) { setState(() => _createError = 'Error: $e'); }
    finally { if (mounted) setState(() => _creatingUser = false); }
  }

  Future<void> _searchMember() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) { setState(() => _searchError = 'Enter mobile or email.'); return; }
    setState(() { _searching = true; _searchError = null; });
    try {
      final r = await http.get(Uri.parse('${ConvexConfig.baseUrl}/admin/find-member?q=${Uri.encodeComponent(q)}'), headers: ConvexConfig.headers);
      final b = jsonDecode(r.body);
      if (b['ok'] == true && b['data'] != null && mounted) {
        final d = b['data'] as Map<String, dynamic>;
        await _loadProfiles(d['ownerUserId'] as String);
        final primary = (_profiles.firstWhere((p) => p['isPrimary'] == true, orElse: () => _profiles.isNotEmpty ? _profiles.first : {}));
        setState(() { _ownerUserId = d['ownerUserId']; _memberName = primary['fullName']?.toString() ?? q;
          _memberEmail = primary['email']?.toString() ?? ''; _memberMobile = primary['mobile']?.toString() ?? '';
          _isExisting = true; _step = 1; });
      } else { setState(() => _searchError = 'No member found for "$q".'); }
    } catch (e) { setState(() => _searchError = 'Search error: $e'); }
    finally { if (mounted) setState(() => _searching = false); }
  }

  Future<void> _loadProfiles(String uid) async {
    final r = await http.get(Uri.parse('${ConvexConfig.baseUrl}/admin/family?ownerUserId=$uid'), headers: ConvexConfig.headers);
    final b = jsonDecode(r.body);
    if (b['ok'] == true && mounted) {
      final ps = List<dynamic>.from(b['data'] ?? []);
      setState(() {
        _profiles = ps;
        final primary = ps.firstWhere((p) => p['isPrimary'] == true, orElse: () => {});
        if (primary['_id'] != null) _selectedProfileIds = {primary['_id'] as String};
      });
    }
  }

  Future<void> _fetchSlots() async {
    setState(() { _loadingSlots = true; _selectedTemplateId = null; });
    final ymd = DateFormat('yyyy-MM-dd').format(_selectedDate);
    try {
      final r = await http.get(Uri.parse('${ConvexConfig.baseUrl}/mass-schedule/times?parishDateYmd=$ymd'), headers: ConvexConfig.headers);
      final b = jsonDecode(r.body);
      if (b['ok'] == true && mounted) {
        final slots = List<dynamic>.from(b['templateTimesForDay'] ?? []);
        slots.sort((a, b) {
          int tm(String s) { try { final p = s.trim().split(RegExp(r'\s+')); final hm = p[0].split(':'); int h = int.parse(hm[0]), m = hm.length > 1 ? int.parse(hm[1]) : 0; final ap = p.length > 1 ? p[1].toUpperCase() : ''; if (ap == 'PM' && h != 12) h += 12; if (ap == 'AM' && h == 12) h = 0; return h * 60 + m; } catch (_) { return 0; } }
          return tm(a['time']?.toString() ?? '').compareTo(tm(b['time']?.toString() ?? ''));
        });
        setState(() { _slots = slots; _allowAnyDay = b['allowAnyDayWeekendScheduleBooking'] == true; });
      }
    } catch (_) {}
    if (mounted) setState(() => _loadingSlots = false);
  }

  Future<void> _confirmBooking() async {
    if (_ownerUserId == null || _selectedTemplateId == null || _selectedProfileIds.isEmpty) return;
    setState(() { _submitting = true; _bookError = null; });
    try {
      final r = await http.post(Uri.parse('${ConvexConfig.baseUrl}/admin/book-for-user'),
        headers: ConvexConfig.headers,
        body: jsonEncode({'ownerUserId': _ownerUserId, 'parishDateYmd': DateFormat('yyyy-MM-dd').format(_selectedDate),
          'templateScheduleEntryId': _selectedTemplateId, 'profileIds': _selectedProfileIds.toList()}));
      final b = jsonDecode(r.body);
      if (b['ok'] == true && mounted) {
        setState(() { _bookingResults = List<dynamic>.from(b['result']?['bookings'] ?? []); _step = 4; });
      } else { setState(() => _bookError = b['error']?.toString() ?? 'Booking failed.'); }
    } catch (e) { setState(() => _bookError = 'Error: $e'); }
    finally { if (mounted) setState(() => _submitting = false); }
  }

  Widget _stepIndicator() {
    final stepIdx = _step == 4 ? 3 : _step == 3 ? 2 : _step >= 1 ? 1 : 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(children: List.generate(4, (i) {
        final active = i <= stepIdx || _step == 4;
        return Expanded(child: Container(
          height: 3,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF1E3A5F) : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(2),
          ),
        ));
      })),
    );
  }

  Widget _memberBanner() => Container(
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.green.shade200)),
    child: Row(children: [
      Container(width: 40, height: 40, decoration: BoxDecoration(color: const Color(0xFF1E3A5F), shape: BoxShape.circle),
        child: Center(child: Text(_memberName.isNotEmpty ? _memberName[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_memberName, style: const TextStyle(fontWeight: FontWeight.bold)),
        if (_memberEmail.isNotEmpty || _memberMobile.isNotEmpty)
          Text([if (_memberEmail.isNotEmpty) _memberEmail, if (_memberMobile.isNotEmpty) _memberMobile].join(' • '), style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
        Text(_isExisting ? 'Existing member' : 'Newly created', style: TextStyle(fontSize: 11, color: Colors.green.shade700, fontWeight: FontWeight.w600)),
      ])),
      TextButton(onPressed: () => setState(() => _step = 0), child: const Text('Change')),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('Book for Member'),
        backgroundColor: const Color(0xFF1E3A5F),
        foregroundColor: Colors.white,
        actions: [if (_step > 0) TextButton(onPressed: _reset, child: const Text('Restart', style: TextStyle(color: Colors.white70)))],
      ),
      body: Column(
        children: [
          _stepIndicator(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_step) {
      case 0: return _buildStep0();
      case 1: return _buildStep1();
      case 2: return _buildStep2();
      case 3: return _buildStep3();
      case 4: return _buildStep4();
      default: return const SizedBox();
    }
  }

  // ── Step 0: Create or find member ──────────────────────────
  Widget _buildStep0() {
    Widget fieldLabel(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 12),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1E3A5F))),
    );

    InputDecoration inputStyle({String? hint, Color? fill}) => InputDecoration(
      hintText: hint, filled: true, fillColor: fill ?? Colors.grey.shade50,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: const Color(0xFF1E3A5F), width: 1.5)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.red.shade300)),
      disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _f,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sectionCard('Member Information', Icons.person_add_rounded, children: [
            if (_createError != null) _errorBox(_createError!),
            
            // ── Scanning UI ──────────────────────────────────────────────
            Container(
              decoration: BoxDecoration(color: const Color(0xFFEEF2FF), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFBFCBF5))),
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Row(children: [
                  Icon(Icons.credit_card, color: Color(0xFF1E3A5F), size: 18), SizedBox(width: 8),
                  Text('Scan Emirates ID (optional)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1E3A5F))),
                ]),
                const SizedBox(height: 4),
                const Text('Take a photo or upload the front of the Emirates ID to auto-fill details.', style: TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 10),
                if (!_scanning) Row(children: [
                  Expanded(child: OutlinedButton.icon(
                    icon: const Icon(Icons.camera_alt, size: 16), label: const Text('Camera', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF1E3A5F), side: const BorderSide(color: Color(0xFF1E3A5F)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(vertical: 10)),
                    onPressed: () => _scanEmiratesId(ImageSource.camera),
                  )),
                  const SizedBox(width: 10),
                  Expanded(child: OutlinedButton.icon(
                    icon: const Icon(Icons.photo_library, size: 16), label: const Text('Gallery', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF1E3A5F), side: const BorderSide(color: Color(0xFF1E3A5F)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(vertical: 10)),
                    onPressed: () => _scanEmiratesId(ImageSource.gallery),
                  )),
                ]),
                if (_scanning) const Row(children: [
                  SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 10),
                  Text('Extracting details…', style: TextStyle(fontSize: 13, color: Color(0xFF1E3A5F))),
                ]),
                if (_scannedImage != null && !_scanning) ...[
                  const SizedBox(height: 8),
                  ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.file(_scannedImage!, height: 120, fit: BoxFit.cover, width: double.infinity)),
                ],
                if (_scanConfidence != null && !_scanning) ...[
                  const SizedBox(height: 6),
                  Row(children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 14), const SizedBox(width: 4),
                    Text('Auto-filled with ${(_scanConfidence! * 100).toStringAsFixed(0)}% confidence.', style: const TextStyle(fontSize: 11, color: Colors.green)),
                  ]),
                ],
                if (_scanError != null) ...[
                  const SizedBox(height: 6),
                  Row(children: [
                    const Icon(Icons.warning_amber, color: Colors.red, size: 14), const SizedBox(width: 4),
                    Expanded(child: Text(_scanError!, style: const TextStyle(fontSize: 11, color: Colors.red))),
                  ]),
                ],
              ]),
            ),
            const SizedBox(height: 10),
            
            fieldLabel("Full Name *"),
            TextFormField(controller: _nameCtrl, decoration: inputStyle(hint: "Enter full name"), validator: (v) => v == null || v.isEmpty ? "Required field" : null),
            
            fieldLabel("Email"),
            TextFormField(controller: _emailCtrl, keyboardType: TextInputType.emailAddress, decoration: inputStyle(hint: "Enter email"), validator: (v) {
              if (v == null || v.isEmpty) return null;
              return RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(v) ? null : "Invalid email address";
            }),
            
            fieldLabel("Mobile Number (+971...) *"),
            TextFormField(controller: _mobileCtrl, keyboardType: TextInputType.phone, decoration: inputStyle(hint: "+9715..."), validator: (v) {
              if (v == null || v.isEmpty) return "Required field";
              return RegExp(r'^\+9715[0-9]{8}$').hasMatch(v) ? null : "Must be in format +9715XXXXXXXX";
            }),
            
            fieldLabel("Date of Birth *"),
            InkWell(
              onTap: () async {
                final dt = await showDatePicker(context: context, initialDate: _selectedDob ?? DateTime(2000), firstDate: DateTime(1920), lastDate: DateTime.now());
                if (dt != null) setState(() => _selectedDob = dt);
              },
              borderRadius: BorderRadius.circular(12),
              child: InputDecorator(
                decoration: inputStyle(fill: Colors.grey.shade50).copyWith(
                  errorText: (_selectedDob == null && _f.currentState != null && !(_f.currentState!.validate())) ? "Please select a date" : null,
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(_selectedDob == null ? "Select Date" : DateFormat('dd/MM/yyyy').format(_selectedDob!), style: TextStyle(color: _selectedDob == null ? Colors.grey.shade600 : Colors.black87, fontSize: 16)),
                  Icon(Icons.calendar_month, color: Colors.grey.shade600),
                ]),
              ),
            ),
            
            fieldLabel("Emirates ID *"),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 3, child: TextFormField(key: ValueKey(_selectedDob?.year), initialValue: "784-${_selectedDob?.year ?? 'YYYY'}-", enabled: false, decoration: inputStyle(fill: Colors.grey.shade200))),
              const SizedBox(width: 12),
              Expanded(flex: 5, child: TextFormField(
                controller: _eidCtrl, decoration: inputStyle(hint: "1234567-1"), keyboardType: TextInputType.number, maxLength: 9,
                validator: (v) => RegExp(r'^[0-9]{7}-[0-9]{1}$').hasMatch(v ?? "") ? null : "Must be XXXXXXX-X",
                onChanged: (v) {
                  if (v.length == 7 && !v.contains("-")) { _eidCtrl.text = "$v-"; _eidCtrl.selection = TextSelection.fromPosition(TextPosition(offset: _eidCtrl.text.length)); }
                },
              )),
            ]),
            
            fieldLabel("Parish Number (optional)"),
            TextFormField(controller: _parishCtrl, textCapitalization: TextCapitalization.characters, decoration: inputStyle(hint: "e.g. envelope or register number")),
            
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E3A5F), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: _creatingUser ? null : _createUser,
              child: _creatingUser ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Text('Create & Continue to Booking'),
            )),
          ]),
          const SizedBox(height: 16),
          _sectionCard('Or Find Existing Member', Icons.search_rounded, children: [
            if (_searchError != null) _errorBox(_searchError!),
            Text('Search by mobile number or email address.', style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: TextField(controller: _searchCtrl, decoration: const InputDecoration(hintText: 'Mobile or email…', border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12)))),
              const SizedBox(width: 10),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.grey.shade800, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18)),
                onPressed: _searching ? null : _searchMember,
                child: _searching ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Text('Search'),
              ),
            ]),
          ]),
        ]),
      ),
    );
  }

  // ── Step 1: After create — two options ─────────────────────
  Widget _buildStep1() => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: Column(children: [
      _memberBanner(),
      Row(children: [
        Expanded(child: _optionCard(icon: Icons.family_restroom_rounded, color: Colors.blue.shade700, bg: Colors.blue.shade50,
          title: 'Add Family Member', subtitle: 'Add dependents before booking',
          onTap: () => setState(() => _step = 2))),
        const SizedBox(width: 12),
        Expanded(child: _optionCard(icon: Icons.event_seat_rounded, color: Colors.green.shade700, bg: Colors.green.shade50,
          title: 'Proceed to Booking', subtitle: 'Go straight to Mass selection',
          onTap: () { _fetchSlots(); setState(() => _step = 3); })),
      ]),
    ]),
  );

  // ── Step 2: Family profiles ─────────────────────────────────
  Widget _buildStep2() => Column(children: [
    _memberBanner(),
    Expanded(child: _profiles.isEmpty
      ? Center(child: Text('No profiles found.', style: TextStyle(color: Colors.grey.shade500)))
      : ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _profiles.length,
          itemBuilder: (_, i) {
            final p = _profiles[i] as Map<String, dynamic>;
            return Card(margin: const EdgeInsets.only(bottom: 8), child: ListTile(
              leading: CircleAvatar(backgroundColor: const Color(0xFF1E3A5F), child: Text((p['fullName']?.toString() ?? '?')[0].toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 14))),
              title: Text('${p['fullName'] ?? ''} ${p['isPrimary'] == true ? '(Primary)' : ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(p['relation']?.toString() ?? ''),
            ));
          })),
    Padding(padding: const EdgeInsets.all(16), child: Row(children: [
      Expanded(child: OutlinedButton(onPressed: () => setState(() => _step = 1), child: const Text('Back'))),
      const SizedBox(width: 12),
      Expanded(child: ElevatedButton(
        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E3A5F), foregroundColor: Colors.white),
        onPressed: () { _fetchSlots(); setState(() => _step = 3); },
        child: const Text('Proceed to Booking'),
      )),
    ])),
  ]);

  // ── Step 3: Book mass ───────────────────────────────────────
  Widget _buildStep3() => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _memberBanner(),
      if (_bookError != null) _errorBox(_bookError!),
      _sectionCard('Select Date', Icons.calendar_today_rounded, children: [
        CalendarDatePicker(
          initialDate: _selectedDate, firstDate: DateTime.now(),
          lastDate: DateTime.now().add(const Duration(days: 60)),
          selectableDayPredicate: _allowAnyDay ? null : (d) => d.weekday == DateTime.saturday || d.weekday == DateTime.sunday,
          onDateChanged: (d) { setState(() { _selectedDate = d; _selectedTemplateId = null; _slots = []; }); _fetchSlots(); }),
      ]),
      const SizedBox(height: 16),
      _sectionCard('Select Mass Time', Icons.access_time_rounded, children: [
        if (_loadingSlots) const Center(child: CircularProgressIndicator())
        else if (_slots.isEmpty) Text('No masses on this date.', style: TextStyle(color: Colors.grey.shade500))
        else Wrap(spacing: 10, runSpacing: 10, children: _slots.map((s) {
          final id = s['_id']?.toString() ?? s['id']?.toString() ?? '';
          final time = s['time']?.toString() ?? '';
          final lang = s['language']?.toString() ?? '';
          final selected = _selectedTemplateId == id;
          return GestureDetector(
            onTap: () => setState(() => _selectedTemplateId = id),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: selected ? const Color(0xFF1E3A5F) : Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: selected ? const Color(0xFF1E3A5F) : Colors.grey.shade300),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4)]),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(time, style: TextStyle(fontWeight: FontWeight.bold, color: selected ? Colors.white : Colors.black87)),
                Text(lang, style: TextStyle(fontSize: 11, color: selected ? Colors.white70 : Colors.grey)),
              ]),
            ),
          );
        }).toList()),
      ]),
      const SizedBox(height: 16),
      _sectionCard('Select Attendees', Icons.people_rounded, children: [
        ..._profiles.map((p) {
          final id = p['_id']?.toString() ?? '';
          final checked = _selectedProfileIds.contains(id);
          return CheckboxListTile(
            value: checked, contentPadding: EdgeInsets.zero,
            title: Text('${p['fullName'] ?? ''} ${p['isPrimary'] == true ? '(Primary)' : ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(p['relation']?.toString() ?? ''),
            onChanged: (v) => setState(() { if (v == true) _selectedProfileIds.add(id); else _selectedProfileIds.remove(id); }),
          );
        }),
      ]),
      const SizedBox(height: 20),
      SizedBox(width: double.infinity, child: ElevatedButton(
        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E3A5F), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
        onPressed: (_selectedTemplateId != null && _selectedProfileIds.isNotEmpty && !_submitting) ? _confirmBooking : null,
        child: _submitting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Text('Confirm Booking', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      )),
      const SizedBox(height: 32),
    ]),
  );

  // ── Step 4: Success ─────────────────────────────────────────
  Widget _buildStep4() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(width: 80, height: 80, decoration: BoxDecoration(color: Colors.green.shade50, shape: BoxShape.circle),
          child: Icon(Icons.check_circle_rounded, size: 56, color: Colors.green.shade600)),
        const SizedBox(height: 24),
        const Text('Booking Confirmed!', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Mass booked for ${_memberName}', style: TextStyle(color: Colors.grey.shade600)),
        const SizedBox(height: 24),
        ..._bookingResults.map((b) => Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.green.shade200)),
          child: Row(children: [
            const Icon(Icons.qr_code_rounded, color: Color(0xFF1E3A5F), size: 28),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(b['fullName']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
              Text('Code: ${b['bookingCode'] ?? ''}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ])),
          ]),
        )),
        const SizedBox(height: 32),
        SizedBox(width: double.infinity, child: ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E3A5F), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
          onPressed: _reset,
          child: const Text('Book for Another Member'),
        )),
      ]),
    ),
  );

  // ── Helpers ─────────────────────────────────────────────────
  Widget _sectionCard(String title, IconData icon, {required List<Widget> children}) => Container(
    width: double.infinity, margin: const EdgeInsets.only(bottom: 0),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 3))]),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Icon(icon, size: 18, color: const Color(0xFF1E3A5F)), const SizedBox(width: 8), Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF1E3A5F)))]),
      const SizedBox(height: 14),
      ...children,
    ]),
  );

  Widget _optionCard({required IconData icon, required Color color, required Color bg, required String title, required String subtitle, required VoidCallback onTap}) =>
    GestureDetector(onTap: onTap, child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8)], border: Border.all(color: Colors.grey.shade200)),
      child: Column(children: [
        Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: bg, shape: BoxShape.circle), child: Icon(icon, color: color, size: 24)),
        const SizedBox(height: 10),
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13), textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text(subtitle, style: TextStyle(color: Colors.grey.shade600, fontSize: 11), textAlign: TextAlign.center),
      ]),
    ));

  Widget _field(TextEditingController ctrl, String label, {TextInputType? type, bool required = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(controller: ctrl, keyboardType: type, decoration: InputDecoration(
      labelText: required ? '$label *' : label, border: const OutlineInputBorder(),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14))));

  Widget _errorBox(String msg) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red.shade200)),
    child: Text(msg, style: TextStyle(color: Colors.red.shade800, fontSize: 13)));
}

// ─── VOLUNTEER SECTION ──────────────────────────────────────
class VolunteerMainScreen extends StatefulWidget {
  const VolunteerMainScreen({super.key});

  @override
  State<VolunteerMainScreen> createState() => _VolunteerMainScreenState();
}

class _VolunteerMainScreenState extends State<VolunteerMainScreen> {
  int _idx = 0;
  String res = "Ready to scan or enter code";
  String resSubtitle = "";
  Color col = Colors.grey;
  bool _isProcessing = false;
  final TextEditingController _manualCtrl = TextEditingController();

  DateTime dt = DateTime.now();
  String? selectedMassSlotId;
  List<dynamic> availableMasses = [];

  @override
  void initState() {
    super.initState();
    _fetchMasses();
  }

  Future<void> _fetchMasses() async {
    try {
      final resp = await http.get(
        Uri.parse("${ConvexConfig.baseUrl}/mass-schedule/times?parishDateYmd=${DateFormat('yyyy-MM-dd').format(dt)}"),
        headers: ConvexConfig.headers,
      );
      if (resp.statusCode == 200) {
        final List<dynamic> rows = jsonDecode(resp.body)['publishedMasses'] ?? [];
        rows.sort((a, b) {
          final dA = DateTime.fromMillisecondsSinceEpoch((a['startDateTime'] as num).toInt());
          final dB = DateTime.fromMillisecondsSinceEpoch((b['startDateTime'] as num).toInt());
          return dA.compareTo(dB);
        });
        setState(() {
          availableMasses = rows;
          if (selectedMassSlotId == null && rows.isNotEmpty) {
             selectedMassSlotId = rows.first['_id'];
          } else if (!rows.any((e) => e['_id'] == selectedMassSlotId)) {
             selectedMassSlotId = rows.isNotEmpty ? rows.first['_id'] : null;
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _checkCloud(BuildContext context, String id) async {
    if (selectedMassSlotId == null) return;
    
    final s = context.read<AppState>();
    
    setState(() {
      _isProcessing = true;
      res = "Verifying...";
      resSubtitle = "";
      col = Colors.blueAccent;
    });

    String outcomeLog = "UNKNOWN";

    try {
      final resp = await http.post(
          Uri.parse("${ConvexConfig.baseUrl}/scan/volunteer"),
          headers: ConvexConfig.headers,
          body: jsonEncode({
            "scannerUserId": s.userId, 
            "token": id,
            "massSlotId": selectedMassSlotId
          }));
          
      if (resp.statusCode == 200) {
        final out = jsonDecode(resp.body)['result'];
        setState(() {
          if (out['outcome'] == 'success') {
            res = "ENTRY ALLOWED";
            col = Colors.green;
            outcomeLog = "ALLOWED";
          } else if (out['reason'] == 'already_used') {
            res = "ALREADY SCANNED";
            col = Colors.orange;
            outcomeLog = "ALREADY USED";
          } else {
            res = "ENTRY NOT ALLOWED";
            resSubtitle = "Hint: DENIED (${out['reason']})";
            col = Colors.red;
            outcomeLog = "DENIED";
          }
        });
      } else {
        setState(() {
          res = "NETWORK ERROR";
          col = Colors.red;
          outcomeLog = "ERROR";
        });
      }
    } catch (e) {
      setState(() {
        res = "ERROR";
        col = Colors.red;
        outcomeLog = "ERROR";
      });
    }

    // Log to AppState history
    final nowTime = DateFormat('hh:mm:ss a').format(DateTime.now());
    await s.logScan(id, outcomeLog, nowTime);

    // Cooldown timer
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          res = "Ready";
          resSubtitle = "";
          col = Colors.grey;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
      final s = context.watch<AppState>();

      Widget activeTab;
      if (selectedMassSlotId == null && _idx != 2) {
         activeTab = const Center(
           child: Padding(
             padding: EdgeInsets.all(20),
             child: Text("Please select a Date and Mass above to begin scanning.",
                 textAlign: TextAlign.center,
                 style: TextStyle(color: Colors.grey, fontSize: 16)),
           ),
         );
      } else if (_idx == 0) {
         activeTab = MobileScanner(onDetect: (c) {
              if (_isProcessing) return;
              for (final b in c.barcodes) {
                if (b.rawValue != null && b.rawValue!.isNotEmpty) {
                  _checkCloud(context, b.rawValue!);
                  break; 
                }
              }
            });
      } else if (_idx == 1) {
         activeTab = Padding(
           padding: const EdgeInsets.all(20),
           child: Column(
             mainAxisAlignment: MainAxisAlignment.center,
             children: [
               const Icon(Icons.keyboard, size: 60, color: Colors.grey),
               const SizedBox(height: 20),
               TextField(
                 controller: _manualCtrl,
                 decoration: InputDecoration(
                   labelText: "Manual Code (e.g., D2CMGGU39Z)",
                   border: OutlineInputBorder(borderRadius: BorderRadius.circular(15))
                 ),
                 textCapitalization: TextCapitalization.characters,
               ),
               const SizedBox(height: 20),
               SizedBox(
                 width: double.infinity,
                 child: ElevatedButton(
                   onPressed: _isProcessing ? null : () {
                     if (_manualCtrl.text.isNotEmpty) {
                       _checkCloud(context, _manualCtrl.text);
                       _manualCtrl.clear();
                     }
                   },
                   style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(15)),
                   child: const Text("Verify Entry")
                 )
               )
             ]
           )
         );
      } else {
         activeTab = s.localScanHistory.isEmpty 
           ? const Center(child: Text("No scans yet this session.", style: TextStyle(color: Colors.grey)))
           : ListView.builder(
               itemCount: s.localScanHistory.length,
               itemBuilder: (ctx, i) {
                 final item = s.localScanHistory[i];
                 final isAllowed = item['status'] == 'ALLOWED';
                 return ListTile(
                   leading: Icon(isAllowed ? Icons.check_circle : Icons.cancel, color: isAllowed ? Colors.green : Colors.red),
                   title: Text(item['code'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
                   subtitle: Text(item['time'] ?? ''),
                   trailing: Text(item['status'] ?? '', style: TextStyle(color: isAllowed ? Colors.green : Colors.red, fontWeight: FontWeight.bold)),
                 );
               }
             );
      }

      return Scaffold(
        appBar: AppBar(
            title: const Text("Volunteer Hub"),
            actions: [
              IconButton(onPressed: () => context.read<AppState>().logout(), icon: const Icon(Icons.logout))
            ]),
        body: Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            color: Colors.white,
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.calendar_today, size: 20, color: Colors.blue),
                    const SizedBox(width: 10),
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final d = await showDatePicker(
                            context: context,
                            initialDate: dt,
                            firstDate: DateTime.now().subtract(const Duration(days: 30)),
                            lastDate: DateTime.now().add(const Duration(days: 30)),
                          );
                          if (d != null && d != dt) {
                            setState(() => dt = d);
                            _fetchMasses();
                          }
                        },
                        child: Text(DateFormat('EEEE, MMM d, yyyy').format(dt), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFFF0F2F5),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                  ),
                  hint: const Text('Select a Mass...'),
                  value: selectedMassSlotId,
                  isExpanded: true,
                  items: availableMasses.map((m) {
                     final d = DateTime.fromMillisecondsSinceEpoch((m['startDateTime'] as num).toInt());
                     String lbl = m['label']?.toString() ?? "";
                     if (lbl.toLowerCase().contains("weekend mass")) {
                       if (d.weekday == DateTime.saturday) lbl = lbl.replaceAll(RegExp("Weekend Mass", caseSensitive: false), "Saturday Mass");
                       if (d.weekday == DateTime.sunday) lbl = lbl.replaceAll(RegExp("Weekend Mass", caseSensitive: false), "Sunday Mass");
                     }
                     return DropdownMenuItem<String>(
                       value: m['_id'],
                       child: Text("$lbl – ${DateFormat('hh:mm a').format(d)}", overflow: TextOverflow.ellipsis),
                     );
                  }).toList(),
                  onChanged: (v) {
                    setState(() => selectedMassSlotId = v);
                  },
                ),
              ],
            )
          ),
          Expanded(child: activeTab),
          if (_idx != 2) // Hide dynamic status panel on History tab
            Container(
                width: double.infinity,
                height: 100,
                color: col,
                child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(res, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                        if (resSubtitle.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4.0),
                            child: Text(resSubtitle, style: const TextStyle(color: Colors.white70, fontSize: 13, fontStyle: FontStyle.italic)),
                          )
                      ],
                    )
                ))
        ]),
        bottomNavigationBar: NavigationBar(
            selectedIndex: _idx,
            onDestinationSelected: (i) => setState(() => _idx = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.qr_code_scanner), label: 'Scanner'),
              NavigationDestination(icon: Icon(Icons.keyboard), label: 'Manual'),
              NavigationDestination(icon: Icon(Icons.history), label: 'History'),
            ]),
      );
  }
}

class PlaceholderScreen extends StatelessWidget {
  final String title;
  const PlaceholderScreen({super.key, required this.title});

  @override
  Widget build(BuildContext context) => Center(child: Text(title));
}
