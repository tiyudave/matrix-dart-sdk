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

import 'dart:convert';

import 'package:test/test.dart';

import 'package:matrix/matrix.dart';
import 'fake_database.dart';

/// `getUserDeviceKeys` buckets both key boxes by user id once instead of
/// filtering all keys for every user. User ids which are a prefix or an
/// extension of each other must never receive each other's keys.
void main() {
  const alice = '@alice:example.com';
  // User ids that share a prefix with [alice] or extend it.
  const neighbours = [
    '@alice:example.com2',
    '@alice:example.co',
    '@alic:example.com',
  ];

  late MatrixSdkDatabase database;
  late Client client;

  setUp(() async {
    client = Client('testclient');
    database = await getMatrixSdkDatabase(null);
  });

  tearDown(() => database.close());

  /// Stores a cross signing key that passes [CrossSigningKey.isValid] (it is
  /// not signature checked), so it shows up in the loaded [DeviceKeysList].
  Future<void> storeCrossSigningKey(String userId, String publicKey) =>
      database.storeUserCrossSigningKey(
        userId,
        publicKey,
        jsonEncode({
          'user_id': userId,
          'usage': ['master'],
          'keys': {'ed25519:$publicKey': publicKey},
        }),
        false,
        false,
      );

  test('returns nothing when no user is tracked', () async {
    await storeCrossSigningKey(alice, 'aliceKey');
    expect(await database.getUserDeviceKeys(client), isEmpty);
  });

  test('every tracked user only gets its own keys', () async {
    final users = [alice, ...neighbours];
    for (final userId in users) {
      await database.storeUserDeviceKeysInfo(userId, false);
      await storeCrossSigningKey(userId, 'key1 of $userId');
      await storeCrossSigningKey(userId, 'key2 of $userId');
    }
    // A user without any keys must not pick up keys of its neighbours.
    const lonely = '@alice:example.com3';
    await database.storeUserDeviceKeysInfo(lonely, false);

    final result = await database.getUserDeviceKeys(client);

    expect(result.keys.toSet(), {...users, lonely});
    for (final userId in users) {
      final list = result[userId]!;
      expect(list.userId, userId);
      expect(
        list.crossSigningKeys.keys.toSet(),
        {'key1 of $userId', 'key2 of $userId'},
      );
      expect(list.outdated, isFalse);
    }
    expect(result[lonely]!.crossSigningKeys, isEmpty);
    expect(result[lonely]!.deviceKeys, isEmpty);
  });

  test('device keys are attributed to the exact user', () async {
    // These device keys are not self signed, so loading them marks *their*
    // user outdated; a neighbouring user id must stay untouched.
    await database.storeUserDeviceKeysInfo(alice, false);
    await database.storeUserDeviceKeysInfo(neighbours.first, false);
    await database.storeUserDeviceKey(
      neighbours.first,
      'DEVICE',
      jsonEncode({
        'user_id': neighbours.first,
        'device_id': 'DEVICE',
        'algorithms': <String>[],
        'keys': <String, String>{},
      }),
      false,
      false,
      0,
    );

    final result = await database.getUserDeviceKeys(client);

    expect(result[neighbours.first]!.outdated, isTrue);
    expect(result[alice]!.outdated, isFalse);
  });
}
