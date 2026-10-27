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
  Channel(this.name, this.url);
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

/// من GitHub أولاً (تتحدث بدون APK جديد)، وإن تعذر الإنترنت فالنسخة المدمجة.
Future<List<Channel>> loadChannels() async {
  final remote = await _fetchRemote('$repoRawBase/assets/channels.txt');
  if (remote != null) {
    final list = parseChannelsText(remote);
    if (list.isNotEmpty) return list;
  }
  final text = await rootBundle.loadString('assets/channels.txt');
  return parseChannelsText(text);
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
  List<Channel> channels = [];
  int current = -1;
  bool menuOpen = false;
  bool qOpen = false;
  String? localMsg; // رسائل خاصة (مثل فشل يوتيوب)

  final ctrl = StreamController2();
  final rootFocus = FocusNode(debugLabel: 'root');
  final qBtnFocus = FocusNode(debugLabel: 'quality-btn');
  FocusNode? activeNode; // يأخذ التركيز عند فتح القائمة
  int focusIndex = 0;
  FocusNode? qFirstNode;
  ScrollController? listCtrl;
  Timer? hideTimer;
  int _playToken = 0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    loadChannels().then((c) {
      if (!mounted) return;
      setState(() => channels = c);
      if (c.isNotEmpty) {
        _openMenu();
        _play(0);
      }
    });
  }

  @override
  void dispose() {
    hideTimer?.cancel();
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
  void _openMenu() {
    if (menuOpen) return;
    listCtrl?.dispose();
    activeNode?.dispose();
    focusIndex = current < 0 ? 0 : current;
    listCtrl = ScrollController(
      initialScrollOffset: math.max(0, focusIndex * _itemExtent - 160),
    );
    activeNode = FocusNode(debugLabel: 'active-card');
    setState(() => menuOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && menuOpen) activeNode?.requestFocus();
    });
  }

  void _closeMenu() {
    hideTimer?.cancel();
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

  void _startHideTimer() {
    hideTimer?.cancel();
    hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !qOpen) _closeMenu();
    });
  }

  void _killTimer() => hideTimer?.cancel();

  // ---------- قائمة الجودة ----------
  void _openQuality() {
    _killTimer();
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
    _startHideTimer();
  }

  // ---------- تشغيل قناة ----------
  Future<void> _play(int i) async {
    if (i < 0 || i >= channels.length) return;
    final token = ++_playToken;
    setState(() {
      current = i;
      localMsg = null;
    });
    _startHideTimer();
    var url = channels[i].url;
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
    await ctrl.play(url);
  }

  // ---------- مفاتيح الريموت ----------
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (qOpen) {
      _killTimer();
      if (k == LogicalKeyboardKey.arrowRight) {
        _closeQuality();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (menuOpen) {
      _killTimer();
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown) {
      _openMenu();
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

  Widget _status() {
    String? text = localMsg;
    bool loading = false;
    if (text == null) {
      if (ctrl.status == PlayStatus.loading) loading = true;
      if (ctrl.status == PlayStatus.error) text = ctrl.message;
    } else if (!text.startsWith('⚠')) {
      loading = true;
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
            Transform.translate(offset: Offset(v * 280, 0), child: child),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _killTimer, // لا تُغلق القائمة عند الضغط داخلها
          child: Listener(
            onPointerDown: (_) => _killTimer(),
            onPointerSignal: (_) => _killTimer(),
            child: Container(
              width: 260,
              height: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: const BoxDecoration(
                color: Color(0xD9000000),
                border: Border(left: BorderSide(color: Color(0x1AFFFFFF))),
              ),
              child: ListView.builder(
                controller: listCtrl,
                itemExtent: _itemExtent,
                itemCount: channels.length,
                itemBuilder: (_, i) => _ChannelCard(
                  number: i + 1,
                  name: channels[i].name,
                  active: i == current,
                  focusNode: i == focusIndex ? activeNode : null,
                  onTap: () => _play(i),
                ),
              ),
            ),
          ),
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

class _ChannelCard extends StatefulWidget {
  final int number;
  final String name;
  final bool active;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _ChannelCard({
    required this.number,
    required this.name,
    required this.active,
    required this.onTap,
    this.focusNode,
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
        onFocusChange: (f) => setState(() => focused = f),
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
