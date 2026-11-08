import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'player_core.dart';
import 'youtube_resolver.dart';

// ألوان الويب (index.html)
const accent = Color(0xFFE74C3C);
const _itemExtent = 56.0; // ارتفاع كرت القناة + المسافة

// =====================================================================
//  القنوات: نفس صيغة الويب (سطر للاسم وتحته سطر للرابط)
// =====================================================================

class Channel {
  final String name;
  final String url;
  final String? group; // عنوان القسم (للقنوات التلقائية فقط)
  final String? logo; // رابط شعار القناة (إن وُجد)
  Channel(this.name, this.url, [this.group, this.logo]);
}

/// مكان ملف القنوات على GitHub (عدّل اسم الحساب/الريبو إذا اختلف).
const repoRawBase = 'https://raw.githubusercontent.com/afm80/box/main';

Future<String?> _fetchRemote(String url) async {
  try {
    final uri = Uri.parse(url).replace(queryParameters: {
      't': DateTime.now().millisecondsSinceEpoch.toString(),
    });
    final r = await http.get(uri).timeout(const Duration(seconds: 8));
    if (r.statusCode == 200) return utf8.decode(r.bodyBytes);
  } catch (_) {}
  return null;
}

List<Channel> parseChannelsText(String text) {
  final lines = text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  final out = <Channel>[];
  for (var i = 0; i + 1 < lines.length; i += 2) {
    out.add(Channel(lines[i], lines[i + 1]));
  }
  return out;
}

Future<String?> _cacheGet(String key) async {
  try {
    return (await SharedPreferences.getInstance()).getString(key);
  } catch (_) {
    return null;
  }
}

Future<void> _cacheSet(String key, String value) async {
  try {
    await (await SharedPreferences.getInstance()).setString(key, value);
  } catch (_) {}
}

List<Channel> parseAutoChannels(String text) {
  try {
    final list = jsonDecode(text) as List;
    return list
        .map((e) {
          final lg = e['logo']?.toString();
          return Channel(
              '${e['name']}',
              '${e['url']}',
              e['group']?.toString() ?? 'قنوات إضافية (تحديث تلقائي)',
              (lg != null && lg.startsWith('http')) ? lg : null);
        })
        .where((c) => c.name.isNotEmpty && c.url.startsWith('http'))
        .toList();
  } catch (_) {
    return [];
  }
}

/// من GitHub فقط (null عند الفشل) — وتُحفظ نسخة للفتح السريع لاحقاً.
Future<List<Channel>?> fetchChannelsRemote() async {
  final t = await _fetchRemote('$repoRawBase/assets/channels.txt');
  if (t == null) return null;
  final l = parseChannelsText(t);
  if (l.isEmpty) return null;
  _cacheSet('cache_channels', t);
  return l;
}

Future<List<Channel>?> fetchAutoRemote() async {
  final t = await _fetchRemote('$repoRawBase/assets/auto_channels.json');
  if (t == null) return null;
  final l = parseAutoChannels(t);
  if (l.isEmpty) return null;
  _cacheSet('cache_auto', t);
  return l;
}

/// من GitHub أولاً (تتحدث بدون APK جديد)، وإن تعذر الإنترنت فالنسخة المدمجة.
Future<List<Channel>> loadChannels() async {
  final r = await fetchChannelsRemote();
  if (r != null) return r;
  final text = await rootBundle.loadString('assets/channels.txt');
  return parseChannelsText(text);
}

/// القنوات التلقائية (يحدّثها السكربت) — تظهر تحت اليدوية بأقسام.
Future<List<Channel>> loadAutoChannels() async {
  final r = await fetchAutoRemote();
  if (r != null) return r;
  try {
    return parseAutoChannels(await rootBundle.loadString('assets/auto_channels.json'));
  } catch (_) {
    return [];
  }
}

// =====================================================================
//  التطبيق
// =====================================================================

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const BoxApp());
}

