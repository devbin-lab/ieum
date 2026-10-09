import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/shortcut_site_icon.dart';

ShortcutSiteIconResponse _body(
  String body, {
  int status = 200,
  String type = 'text/html',
}) => ShortcutSiteIconResponse(
  statusCode: status,
  bytes: Uint8List.fromList(utf8.encode(body)),
  headers: {'content-type': type},
);

ShortcutSiteIconResponse _image(Uint8List bytes, [String type = 'image/png']) =>
    ShortcutSiteIconResponse(
      statusCode: 200,
      bytes: bytes,
      headers: {'content-type': type},
    );

Future<Uint8List> _png({int width = 4, int height = 4}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xff3366cc),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

Uint8List _ico(Uint8List payload, {int width = 4, int height = 4}) {
  final bytes = Uint8List(22 + payload.length);
  final data = ByteData.sublistView(bytes);
  data.setUint16(2, 1, Endian.little);
  data.setUint16(4, 1, Endian.little);
  bytes[6] = width;
  bytes[7] = height;
  data.setUint16(10, 1, Endian.little);
  data.setUint16(12, 32, Endian.little);
  data.setUint32(14, payload.length, Endian.little);
  data.setUint32(18, 22, Endian.little);
  bytes.setRange(22, bytes.length, payload);
  return bytes;
}

Uint8List _bitmapIcon(int bits) {
  const width = 2, height = 2;
  final colors = bits == 8 ? 2 : 0;
  final stride = ((width * bits + 31) ~/ 32) * 4;
  final bytes = Uint8List(40 + colors * 4 + stride * height + 8);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 40, Endian.little);
  data.setInt32(4, width, Endian.little);
  data.setInt32(8, height * 2, Endian.little);
  data.setUint16(12, 1, Endian.little);
  data.setUint16(14, bits, Endian.little);
  data.setUint32(32, colors, Endian.little);
  if (bits == 8) {
    bytes.setRange(40, 48, [0, 0, 0, 0, 204, 102, 51, 0]);
  }
  final pixelOffset = 40 + colors * 4;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final pos = pixelOffset + y * stride + x * (bits ~/ 8);
      if (bits == 8) {
        bytes[pos] = 1;
      } else {
        bytes.setRange(pos, pos + 3, [204, 102, 51]);
        if (bits == 32) bytes[pos + 3] = 255;
      }
    }
  }
  // The top-left pixel is transparent via the AND mask.
  bytes[pixelOffset + stride * height + 4] = 0x80;
  return _ico(bytes, width: width, height: height);
}

