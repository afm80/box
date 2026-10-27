import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// هل الرابط رابط يوتيوب؟ (الويب يشغله عبر iframe، والتطبيق يستخرج رابط البث)
bool isYoutubeUrl(String url) =>
    url.contains('youtube.com') ||
    url.contains('youtu.be') ||
    url.contains('watch?v=');

String? youtubeId(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  if (uri.host.contains('youtu.be') && uri.pathSegments.isNotEmpty) {
    return uri.pathSegments.first;
  }
  return uri.queryParameters['v'];
}

/// يرجع رابط بث قابل للتشغيل (HLS للبث المباشر)، أو null عند الفشل.
Future<String?> resolveYoutube(String url) async {
  final id = youtubeId(url);
  if (id == null || id.isEmpty) return null;
  final yt = YoutubeExplode();
  try {
    try {
      // بث مباشر
      return await yt.videos.streamsClient.getHttpLiveStreamUrl(VideoId(id));
    } catch (_) {
      // فيديو عادي
      final manifest = await yt.videos.streamsClient.getManifest(VideoId(id));
      return manifest.muxed.withHighestBitrate().url.toString();
    }
  } catch (_) {
    return null;
  } finally {
    yt.close();
  }
}
