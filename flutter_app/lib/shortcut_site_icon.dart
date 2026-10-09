import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:html/parser.dart' as html;

const _htmlLimit = 256 * 1024;
const _imageLimit = 512 * 1024;
const _requestTimeout = Duration(seconds: 4);
const _discoveryTimeout = Duration(seconds: 8);

/// [bytes] is a small PNG thumbnail, including when [url] points to SVG or ICO.
class ShortcutSiteIconResult {
  const ShortcutSiteIconResult({required this.url, required this.bytes});
  final String url;
  final Uint8List bytes;
}

class ShortcutSiteIconResponse {
  const ShortcutSiteIconResponse({
    required this.statusCode,
    required this.bytes,
    this.headers = const {},
  });
  final int statusCode;
  final Uint8List bytes;
  final Map<String, String> headers;

  String? header(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }
}

/// Injected getters must enforce the supplied byte limit while reading streams.
typedef ShortcutSiteIconGetter = Future<ShortcutSiteIconResponse> Function(
  Uri uri,
  int maxBytes,
);

/// Explicitly discover an icon when a user adds or refreshes a shortcut.
/// Cards only load their saved icon URL and never repeat the HTML discovery.
Future<ShortcutSiteIconResult?> discoverShortcutSiteIcon(
  String pageUrl, {
  ShortcutSiteIconGetter? getter,
}) async {
  final page = _publicUri(pageUrl);
  if (page == null) return null;
  final deadline = DateTime.now().add(_discoveryTimeout);
  final candidates = <Uri>[];
  var destination = page;
  try {
    final response = await _followingRedirects(
      page,
      _htmlLimit,
      getter ?? _publicGet,
      deadline,
    );
    destination = response.uri;
    if (response.response.statusCode == 200 &&
        (response.response.header('content-type') ?? '').toLowerCase().contains(
          'html',
        )) {
      final document = html.parse(
        utf8.decode(response.response.bytes, allowMalformed: true),
      );
      final baseHref = document.querySelector('base[href]')?.attributes['href'];
      final base = baseHref == null
          ? destination
          : _resolvedUri(destination, baseHref) ?? destination;
      final ranked = <(int, Uri)>[];
      for (final link in document.querySelectorAll('link[href][rel]')) {
        final rel = (link.attributes['rel'] ?? '').toLowerCase().split(
          RegExp(r'\s+'),
        );
        if (!rel.contains('icon') &&
            !rel.contains('apple-touch-icon') &&
            !rel.contains('apple-touch-icon-precomposed')) {
          continue;
        }
        final uri = _resolvedUri(base, link.attributes['href']!);
        if (uri == null) continue;
        var rank = rel.contains('icon') ? 0 : 20;
        final sizes = link.attributes['sizes'] ?? '';
        if (sizes == 'any' || (link.attributes['type'] ?? '').contains('svg')) {
          rank -= 3;
        } else if (sizes.contains('32x32') || sizes.contains('48x48')) {
          rank -= 2;
        }
        ranked.add((rank, uri));
      }
      ranked.sort((a, b) => a.$1.compareTo(b.$1));
      for (final (_, uri) in ranked) {
        if (!candidates.contains(uri)) candidates.add(uri);
        if (candidates.length == 3) break;
      }
    }
  } catch (_) {
    // A private or unavailable page can still have a public /favicon.ico.
  }
  final fallback = destination.resolve('/favicon.ico');
  if (!candidates.contains(fallback)) candidates.add(fallback);
  for (final candidate in candidates) {
    if (!DateTime.now().isBefore(deadline)) return null;
    final result = await _downloadIcon(
      candidate,
      getter ?? _publicGet,
      deadline,
    );
    if (result != null) {
      _remember(candidate.toString(), result);
      _remember(result.url, result);
      return result;
    }
  }
  return null;
}

/// Uses only the stored [iconUrl]; [pageUrl] never triggers page discovery.
class ShortcutSiteIcon extends StatefulWidget {
  const ShortcutSiteIcon({
    super.key,
    required this.pageUrl,
    this.iconUrl,
    required this.fallback,
    this.size = 24,
    this.getter,
  });
  final String pageUrl;
  final String? iconUrl;
  final Widget fallback;
  final double size;
  final ShortcutSiteIconGetter? getter;

  @override
  State<ShortcutSiteIcon> createState() => _ShortcutSiteIconState();
}

