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

import 'package:test/test.dart';

import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/event_loop_yielder.dart';
import 'fake_database.dart';

/// `getRoomList` turns every stored room, preloaded state and room account
/// data row into objects at startup. It now hands control back to the event
/// loop every few milliseconds; the loaded rooms must stay exactly the same.
void main() {
  group('EventLoopYielder', () {
    test('asks to yield only after the slice is used up', () {
      final yielder = EventLoopYielder(slice: const Duration(milliseconds: 5));
      expect(yielder.shouldYield, isFalse);
      final busy = Stopwatch()..start();
      while (busy.elapsedMilliseconds < 6) {}
      expect(yielder.shouldYield, isTrue);
    });

    test('yieldNow lets pending timers run and starts a new slice', () async {
      final yielder = EventLoopYielder(slice: Duration.zero);
      var fired = false;
      Timer(Duration.zero, () => fired = true);
      await yielder.yieldNow();
      expect(fired, isTrue);
      expect(
        EventLoopYielder(slice: const Duration(hours: 1)).shouldYield,
        isFalse,
      );
    });
  });

  group('getRoomList', () {
    late MatrixSdkDatabase database;
    late Client client;
    var seq = 0;

    setUp(() async {
      client = Client('testclient');
      database = await getMatrixSdkDatabase(null);
    });

    tearDown(() => database.close());

    Future<void> storeRooms(int count, {int statesPerRoom = 1}) =>
        database.transaction(() async {
          for (var i = 0; i < count; i++) {
            final roomId = '!room$i:example.com';
            await database.storeRoomUpdate(
              roomId,
              JoinedRoomUpdate(),
              null,
              client,
            );
            await database.storeRoomAccountData(
              roomId,
              BasicEvent(type: 'm.test', content: {'room': roomId}),
            );
            for (var s = 0; s < statesPerRoom; s++) {
              await database.storeEventUpdate(
                roomId,
                MatrixEvent.fromJson({
                  'type': s == 0 ? EventTypes.RoomName : 'com.example.s$s',
                  'content': {'name': '$roomId/$s'},
                  'event_id': '\$event${seq++}',
                  'sender': '@alice:example.com',
                  'state_key': '',
                  'origin_server_ts': 0,
                }),
                EventUpdateType.state,
                client,
              );
            }
          }
        });

    test('loads every room with its states and account data', () async {
      await storeRooms(50);

      final rooms = await database.getRoomList(client);

      expect(rooms, hasLength(50));
      for (final room in rooms) {
        expect(
          room.getState(EventTypes.RoomName)?.content['name'],
          '${room.id}/0',
        );
        expect(room.roomAccountData['m.test']?.content['room'], room.id);
      }
    });

    test('never blocks the event loop for most of the load', () async {
      await storeRooms(2000, statesPerRoom: 5);

      var longestGap = Duration.zero;
      final gap = Stopwatch()..start();
      final ticker = Timer.periodic(const Duration(milliseconds: 1), (_) {
        if (gap.elapsed > longestGap) longestGap = gap.elapsed;
        gap.reset();
      });
      final total = Stopwatch()..start();
      final rooms = await database.getRoomList(client);
      total.stop();
      ticker.cancel();

      expect(rooms, hasLength(2000));
      // Only meaningful when loading took a while on this machine.
      if (total.elapsedMilliseconds >= 60) {
        expect(
          longestGap.inMilliseconds,
          lessThan(total.elapsedMilliseconds ~/ 2),
          reason: 'total ${total.elapsedMilliseconds}ms, '
              'longest gap ${longestGap.inMilliseconds}ms',
        );
      }
    });
  });
}