void main() {
  testWidgets(
    'discovers relative HTML icons and safely follows HTTPS redirects',
    (tester) async {
      final requests = <String>[];
      const svg =
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
          '<circle cx="12" cy="12" r="10" fill="#3366cc"/></svg>';
      Future<ShortcutSiteIconResponse> getter(Uri uri, int maxBytes) async {
        requests.add(uri.toString());
        return switch (uri.toString()) {
          'https://docs.example.com/project' => ShortcutSiteIconResponse(
            statusCode: 302,
            bytes: Uint8List(0),
            headers: {'location': '/boards/work'},
          ),
          'https://docs.example.com/boards/work' => _body(
            '<base href="/assets/">'
            '<link rel="icon" href="http://unsafe.example.com/icon.png">'
            '<link rel="SHORTCUT ICON" href="mark.svg?v=2">',
          ),
          'https://docs.example.com/assets/mark.svg?v=2' =>
            ShortcutSiteIconResponse(
              statusCode: 307,
              bytes: Uint8List(0),
              headers: {'location': 'https://static.example.com/logo.svg'},
            ),
          'https://static.example.com/logo.svg' => _body(
            svg,
            type: 'image/svg+xml',
          ),
          _ => _body('', status: 404),
        };
      }

      final result = await tester.runAsync(
        () => discoverShortcutSiteIcon(
          'https://docs.example.com/project#details',
          getter: getter,
        ),
      );
      expect(result?.url, 'https://static.example.com/logo.svg');
      expect(result!.bytes.take(4), [137, 80, 78, 71]);
      expect(requests, hasLength(4));
      expect(requests.every((url) => url.startsWith('https://')), isTrue);

      // Discovery primes the image cache; a card displays it without another fetch.
      await tester.pumpWidget(
        MaterialApp(
          home: ShortcutSiteIcon(
            pageUrl: 'https://docs.example.com/project',
            iconUrl: result.url,
            getter: getter,
            fallback: const Text('fallback'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(requests, hasLength(4));
    },
  );

  testWidgets('apple touch icons and favicon ICO PNG/DIB are supported', (
    tester,
  ) async {
    final png = (await tester.runAsync(_png))!;
    for (final (label, bytes) in [
      ('png', _ico(png)),
      ('24bit', _bitmapIcon(24)),
      ('32bit', _bitmapIcon(32)),
      ('8bit', _bitmapIcon(8)),
    ]) {
      final requests = <String>[];
      final result = await tester.runAsync(
        () => discoverShortcutSiteIcon(
          'https://$label.example.com/board',
          getter: (uri, limit) async {
            requests.add(uri.path);
            return uri.path == '/favicon.ico'
                ? _image(bytes, 'image/x-icon')
                : _body('private', status: 403);
          },
        ),
      );
      expect(result, isNotNull, reason: label);
      expect(result!.bytes.take(4), [137, 80, 78, 71], reason: label);
      expect(requests, ['/board', '/favicon.ico']);
      if (label != 'png') {
        final alpha = await tester.runAsync(() async {
          final codec = await ui.instantiateImageCodec(result.bytes);
          final frame = await codec.getNextFrame();
          final pixels = await frame.image.toByteData();
          frame.image.dispose();
          codec.dispose();
          return pixels!.getUint8(3);
        });
        expect(alpha, 0, reason: 'AND transparency mask: $label');
      }
    }
    final apple = await tester.runAsync(
      () => discoverShortcutSiteIcon(
        'https://apple.example.com',
        getter: (uri, _) async => uri.path == '/touch.png'
            ? _image(png)
            : _body('<link href="/touch.png" rel="apple-touch-icon">'),
      ),
    );
    expect(apple?.url, 'https://apple.example.com/touch.png');
  });

  testWidgets(
    'rejects credentials, private hosts and unsafe redirect targets',
    (tester) async {
      var calls = 0;
      Future<ShortcutSiteIconResponse> getter(Uri _, int _) async {
        calls++;
        return _body('', status: 404);
      }

      for (final url in [
        'http://example.com',
        'https://name:secret@example.com',
        'https://localhost',
        'https://127.0.0.1',
        'https://10.0.0.2',
        'https://192.168.1.2',
        'https://[::1]',
        'https://example.com:8443',
      ]) {
        expect(await discoverShortcutSiteIcon(url, getter: getter), isNull);
      }
      expect(calls, 0);
      final requests = <Uri>[];
      final result = await discoverShortcutSiteIcon(
        'https://redirect.example.com/board',
        getter: (uri, _) async {
          requests.add(uri);
          return ShortcutSiteIconResponse(
            statusCode: 302,
            bytes: Uint8List(0),
            headers: {'location': 'https://private:token@10.0.0.1/favicon.ico'},
          );
        },
      );
      expect(result, isNull);
      expect(
        requests.every((uri) => uri.host == 'redirect.example.com'),
        isTrue,
      );
      expect(requests, hasLength(2));
    },
  );

  testWidgets(
    'bounds response bytes, image dimensions and candidate attempts',
    (tester) async {
      final huge = (await tester.runAsync(() => _png(width: 1025, height: 1)))!;
      final png = (await tester.runAsync(_png))!;
      final requests = <Uri>[];
      final result = await tester.runAsync(
        () => discoverShortcutSiteIcon(
          'https://bounded.example.com/board',
          getter: (uri, limit) async {
            requests.add(uri);
            return switch (uri.path) {
              '/board' => _body(
                '<link rel="icon" href="/too-large.png">'
                '<link rel="icon" href="/dimensions.png">'
                '<link rel="icon" href="/invalid.png">'
                '<link rel="icon" href="/not-tried.png">',
              ),
              '/too-large.png' => _image(Uint8List(limit + 1)),
              '/dimensions.png' => _image(huge),
              '/favicon.ico' => _image(png),
              _ => _image(Uint8List.fromList([1, 2, 3, 4])),
            };
          },
        ),
      );
      expect(result?.url, 'https://bounded.example.com/favicon.ico');
      expect(requests, hasLength(5));
      expect(requests.any((uri) => uri.path == '/not-tried.png'), isFalse);
    },
  );

  testWidgets('rejects SVG external references and malformed icon containers', (
    tester,
  ) async {
    for (final (name, bytes, type) in [
      (
        'svg',
        Uint8List.fromList(
          utf8.encode(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
            '<use href="https://private.example.com/file.svg#shape"/></svg>',
          ),
        ),
        'image/svg+xml',
      ),
      ('ico', Uint8List.fromList([0, 0, 1, 0, 50, 0, 0]), 'image/x-icon'),
    ]) {
      final result = await tester.runAsync(
        () => discoverShortcutSiteIcon(
          'https://bad-$name.example.com/board',
          getter: (uri, _) async => uri.path == '/board'
              ? _body('<link rel="icon" href="/mark">')
              : _image(bytes, type),
        ),
      );
      expect(result, isNull, reason: name);
    }
  });

  testWidgets(
    'cards never fetch page HTML and reuse bounded success/failure cache',
    (tester) async {
      final png = (await tester.runAsync(_png))!;
      final requests = <String>[];
      Future<ShortcutSiteIconResponse> getter(Uri uri, int _) async {
        requests.add(uri.toString());
        return uri.path.endsWith('/ok.png')
            ? _image(png)
            : _body('', status: 404);
      }

      Widget cards() => MaterialApp(
        home: Row(
          children: [
            for (final path in ['ok.png', 'ok.png', 'bad.png', 'bad.png'])
              ShortcutSiteIcon(
                pageUrl: 'https://cache.example.com/board',
                iconUrl: 'https://cache.example.com/$path',
                getter: getter,
                fallback: const Text('fallback'),
              ),
            ShortcutSiteIcon(
              pageUrl: 'https://cache.example.com/no-icon',
              getter: getter,
              fallback: const Text('fallback'),
            ),
          ],
        ),
      );
      await tester.pumpWidget(cards());
      await tester.runAsync(() async {
        // Complete engine image decoding outside the fake clock.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(requests, [
        'https://cache.example.com/ok.png',
        'https://cache.example.com/bad.png',
      ]);
      expect(find.byType(Image), findsNWidgets(2));
      expect(find.text('fallback'), findsNWidgets(3));
      await tester.pumpWidget(cards());
      await tester.pumpAndSettle();
      expect(requests, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );
}
