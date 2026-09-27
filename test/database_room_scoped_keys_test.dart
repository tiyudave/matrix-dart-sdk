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

import 'package:test/test.dart';

import 'package:matrix/matrix.dart';
import 'fake_database.dart';

/// Room scoped lookups (`getUsers`, `getUnimportantRoomEventStatesForRoom`,
/// `getSingleRoom`) filter the keys of a whole box by room id. They use a
/// prefix match instead of splitting every key, so room ids which are a prefix
/// or an extension of each other must never leak into each other.
void main() {
  const roomId = '!abc:example.com';
  // Room ids that share a prefix with [roomId] or extend it.
  const neighbours = [
    '!abc:example.com2',
    '!abc:example.co',
    '!ab:example.com',
    '!abcd:example.com',
  ];

  late MatrixSdkDatabase database;
  late Client client;
  var seq = 0;

  setUp(() async {
    client = Client('testclient');
    database = await getMatrixSdkDatabase(null);
  });

  tearDown(() => database.close());

  Future<void> storeState(
    String room,
    String type,
    String stateKey,
    Map<String, Object?> content,
  ) =>
      database.storeEventUpdate(
        room,
        MatrixEvent.fromJson({
          'type': type,
          'content': content,
          'event_id': '\$event${seq++}',
          'sender': '@alice:example.com',
          'state_key': stateKey,
          'origin_server_ts': 0,
        }),
        EventUpdateType.state,
        client,
      );

  test('getUsers only returns members of the exact room', () async {
    await storeState(
      roomId,
      EventTypes.RoomMember,
      '@member:example.com',
      {'membership': 'join'},
    );
    for (final (index, neighbour) in neighbours.indexed) {
      await storeState(
        neighbour,
        EventTypes.RoomMember,
        '@neighbour$index:example.com',
        {'membership': 'join'},
      );
    }

    final users = await database.getUsers(Room(id: roomId, client: client));

    expect(users.map((user) => user.id), ['@member:example.com']);
  });

  test(
      'getUnimportantRoomEventStatesForRoom only returns states of the exact room',
      () async {
    await storeState(roomId, 'com.example.custom', '', {'value': 'mine'});
    await storeState(roomId, 'com.example.excluded', '', {'value': 'skip'});
    for (final neighbour in neighbours) {
      await storeState(neighbour, 'com.example.custom', '', {'value': 'other'});
    }

    final states = await database.getUnimportantRoomEventStatesForRoom(
      ['com.example.excluded'],
      Room(id: roomId, client: client),
    );

    expect(states.map((state) => state.content['value']), ['mine']);
  });

  test('getSingleRoom only loads account data and states of the exact room',
      () async {
    for (final id in [roomId, ...neighbours]) {
      await database.storeRoomUpdate(id, JoinedRoomUpdate(), null, client);
      await database.storeRoomAccountData(
        id,
        BasicEvent(type: 'm.test', content: {'room': id}),
      );
      await storeState(id, EventTypes.RoomName, '', {'name': id});
    }

    final room = await database.getSingleRoom(client, roomId);

    expect(room?.roomAccountData['m.test']?.content['room'], roomId);
    expect(room?.getState(EventTypes.RoomName)?.content['name'], roomId);
  });
}
