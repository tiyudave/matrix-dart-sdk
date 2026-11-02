/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2026 Famedly GmbH
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General Public License as
 *   published by the Free Software Foundation, either version 3 of the
 *   License, or (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU Affero General Public License for more details.
 *
 *   You should have received a copy of the GNU Affero General Public License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:matrix/matrix_api_lite/utils/decode_sync_update.dart';

/// Builds a sync response with [rooms] joined rooms of [events] timeline
/// events each.
Map<String, Object?> syncJson(int rooms, int events) => {
      'next_batch': 's_$rooms',
      'rooms': {
        'join': {
          for (var r = 0; r < rooms; r++)
            '!room$r:example.com': {
              'timeline': {
                'limited': false,
                'prev_batch': 'p$r',
                'events': [
                  for (var e = 0; e < events; e++)
                    {
                      'type': 'm.room.message',
                      'event_id': '\$e$r-$e',
                      'sender': '@user$e:example.com',
                      'origin_server_ts': 1700000000000 + e,
                      'content': {
                        'msgtype': 'm.text',
                        'body': 'message $e in room $r 你好',
                      },
                    },
                ],
              },
              'state': {
                'events': [
                  {
                    'type': 'm.room.name',
                    'event_id': '\$name$r',
                    'sender': '@user0:example.com',
                    'origin_server_ts': 1700000000000,
                    'state_key': '',
                    'content': {'name': 'Room $r'},
                  },
                ],
              },
              'unread_notifications': {
                'notification_count': r,
                'highlight_count': 0,
              },
            },
        },
      },
    };

Uint8List encode(Object? json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

/// `/sync` bodies of at least [syncUpdateIsolateDecodeThreshold] bytes are
/// decoded on another isolate. The result and the errors must be exactly the
/// same as decoding in place.
void main() {
  test('small and large bodies decode to the same SyncUpdate as in place',
      () async {
    for (final body in [encode(syncJson(2, 3)), encode(syncJson(400, 10))]) {
      final decoded = await decodeSyncUpdate(body);
      expect(
        jsonEncode(decoded.toJson()),
        jsonEncode(decodeSyncUpdateInPlace(body).toJson()),
      );
    }
    expect(
      encode(syncJson(400, 10)).length,
      greaterThanOrEqualTo(syncUpdateIsolateDecodeThreshold),
      reason: 'the large body must take the isolate path',
    );
  });

  test('errors are the same on both paths', () async {
    final padding = 'x' * syncUpdateIsolateDecodeThreshold;
    final invalidJson = Uint8List.fromList(utf8.encode('{"a": "$padding"'));
    await expectLater(decodeSyncUpdate(invalidJson), throwsFormatException);
    await expectLater(
      decodeSyncUpdate(Uint8List.fromList(utf8.encode('{'))),
      throwsFormatException,
    );

    final notAnObject = encode([padding]);
    await expectLater(decodeSyncUpdate(notAnObject), throwsA(isA<TypeError>()));

    final invalidUtf8 = Uint8List(syncUpdateIsolateDecodeThreshold)..[0] = 0xff;
    await expectLater(decodeSyncUpdate(invalidUtf8), throwsFormatException);
  });

  test('large bodies do not block the event loop while decoding', () async {
    final body = encode(syncJson(3000, 10));
    final inPlace = Stopwatch()..start();
    decodeSyncUpdateInPlace(body);
    inPlace.stop();

    var longestGap = Duration.zero;
    final gap = Stopwatch()..start();
    final ticker = Timer.periodic(const Duration(milliseconds: 1), (_) {
      if (gap.elapsed > longestGap) longestGap = gap.elapsed;
      gap.reset();
    });
    final update = await decodeSyncUpdate(body);
    ticker.cancel();

    expect(update.rooms?.join, hasLength(3000));
    // Only meaningful when decoding in place takes a while on this machine.
    if (inPlace.elapsedMilliseconds >= 60) {
      expect(
        longestGap.inMilliseconds,
        lessThan(inPlace.elapsedMilliseconds ~/ 2),
        reason: 'in place ${inPlace.elapsedMilliseconds}ms, '
            'longest gap ${longestGap.inMilliseconds}ms',
      );
    }
  });
}
