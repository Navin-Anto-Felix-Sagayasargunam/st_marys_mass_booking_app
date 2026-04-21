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
        serverClientId:
            '299520186917-hsrup359ckb81ud1g565o2kh83oa3boa.apps.googleusercontent.com',
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
  DateTime dt = (DateTime.now().weekday == DateTime.saturday || DateTime.now().weekday == DateTime.sunday) ? DateTime.now() : DateTime.now().add(Duration(days: 6 - DateTime.now().weekday));
  String? tm;
  String? templateId;
  List<String> selectedProfiles = [];
  List<dynamic> availableSlots = [];

  @override
  void initState() {
    super.initState();
    _fetchSlots();
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
    if (res.statusCode == 200) {
      setState(() {
        final List<dynamic> slots = jsonDecode(res.body)['templateTimesForDay'] ?? [];
        slots.sort((a, b) => _timeToMinutes(a['time']?.toString() ?? '')
            .compareTo(_timeToMinutes(b['time']?.toString() ?? '')));
        availableSlots = slots;
      });
    }
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
          CalendarDatePicker(
              initialDate: dt,
              firstDate: DateTime.now(),
              lastDate: DateTime.now().add(const Duration(days: 30)),
              selectableDayPredicate: (DateTime day) {
                // 1. Only Sat/Sun allowed
                if (day.weekday != DateTime.saturday && day.weekday != DateTime.sunday) {
                  return false;
                }
                
                // 2. Determine the exact Monday before this targeted weekend
                final openingMonday = day.subtract(Duration(days: day.weekday - 1));
                
                // 3. Only unlock if today is on/after that specific Monday
                final now = DateTime.now();
                final today = DateTime(now.year, now.month, now.day);
                final openingMondayDate = DateTime(openingMonday.year, openingMonday.month, openingMonday.day);
                
                return !today.isBefore(openingMondayDate);
              },
              onDateChanged: (d) {
                setState(() {
                  dt = d;
                  tm = null;
                });
                _fetchSlots();
              }),
          const SizedBox(height: 20),
          const Text("3. Select Time",
              style: TextStyle(fontWeight: FontWeight.bold)),
          Wrap(
              spacing: 8,
              children: availableSlots
                  .map((slot) => ChoiceChip(
                      label: Text(slot['time']?.toString() ?? ''),
                      selected: templateId != null && templateId == slot['id']?.toString(),
                      onSelected: (sel) => setState(
                          () => templateId = sel ? slot['id']?.toString() : null)))
                  .toList()),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const Text("Admin Mission Control"),
          backgroundColor: const Color(0xFF1E3A5F),
          foregroundColor: Colors.white,
          actions: [
            IconButton(
                onPressed: () => context.read<AppState>().logout(),
                icon: const Icon(Icons.logout))
          ]),
      body: [
        const AdminDashboardTab(),
        const AdminScannerTab(),
        const AdminSettingsTab(),
      ][_idx],
      bottomNavigationBar: NavigationBar(
          selectedIndex: _idx,
          onDestinationSelected: (i) => setState(() => _idx = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.dashboard), label: 'Dashboard'),
            NavigationDestination(icon: Icon(Icons.qr_code_scanner), label: 'Gate Scan'),
            NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
          ]),
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
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Live Operations",
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            if (_loadingSummary)
              const Center(child: CircularProgressIndicator())
            else
              Row(children: [
                Expanded(
                    child: _statCard("Total Verified\nVisitors",
                        summary['totalVisitors'].toString(), Colors.green)),
                const SizedBox(width: 15),
                Expanded(
                    child: _statCard("Total Rejected\nAttempts",
                        summary['totalRejected'].toString(), Colors.red)),
              ]),
            const SizedBox(height: 40),
            
            // STATS TABLE SECTION
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Mass Statistics",
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                TextButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: Text(
                      "${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}"),
                )
              ],
            ),
            const SizedBox(height: 10),
            if (_loadingStats)
              const Padding(
                padding: EdgeInsets.all(20.0),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_slotStats.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20.0),
                child: Center(
                    child: Text("No mass slots found for this date.",
                        style: TextStyle(color: Colors.grey))),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowColor:
                      WidgetStateProperty.all(Colors.grey.shade100),
                  columns: const [
                    DataColumn(label: Text("Date")),
                    DataColumn(label: Text("Mass")),
                    DataColumn(label: Text("Booked")),
                    DataColumn(label: Text("Accepted")),
                    DataColumn(label: Text("Cancelled")),
                    DataColumn(label: Text("Rejected")),
                  ],
                  rows: _slotStats.map((slot) {
                    final counts = slot['counts'] ?? {};
                    return DataRow(cells: [
                      DataCell(Text(slot['date'].toString())),
                      DataCell(Text(slot['label'].toString())),
                      DataCell(Text(counts['booked']?.toString() ?? '0')),
                      DataCell(Text(counts['attended']?.toString() ?? '0')),
                      DataCell(Text(counts['cancelled']?.toString() ?? '0')),
                      DataCell(Text(((counts['expired'] ?? 0) +
                              (counts['no_show'] ?? 0))
                          .toString())),
                    ]);
                  }).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statCard(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: color.withOpacity(0.5))),
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 36, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 10),
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600)),
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