class _ShortcutSiteIconState extends State<ShortcutSiteIcon> {
  late Future<ShortcutSiteIconResult?> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ShortcutSiteIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.iconUrl != widget.iconUrl ||
        oldWidget.pageUrl != widget.pageUrl ||
        oldWidget.getter != widget.getter) {
      _load();
    }
  }

  void _load() {
    final uri = _publicUri(widget.iconUrl ?? '');
    _future = uri == null || _publicUri(widget.pageUrl) == null
        ? Future.value()
        : _cachedIcon(uri, widget.getter ?? _publicGet);
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: FutureBuilder<ShortcutSiteIconResult?>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data?.bytes;
        if (bytes == null) return widget.fallback;
        return Image.memory(
          bytes,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) => widget.fallback,
        );
      },
    ),
  );
}

class _CacheEntry {
  _CacheEntry(this.result)
    : expires = DateTime.now().add(
        result == null ? const Duration(minutes: 1) : const Duration(hours: 1),
      );
  final ShortcutSiteIconResult? result;
  final DateTime expires;
}

final _cache = <String, _CacheEntry>{};
final _pending = <String, Future<ShortcutSiteIconResult?>>{};
int _cacheBytes = 0;

void _remember(String key, ShortcutSiteIconResult? result) {
  _cacheBytes -= _cache.remove(key)?.result?.bytes.length ?? 0;
  _cache[key] = _CacheEntry(result);
  _cacheBytes += result?.bytes.length ?? 0;
  while (_cache.length > 64 || _cacheBytes > 8 * 1024 * 1024) {
    _cacheBytes -= _cache.remove(_cache.keys.first)?.result?.bytes.length ?? 0;
  }
}

Future<ShortcutSiteIconResult?> _cachedIcon(
  Uri uri,
  ShortcutSiteIconGetter getter,
) {
  final key = uri.toString();
  final entry = _cache[key];
  if (entry != null && DateTime.now().isBefore(entry.expires)) {
    _cache.remove(key);
    _cache[key] = entry;
    return Future.value(entry.result);
  }
  final pending = _pending[key];
  if (pending != null) return pending;
  if (_pending.length >= 12) return Future.value();
  final future = _downloadIcon(uri, getter, DateTime.now().add(_requestTimeout))
      .then((result) {
        _remember(key, result);
        if (result != null) _remember(result.url, result);
        return result;
      })
      .whenComplete(() {
        _pending.remove(key);
      });
  _pending[key] = future;
  return future;
}

Future<ShortcutSiteIconResult?> _downloadIcon(
  Uri uri,
  ShortcutSiteIconGetter getter,
  DateTime deadline,
) async {
  try {
    final response = await _followingRedirects(
      uri,
      _imageLimit,
      getter,
      deadline,
    );
    if (response.response.statusCode != 200) return null;
    final bytes = await _normalizeImage(
      response.response.bytes,
      response.response.header('content-type') ?? '',
    ).timeout(_remaining(deadline));
    return bytes == null
        ? null
        : ShortcutSiteIconResult(url: response.uri.toString(), bytes: bytes);
  } catch (_) {
    return null;
  }
}

Future<({Uri uri, ShortcutSiteIconResponse response})> _followingRedirects(
  Uri uri,
  int maxBytes,
  ShortcutSiteIconGetter getter,
  DateTime deadline,
) async {
  for (var redirects = 0; redirects <= 3; redirects++) {
    if (_publicUri(uri.toString()) == null) throw const FormatException();
    final response = await getter(uri, maxBytes).timeout(_remaining(deadline));
    if (response.bytes.length > maxBytes) throw const FormatException();
    if (![301, 302, 303, 307, 308].contains(response.statusCode)) {
      return (uri: uri, response: response);
    }
    final location = response.header('location');
    final next = location == null ? null : _resolvedUri(uri, location);
    if (next == null) throw const FormatException();
    uri = next;
  }
  throw const FormatException('Too many redirects');
}

Duration _remaining(DateTime deadline) {
  final remaining = deadline.difference(DateTime.now());
  if (remaining <= Duration.zero) {
    throw TimeoutException('Icon request expired');
  }
  return remaining < _requestTimeout ? remaining : _requestTimeout;
}

Uri? _resolvedUri(Uri base, String href) {
  try {
    return _publicUri(base.resolve(href.trim()).toString());
  } catch (_) {
    return null;
  }
}

Uri? _publicUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.host.isEmpty ||
      (uri.hasPort && uri.port != 443)) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal')) {
    return null;
  }
  final address = InternetAddress.tryParse(host);
  if (address != null) {
    if (!_publicAddress(address)) return null;
  } else if (!host.contains('.') || !RegExp(r'^[a-z0-9.-]+$').hasMatch(host)) {
    return null;
  }
  return uri.removeFragment();
}