ThemeData _buildTheme() {
  final base = ThemeData.dark();
  return base.copyWith(
    scaffoldBackgroundColor: Colors.black,
    textTheme: GoogleFonts.cairoTextTheme(base.textTheme),
    primaryTextTheme: GoogleFonts.cairoTextTheme(base.primaryTextTheme),
  );
}

class BoxApp extends StatelessWidget {
  const BoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Alfaham Box',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: _buildTheme(),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Channel> channels = []; // يدوية
  List<Channel> autoChannels = []; // تلقائية (تحت اليدوية)
  List<Channel> get allChannels => [...channels, ...autoChannels];
  int current = -1;
  bool menuOpen = false;
  bool qOpen = false;
  String? localMsg; // رسائل خاصة (مثل فشل يوتيوب)

  final ctrl = StreamController2();
  final rootFocus = FocusNode(debugLabel: 'root');
  final qBtnFocus = FocusNode(debugLabel: 'quality-btn');
  FocusNode? activeNode; // يأخذ التركيز عند فتح القائمة
  int focusIndex = 0;
  int focusedIdx = -1; // القناة التي عليها التركيز فعلياً في القائمة
  FocusNode? qFirstNode;
  ScrollController? listCtrl;
  int _playToken = 0;
  Timer? _playTimer;

