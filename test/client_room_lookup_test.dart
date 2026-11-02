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

import 'dart:math';

import 'package:test/test.dart';

import 'package:matrix/matrix.dart';

/// [Client.getRoomById] answers from a self-validating position index. The
/// rooms list is public and mutated in place (insert, removeAt, sort, clear,
/// element replacement, setter), so every mutation must still give the same
/// answer as a plain linear scan.
void main() {
  late Client client;

  Room room(String id) => Room(id: id, client: client);

  Room? linearScan(String id) {
    for (final r in client.rooms) {
      if (r.id == id) return r;
    }
    return null;
  }

  setUp(() {
    client = Client('testclient');
    client.rooms = [for (var i = 0; i < 50; i++) room('!r$i:example.com')];
  });

  test('finds every room and returns null for unknown ids', () {
    for (final r in client.rooms) {
      expect(client.getRoomById(r.id), same(r));
    }
    expect(client.getRoomById('!unknown:example.com'), isNull);
  });

  test('insert at the front shifts every position', () {
    client.getRoomById('!r10:example.com');
    final invite = room('!invite:example.com');
    client.rooms.insert(0, invite);

    expect(client.getRoomById('!invite:example.com'), same(invite));
    expect(client.getRoomById('!r10:example.com')?.id, '!r10:example.com');
    expect(client.getRoomById('!r49:example.com')?.id, '!r49:example.com');
  });

  test('sorting in place keeps lookups correct', () {
    client.getRoomById('!r0:example.com');
    client.rooms.sort((a, b) => b.id.compareTo(a.id));

    for (var i = 0; i < 50; i++) {
      final id = '!r$i:example.com';
      expect(client.getRoomById(id), same(linearScan(id)));
    }
  });

  test('leave and join in one go (same length) does not return stale rooms',
      () {
    client.getRoomById('!r5:example.com');
    client.rooms.removeAt(5);
    final joined = room('!joined:example.com');
    client.rooms.add(joined);

    expect(client.getRoomById('!r5:example.com'), isNull);
    expect(client.getRoomById('!joined:example.com'), same(joined));
    expect(client.getRoomById('!r6:example.com')?.id, '!r6:example.com');
  });

  test('element replacement at the same position', () {
    client.getRoomById('!r7:example.com');
    final replacement = room('!replacement:example.com');
    client.rooms[7] = replacement;

    expect(client.getRoomById('!r7:example.com'), isNull);
    expect(client.getRoomById('!replacement:example.com'), same(replacement));
  });

  test('clear and the testing setter drop the old index', () {
    client.getRoomById('!r1:example.com');
    client.rooms.clear();
    expect(client.getRoomById('!r1:example.com'), isNull);

    final fresh = room('!r1:example.com');
    client.rooms = [fresh];
    expect(client.getRoomById('!r1:example.com'), same(fresh));
  });

  test('random mutations always match a linear scan', () {
    final random = Random(42);
    final ids = [for (var i = 0; i < 80; i++) '!r$i:example.com'];
    String? absentId() {
      final present = {for (final r in client.rooms) r.id};
      final candidates = ids.where((id) => !present.contains(id)).toList();
      return candidates.isEmpty
          ? null
          : candidates[random.nextInt(candidates.length)];
    }

    for (var step = 0; step < 3000; step++) {
      final rooms = client.rooms;
      switch (random.nextInt(6)) {
        case 0:
          final id = absentId();
          if (id != null) {
            rooms.insert(random.nextInt(rooms.length + 1), room(id));
          }
        case 1:
          if (rooms.isNotEmpty) rooms.removeAt(random.nextInt(rooms.length));
        case 2:
          rooms.shuffle(random);
        case 3:
          final id = absentId();
          if (id != null && rooms.isNotEmpty) {
            rooms[random.nextInt(rooms.length)] = room(id);
          }
        case 4:
          if (random.nextInt(50) == 0) rooms.clear();
        default:
          break;
      }
      final id = ids[random.nextInt(ids.length)];
      expect(
        client.getRoomById(id),
        same(linearScan(id)),
        reason: 'step $step',
      );
    }
  });
}