bool _publicAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (bytes.length == 16) return (bytes.first & 0xe0) == 0x20;
  final a = bytes[0], b = bytes[1];
  return a != 0 &&
      a != 10 &&
      a != 127 &&
      a < 224 &&
      !(a == 169 && b == 254) &&
      !(a == 172 && b >= 16 && b <= 31) &&
      !(a == 192 && b == 168) &&
      !(a == 100 && b >= 64 && b <= 127) &&
      !(a == 198 && (b == 18 || b == 19));
}

Future<ShortcutSiteIconResponse> _publicGet(Uri uri, int maxBytes) async {
  final client = HttpClient()
    ..connectionTimeout = _requestTimeout
    ..userAgent = 'Ieum-LinkIcon/1.0'
    ..findProxy = (_) => 'DIRECT';
  client.connectionFactory = (target, _, _) async {
    final addresses = await InternetAddress.lookup(target.host)
        .timeout(_requestTimeout);
    if (addresses.isEmpty || addresses.any((a) => !_publicAddress(a))) {
      throw const SocketException('Icon host is not public');
    }
    final address = addresses.firstWhere(
      (address) => address.type == InternetAddressType.IPv4,
      orElse: () => addresses.first,
    );
    return Socket.startConnect(address, target.port);
  };
  try {
    return await (() async {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'text/html,image/*;q=0.9');
      final response = await request.close();
      if (response.contentLength > maxBytes) throw const FormatException();
      final body = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (body.length + chunk.length > maxBytes) {
          throw const FormatException();
        }
        body.add(chunk);
      }
      return ShortcutSiteIconResponse(
        statusCode: response.statusCode,
        bytes: body.takeBytes(),
        headers: {
          for (final name in ['content-type', 'location'])
            if (response.headers.value(name) case final String value)
              name: value,
        },
      );
    })().timeout(_requestTimeout);
  } finally {
    client.close(force: true);
  }
}