  // ---- ميزات التلفزيون ----
  int prev = -1; // القناة السابقة (للرجوع السريع)
  bool infoVisible = false; // شريط معلومات القناة
  Timer? infoTimer;
  String numBuf = ''; // رقم القناة قيد الإدخال
  Timer? numTimer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _startup();
  }

  // ---------- آخر قناة ----------
  Future<(String, String)?> _loadLast() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final n = sp.getString('last_name');
      final u = sp.getString('last_url');
      if (n != null && u != null) return (n, u);
    } catch (_) {}
    return null;
  }

  Future<void> _saveLast(Channel c) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('last_name', c.name);
      await sp.setString('last_url', c.url);
    } catch (_) {}
  }

  int _findSaved((String, String)? saved) {
    if (saved == null) return -1;
    final all = allChannels;
    var k = all.indexWhere((c) => c.url == saved.$2);
    if (k < 0) k = all.indexWhere((c) => c.name == saved.$1);
    return k;
  }

  Future<void> _startup() async {
    final saved = await _loadLast();
    final cm = await _cacheGet('cache_channels');
    final ca = await _cacheGet('cache_auto');
    final cached = cm == null ? <Channel>[] : parseChannelsText(cm);
    if (cached.isNotEmpty) {
      // فتح فوري من النسخة المحفوظة، ثم التحديث في الخلفية
      if (!mounted) return;
      setState(() {
        channels = cached;
        autoChannels = ca == null ? <Channel>[] : parseAutoChannels(ca);
      });
      _begin(saved);
      _refreshLists();
      return;
    }
    // أول تشغيل: لا توجد نسخة محفوظة بعد
    final autoFuture = loadAutoChannels();
    final c = await loadChannels();
    if (!mounted) return;
    setState(() => channels = c);
    if (_findSaved(saved) < 0 && saved != null) {
      // القناة المحفوظة قد تكون ضمن القنوات التلقائية
      final a = await autoFuture;
      if (!mounted) return;
      setState(() => autoChannels = a);
    } else {
      autoFuture.then((a) {
        if (mounted) setState(() => autoChannels = a);
      });
    }
    _begin(saved);
  }

  void _begin((String, String)? saved) {
    if (allChannels.isEmpty) return;
    final start = _findSaved(saved);
    if (start >= 0) {
      // نفتح مباشرة على آخر قناة (مثل التلفزيون) مع شريط المعلومات
      _play(start);
      _showInfo();
    } else {
      _openMenu();
      _play(0);
    }
  }

  /// تحديث القوائم من الإنترنت بالخلفية دون مقاطعة المشاهدة.
  Future<void> _refreshLists() async {
    final r = await Future.wait<List<Channel>?>(
        [fetchChannelsRemote(), fetchAutoRemote()]);
    final m = r[0];
    final a = r[1];
    if (!mounted || (m == null && a == null)) return;
    final all = allChannels;
    final curUrl =
        (current >= 0 && current < all.length) ? all[current].url : null;
    final prevUrl =
        (prev >= 0 && prev < all.length) ? all[prev].url : null;
    final newManual = m ?? channels;
    final newAuto = a ?? autoChannels;
    String sig(List<Channel> l) => l.map((c) => '${c.name}|${c.url}').join('\n');
    if (sig(newManual) == sig(channels) && sig(newAuto) == sig(autoChannels)) {
      return;
    }
    setState(() {
      channels = newManual;
      autoChannels = newAuto;
      final na = allChannels;
      // نُبقي current/prev مشيرة لنفس القناة بعد تغيّر الترتيب
      if (curUrl != null) current = na.indexWhere((c) => c.url == curUrl);
      if (prevUrl != null) prev = na.indexWhere((c) => c.url == prevUrl);
    });
  }

  @override
  void dispose() {
    infoTimer?.cancel();
    numTimer?.cancel();
    _playTimer?.cancel();
    ctrl.dispose();
    rootFocus.dispose();
    qBtnFocus.dispose();
    activeNode?.dispose();
    qFirstNode?.dispose();
    listCtrl?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ---------- القائمة ----------
  /// صفوف القائمة: رقم = قناة، نص = عنوان قسم
  List<Object> _rows() {
    final all = allChannels;
    final rows = <Object>[];
    String? lastGroup;
    for (var k = 0; k < all.length; k++) {
      final g = all[k].group;
      if (g != null && g != lastGroup) rows.add(g);
      lastGroup = g;
      rows.add(k);
    }
    return rows;
  }

  void _openMenu() {
    if (menuOpen) return;
    listCtrl?.dispose();
    activeNode?.dispose();
    focusIndex = current < 0 ? 0 : current;
    focusedIdx = -1;
    final pos = math.max(0, _rows().indexOf(focusIndex));
    listCtrl = ScrollController(
      initialScrollOffset: math.max(0, pos * _itemExtent - 160),
    );
    activeNode = FocusNode(debugLabel: 'active-card');
    setState(() => menuOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && menuOpen) activeNode?.requestFocus();
    });
  }

  void _closeMenu() {
    if (!menuOpen && !qOpen) return;
    setState(() {
      menuOpen = false;
      qOpen = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) rootFocus.requestFocus();
    });
  }

  void _toggleMenu() => menuOpen ? _closeMenu() : _openMenu();

  // القائمة لا تُغلق تلقائياً: تبقى مفتوحة حتى يختار المستخدم قناة
  // أو يضغط رجوع / يلمس خارج القائمة.

  // ---------- قائمة الجودة ----------
  void _openQuality() {
    qFirstNode?.dispose();
    qFirstNode = FocusNode(debugLabel: 'q-first');
    setState(() => qOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && qOpen) qFirstNode?.requestFocus();
    });
  }

  void _closeQuality() {
    setState(() => qOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && qBtnFocus.context != null) qBtnFocus.requestFocus();
    });
  }

  void _pickQuality(int i) {
    ctrl.setQuality(i);
    _closeQuality();
  }

  // ---------- تشغيل قناة ----------
  void _play(int i) {
    final all = allChannels;
    if (i < 0 || i >= all.length) return;
    final ch = all[i];
    final token = ++_playToken;
    setState(() {
      if (current >= 0 && current != i) prev = current;
      current = i;
      localMsg = null;
    });
    _saveLast(ch);
    // تأخير بسيط: عند التنقل السريع لا نحمّل كل قناة نمر عليها
    _playTimer?.cancel();
    _playTimer =
        Timer(const Duration(milliseconds: 350), () => _startPlayback(ch, token));
  }

  Future<void> _startPlayback(Channel ch, int token) async {
    if (!mounted || token != _playToken) return;
    var url = ch.url;
    if (isYoutubeUrl(url)) {
      setState(() => localMsg = 'جاري تحميل بث يوتيوب...');
      final resolved = await resolveYoutube(url);
      if (!mounted || token != _playToken) return;
      if (resolved == null) {
        setState(() => localMsg = '⚠ تعذر تشغيل بث يوتيوب');
        return;
      }
      setState(() => localMsg = null);
      url = resolved;
    }
    if (!mounted || token != _playToken) return;
    await ctrl.play(url);
  }

  // ---------- القفز بين الأقسام في القائمة ----------
  void _jumpGroup(int dir) {
    final rows = _rows();
    if (rows.isEmpty) return;
    var pos = rows.indexOf(focusedIdx);
    if (pos < 0) pos = rows.indexOf(focusIndex);
    if (pos < 0) pos = 0;
    if (rows[pos] is! int) pos = rows.indexWhere((r) => r is int);
    if (pos < 0) return;
    int target;
    if (dir > 0) {
      int? t;
      for (var r = pos + 1; r < rows.length; r++) {
        if (rows[r] is String && r + 1 < rows.length) {
          t = rows[r + 1] as int;
          break;
        }
      }
      target = t ?? (rows.lastWhere((r) => r is int) as int);
    } else {
      var h = pos;
      while (h >= 0 && rows[h] is! String) {
        h--;
      }
      final firstOfGroup = rows[h + 1] as int;
      final cur = rows[pos] as int;
      if (h < 0 || cur != firstOfGroup) {
        target = firstOfGroup;
      } else {
        var h2 = h - 1;
        while (h2 >= 0 && rows[h2] is! String) {
          h2--;
        }
        target = rows[h2 + 1] as int;
      }
    }
    final tpos = rows.indexOf(target);
    focusIndex = target;
    final lc = listCtrl;
    if (lc != null && lc.hasClients) {
      final off = math.max(0.0, tpos * _itemExtent - 160);
      lc.jumpTo(off.clamp(0.0, lc.position.maxScrollExtent).toDouble());
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && menuOpen) activeNode?.requestFocus();
    });
  }

  // ---------- شريط المعلومات / تغيير القناة ----------
  void _showInfo() {
    infoTimer?.cancel();
    setState(() => infoVisible = true);
    infoTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => infoVisible = false);
    });
  }

  void _switchBy(int delta) {
    final n = allChannels.length;
    if (n == 0) return;
    final base = current < 0 ? 0 : current;
    _play(((base + delta) % n + n) % n);
    _showInfo();
  }

  void _recallPrev() {
    if (prev < 0 || prev >= allChannels.length) return;
    _play(prev);
    _showInfo();
  }

  // إدخال رقم القناة بأزرار الريموت
  void _typeDigit(String d) {
    if (numBuf.length >= 4) return;
    numTimer?.cancel();
    setState(() => numBuf += d);
    final n = int.parse(numBuf);
    final total = allChannels.length;
    // إذا لا يمكن إضافة رقم آخر (n*10 أكبر من العدد) نشغّل فوراً
    if (n * 10 > total) {
      _commitNumber();
    } else {
      numTimer = Timer(const Duration(milliseconds: 1500), _commitNumber);
    }
  }

  void _commitNumber() {
    numTimer?.cancel();
    final n = int.tryParse(numBuf) ?? 0;
    setState(() => numBuf = '');
    if (n >= 1 && n <= allChannels.length) {
      _play(n - 1);
      _showInfo();
    }
  }

  static String? _digitOf(LogicalKeyboardKey k) {
    final l = k.keyLabel;
    if (l.length == 1 && '0123456789'.contains(l)) return l;
    return null;
  }

  // ---------- مفاتيح الريموت ----------
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (qOpen) {
      if (k == LogicalKeyboardKey.arrowRight) {
        _closeQuality();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (menuOpen) {
      if (k == LogicalKeyboardKey.escape) {
        _closeMenu();
        return KeyEventResult.handled;
      }
      // CH-/PageDown: القسم التالي، CH+/PageUp: القسم السابق
      if (k == LogicalKeyboardKey.channelDown ||
          k == LogicalKeyboardKey.pageDown) {
        _jumpGroup(1);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.channelUp ||
          k == LogicalKeyboardKey.pageUp) {
        _jumpGroup(-1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final isOk = k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.space;
    // OK أثناء إدخال رقم = تأكيد فوري
    if (isOk && numBuf.isNotEmpty) {
      _commitNumber();
      return KeyEventResult.handled;
    }
    if (isOk) {
      _openMenu();
      return KeyEventResult.handled;
    }
    // ↑ القناة التالية، ↓ السابقة (بدون فتح القائمة)
    if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.channelUp ||
        k == LogicalKeyboardKey.pageUp) {
      _switchBy(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.channelDown ||
        k == LogicalKeyboardKey.pageDown) {
      _switchBy(-1);
      return KeyEventResult.handled;
    }
    // ← الرجوع للقناة السابقة
    if (k == LogicalKeyboardKey.arrowLeft) {
      _recallPrev();
      return KeyEventResult.handled;
    }
    // الأرقام
    final d = _digitOf(k);
    if (d != null) {
      _typeDigit(d);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------- الواجهة ----------
  Widget _video() {
    if (ctrl.exo != null && ctrl.engine == Engine.exo) {
      final c = ctrl.exo!;
      return Center(
        child: AspectRatio(
          aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
          child: VideoPlayer(c),
        ),
      );
    }
    if (ctrl.mpvVideo != null && ctrl.engine == Engine.mpv) {
      return Video(controller: ctrl.mpvVideo!, controls: NoVideoControls);
    }
    return const SizedBox.shrink();
  }

  /// شاشة "لا توجد إشارة" (مثل أجهزة الستلايت)
  Widget _noSignal() {
    final all = allChannels;
    final name =
        (current >= 0 && current < all.length) ? all[current].name : '';
    return IgnorePointer(
      child: Container(
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0D2340), Color(0xFF050B14)],
          ),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.satellite_alt, size: 72, color: Color(0xFF5B7FA8)),
          const SizedBox(height: 14),
          const Text('لا توجد إشارة',
              style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('NO SIGNAL',
              style: TextStyle(
                  fontSize: 14, letterSpacing: 4, color: Color(0xFF7C93B0))),
          if (name.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('${current + 1}  •  $name',
                style:
                    const TextStyle(fontSize: 16, color: Color(0xFFB8C7DB))),
          ],
        ]),
      ),
    );
  }

  Widget _status() {
    // أثناء الانتظار القصير قبل تحميل قناة جديدة لا نُظهر "لا توجد إشارة"
    final waiting = _playTimer?.isActive ?? false;
    if (waiting && ctrl.status == PlayStatus.error) {
      return const IgnorePointer(
        child: Center(
          child: SizedBox(
            width: 42,
            height: 42,
            child: CircularProgressIndicator(color: accent, strokeWidth: 3),
          ),
        ),
      );
    }
    final failed = (localMsg != null && localMsg!.startsWith('⚠')) ||
        (localMsg == null && ctrl.status == PlayStatus.error);
    if (failed) return _noSignal();
    String? text = localMsg;
    bool loading = false;
    if (text == null) {
      if (ctrl.status == PlayStatus.loading) loading = true;
      if (ctrl.status == PlayStatus.error) text = ctrl.message;
    } else if (!text.startsWith('⚠')) {
      loading = true;
    }
    if (loading && text == null && ctrl.retryNote.isNotEmpty) {
      text = ctrl.retryNote;
    }
    if (!loading && (text == null || text.isEmpty)) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (loading)
            const SizedBox(
              width: 42,
              height: 42,
              child: CircularProgressIndicator(color: accent, strokeWidth: 3),
            ),
          if (text != null && text.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(text,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700)),
          ],
        ]),
      ),
    );
  }

  Widget _menu() {
    return Align(
      alignment: Alignment.centerRight,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 1, end: 0),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        builder: (_, v, child) =>
            Transform.translate(offset: Offset(v * 320, 0), child: child),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {}, // لا تُغلق القائمة عند الضغط داخلها
          child: Container(
            width: 300,
            height: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              color: Color(0xD9000000),
              border: Border(left: BorderSide(color: Color(0x1AFFFFFF))),
            ),
            child: Builder(builder: (_) {
              final all = allChannels;
              final rows = _rows();
              return ListView.builder(
                controller: listCtrl,
                itemExtent: _itemExtent,
                itemCount: rows.length,
                itemBuilder: (_, pos) {
                  final row = rows[pos];
                  if (row is String) return _GroupHeader(title: row);
                  final i = row as int;
                  return _ChannelCard(
                    number: i + 1,
                    name: all[i].name,
                    logo: all[i].logo,
                    active: i == current,
                    focusNode: i == focusIndex ? activeNode : null,
                    onFocused: () => focusedIdx = i,
                    onTap: () {
                      _closeMenu();
                      _play(i);
                      _showInfo();
                    },
                  );
                },
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _infoBar() {
    final all = allChannels;
    if (current < 0 || current >= all.length) return const SizedBox.shrink();
    return Positioned(
      left: 30,
      bottom: 30,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xD9000000),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('${current + 1}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            if (all[current].logo != null) ...[
              const SizedBox(width: 10),
              _Logo(url: all[current].logo!, size: 34),
            ],
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(all[current].name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _numOverlay() {
    return Positioned(
      top: 30,
      left: 30,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xD9000000),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: accent, width: 1.5),
          ),
          child: Text(numBuf,
              style: const TextStyle(
                  fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 2)),
        ),
      ),
    );
  }

  Widget _qualityButton() {
    return Positioned(
      left: 30,
      bottom: 30,
      child: _PillButton(
        label: 'HQ',
        focusNode: qBtnFocus,
        onTap: _openQuality,
      ),
    );
  }

  Widget _qualityMenu() {
    final opts = <MapEntry<int, String>>[
      const MapEntry(-1, 'تلقائي'),
      for (var i = 0; i < ctrl.qualities.length; i++)
        MapEntry(i, ctrl.qualities[i].label),
    ];
    return Positioned(
      left: 30,
      bottom: 80,
      child: FocusScope(
        child: Container(
          constraints: const BoxConstraints(minWidth: 120),
          decoration: BoxDecoration(
            color: const Color(0xF2000000),
            border: Border.all(color: const Color(0xFF444444)),
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var k = 0; k < opts.length; k++)
                _QualityOption(
                  label: opts[k].value,
                  focusNode: k == 0 ? qFirstNode : null,
                  onTap: () => _pickQuality(opts[k].key),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !(menuOpen || qOpen),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (qOpen) {
          _closeQuality();
        } else {
          _closeMenu();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: rootFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleMenu,
            child: AnimatedBuilder(
              animation: ctrl,
              builder: (_, __) => Stack(
                fit: StackFit.expand,
                children: [
                  _video(),
                  _status(),
                  if (infoVisible && !menuOpen) _infoBar(),
                  if (numBuf.isNotEmpty && !menuOpen) _numOverlay(),
                  if (menuOpen) _menu(),
                  if (menuOpen && ctrl.qualities.length > 1) _qualityButton(),
                  if (menuOpen && qOpen && ctrl.qualities.length > 1)
                    _qualityMenu(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
//  عناصر الواجهة (نفس تصميم الويب)
// =====================================================================

class _GroupHeader extends StatelessWidget {
  final String title;
  const _GroupHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Row(children: [
        const Expanded(child: Divider(color: Color(0x33FFFFFF))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF9A9A9A),
            ),
          ),
        ),
        const Expanded(child: Divider(color: Color(0x33FFFFFF))),
      ]),
    );
  }
}

class _ChannelCard extends StatefulWidget {
  final int number;
  final String name;
  final String? logo;
  final bool active;
  final FocusNode? focusNode;
  final VoidCallback onTap;
  final VoidCallback? onFocused;

  const _ChannelCard({
    required this.number,
    required this.name,
    required this.active,
    required this.onTap,
    this.logo,
    this.focusNode,
    this.onFocused,
  });

  @override
  State<_ChannelCard> createState() => _ChannelCardState();
}

class _ChannelCardState extends State<_ChannelCard> {
  bool focused = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final Color border = active
        ? accent
        : (focused ? const Color(0xFF444444) : Colors.transparent);
    final Color bg = active
        ? const Color(0x14FFFFFF)
        : (focused ? const Color(0xFF2A2A2A) : const Color(0x0DFFFFFF));
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        focusNode: widget.focusNode,
        onTap: widget.onTap,
        onFocusChange: (f) {
          setState(() => focused = f);
          if (f) widget.onFocused?.call();
        },
        borderRadius: BorderRadius.circular(6),
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: border, width: 2),
          ),
          child: Row(children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active ? accent : const Color(0x1AFFFFFF),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${widget.number}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: active ? Colors.white : const Color(0xFFCCCCCC),
                ),
              ),
            ),
            if (widget.logo != null) ...[
              const SizedBox(width: 10),
              _Logo(url: widget.logo!, size: 30),
            ],
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// شعار القناة (إن تعذر تحميله نعرض أيقونة تلفزيون بدلاً منه)
class _Logo extends StatelessWidget {
  final String url;
  final double size;
  const _Logo({required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: const Color(0x33FFFFFF),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Image.network(
        url,
        fit: BoxFit.contain,
        cacheWidth: (size * 3).round(),
        errorBuilder: (_, __, ___) =>
            const Icon(Icons.tv, size: 16, color: Color(0xFF777777)),
      ),
    );
  }
}

class _PillButton extends StatefulWidget {
  final String label;
  final FocusNode focusNode;
  final VoidCallback onTap;
  const _PillButton(
      {required this.label, required this.focusNode, required this.onTap});

  @override
  State<_PillButton> createState() => _PillButtonState();
}

class _PillButtonState extends State<_PillButton> {
  bool focused = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: focused ? 1.1 : 1.0,
      duration: const Duration(milliseconds: 150),
      child: InkWell(
        focusNode: widget.focusNode,
        onTap: widget.onTap,
        onFocusChange: (f) => setState(() => focused = f),
        borderRadius: BorderRadius.circular(50),
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          decoration: BoxDecoration(
            color: focused ? accent : const Color(0x1AFFFFFF),
            borderRadius: BorderRadius.circular(50),
            border: Border.all(
                color: focused ? Colors.white : const Color(0x33FFFFFF)),
          ),
          child: Text(widget.label,
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }
}

class _QualityOption extends StatefulWidget {
  final String label;
  final FocusNode? focusNode;
  final VoidCallback onTap;
  const _QualityOption(
      {required this.label, required this.onTap, this.focusNode});

  @override
  State<_QualityOption> createState() => _QualityOptionState();
}

class _QualityOptionState extends State<_QualityOption> {
  bool focused = false;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      focusNode: widget.focusNode,
      onTap: widget.onTap,
      onFocusChange: (f) => setState(() => focused = f),
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: focused ? accent : Colors.transparent,
          border: const Border(bottom: BorderSide(color: Color(0x1AFFFFFF))),
        ),
        child: Text(widget.label, style: const TextStyle(fontSize: 13)),
      ),
    );
  }
}