Future<Uint8List?> _normalizeImage(Uint8List bytes, String type) async {
  type = type.toLowerCase();
  if (bytes.isEmpty ||
      bytes.length > _imageLimit ||
      type.contains('text/html')) {
    return null;
  }
  if (_starts(bytes, [0, 0, 1, 0])) return _decodeIco(bytes);
  final prefix = utf8
      .decode(
        bytes.sublist(0, math.min(bytes.length, 1024)),
        allowMalformed: true,
      )
      .trimLeft();
  if (type.contains('svg') ||
      prefix.startsWith('<svg') ||
      prefix.startsWith('<?xml')) {
    final source = utf8.decode(bytes, allowMalformed: true);
    final document = html.parse(source);
    if (document.querySelector('svg') == null ||
        document.querySelector('script, foreignObject, image, feImage') !=
            null ||
        source.toLowerCase().contains('<!entity')) {
      return null;
    }
    for (final element in document.querySelectorAll('*')) {
      for (final entry in element.attributes.entries) {
        final name = entry.key.toString().toLowerCase();
        if ((name == 'href' || name == 'xlink:href' || name == 'src') &&
            !entry.value.trim().startsWith('#')) {
          return null;
        }
      }
    }
    if (source.contains(
          RegExp(r'url\(\s*["\x27]?https?:', caseSensitive: false),
        ) ||
        source.toLowerCase().contains('@import')) {
      return null;
    }
    final picture = await vg.loadPicture(SvgStringLoader(source), null);
    try {
      if (!_reasonableSize(picture.size.width, picture.size.height)) {
        return null;
      }
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final scale = math.min(96 / picture.size.width, 96 / picture.size.height);
      canvas.translate(
        (96 - picture.size.width * scale) / 2,
        (96 - picture.size.height * scale) / 2,
      );
      canvas.scale(scale);
      canvas.drawPicture(picture.picture);
      final rendered = recorder.endRecording();
      final image = await rendered.toImage(96, 96);
      rendered.dispose();
      try {
        return (await image.toByteData(format: ui.ImageByteFormat.png))?.buffer
            .asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      picture.picture.dispose();
    }
  }
  return _rasterThumbnail(bytes);
}

bool _reasonableSize(num width, num height) =>
    width.isFinite &&
    height.isFinite &&
    width > 0 &&
    height > 0 &&
    width <= 1024 &&
    height <= 1024 &&
    width * height <= 1024 * 1024;

Future<Uint8List?> _rasterThumbnail(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (!_reasonableSize(descriptor.width, descriptor.height)) return null;
    final scale = math.min(
      1.0,
      96 / math.max(descriptor.width, descriptor.height),
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    final frame = await codec.getNextFrame();
    try {
      return (await frame.image.toByteData(format: ui.ImageByteFormat.png))
          ?.buffer
          .asUint8List();
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

bool _starts(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

Future<Uint8List?> _decodeIco(Uint8List bytes) async {
  if (bytes.length < 6) return null;
  final data = ByteData.sublistView(bytes);
  final count = data.getUint16(4, Endian.little);
  if (count == 0 || count > 64 || 6 + count * 16 > bytes.length) return null;
  final entries = <(int, int, int)>[];
  for (var i = 0; i < count; i++) {
    final position = 6 + i * 16;
    final length = data.getUint32(position + 8, Endian.little);
    final offset = data.getUint32(position + 12, Endian.little);
    if (length == 0 ||
        offset < 6 + count * 16 ||
        offset + length > bytes.length) {
      continue;
    }
    final width = bytes[position] == 0 ? 256 : bytes[position];
    entries.add((width, offset, length));
  }
  entries.sort((a, b) => b.$1.compareTo(a.$1));
  for (final (_, offset, length) in entries.take(4)) {
    final payload = Uint8List.sublistView(bytes, offset, offset + length);
    try {
      if (_starts(payload, [137, 80, 78, 71, 13, 10, 26, 10])) {
        final png = await _rasterThumbnail(payload);
        if (png != null) return png;
      } else {
        final png = await _decodeIconBitmap(payload);
        if (png != null) return png;
      }
    } catch (_) {
      // Try the next representation from the same bounded icon container.
    }
  }
  return null;
}

Future<Uint8List?> _decodeIconBitmap(Uint8List bytes) async {
  if (bytes.length < 40) return null;
  final data = ByteData.sublistView(bytes);
  final header = data.getUint32(0, Endian.little);
  final width = data.getInt32(4, Endian.little);
  final storedHeight = data.getInt32(8, Endian.little);
  final height = storedHeight.abs() ~/ 2;
  final bits = data.getUint16(14, Endian.little);
  if (header < 40 ||
      header > bytes.length ||
      width < 1 ||
      width > 512 ||
      height < 1 ||
      height > 512 ||
      data.getUint16(12, Endian.little) != 1 ||
      data.getUint32(16, Endian.little) != 0 ||
      ![1, 4, 8, 24, 32].contains(bits)) {
    return null;
  }
  final colors = bits > 8 ? 0 : data.getUint32(32, Endian.little);
  final paletteCount = bits > 8
      ? 0
      : colors == 0
      ? 1 << bits
      : colors;
  if (paletteCount > 256) return null;
  final pixelsOffset = header + paletteCount * 4;
  final stride = ((width * bits + 31) ~/ 32) * 4;
  final maskOffset = pixelsOffset + stride * height;
  final maskStride = ((width + 31) ~/ 32) * 4;
  if (maskOffset > bytes.length) return null;
  final hasMask = maskOffset + maskStride * height <= bytes.length;
  final rgba = Uint8List(width * height * 4);
  var hasAlpha = false;
  for (var y = 0; y < height; y++) {
    final sourceY = storedHeight < 0 ? y : height - y - 1;
    final row = pixelsOffset + sourceY * stride;
    for (var x = 0; x < width; x++) {
      final dest = (y * width + x) * 4;
      var alpha = 255;
      if (bits <= 8) {
        final shift = 8 - bits - (x * bits % 8);
        final index = (bytes[row + x * bits ~/ 8] >> shift) & ((1 << bits) - 1);
        if (index >= paletteCount) return null;
        final color = header + index * 4;
        rgba[dest] = bytes[color + 2];
        rgba[dest + 1] = bytes[color + 1];
        rgba[dest + 2] = bytes[color];
      } else {
        final color = row + x * (bits ~/ 8);
        rgba[dest] = bytes[color + 2];
        rgba[dest + 1] = bytes[color + 1];
        rgba[dest + 2] = bytes[color];
        if (bits == 32) alpha = bytes[color + 3];
      }
      if (alpha != 0) hasAlpha = true;
      rgba[dest + 3] = alpha;
    }
  }
  for (var y = 0; y < height; y++) {
    final sourceY = storedHeight < 0 ? y : height - y - 1;
    for (var x = 0; x < width; x++) {
      final dest = (y * width + x) * 4 + 3;
      if (bits == 32 && !hasAlpha) rgba[dest] = 255;
      if (hasMask &&
          (bytes[maskOffset + sourceY * maskStride + x ~/ 8] &
                  (0x80 >> (x % 8))) !=
              0) {
        rgba[dest] = 0;
      }
    }
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec(
    targetWidth: math.min(width, 96),
    targetHeight: math.min(height, 96),
  );
  try {
    final frame = await codec.getNextFrame();
    try {
      return (await frame.image.toByteData(format: ui.ImageByteFormat.png))
          ?.buffer
          .asUint8List();
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}
