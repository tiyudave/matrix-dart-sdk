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
import 'dart:typed_data';

import 'package:matrix/matrix_api_lite/model/sync_update.dart';
import 'package:matrix/matrix_api_lite/utils/run_off_main_isolate_stub.dart'
    if (dart.library.isolate) 'package:matrix/matrix_api_lite/utils/run_off_main_isolate_io.dart';

/// Sync responses at least this large are decoded on a short lived isolate.
///
/// Below it, spawning an isolate costs about as much as decoding in place;
/// long poll responses of a running sync loop are usually far smaller.
const int syncUpdateIsolateDecodeThreshold = 256 * 1024;

/// Decodes a `/sync` response body (UTF-8 JSON) into a [SyncUpdate].
///
/// Initial syncs and catch-up syncs of large accounts are several megabytes;
/// decoding them in place (UTF-8, JSON, then [SyncUpdate.fromJson]) used to
/// block the main isolate in one piece. Bodies of at least
/// [syncUpdateIsolateDecodeThreshold] bytes are decoded with `Isolate.run`
/// instead: the body is copied in once and the decoded objects are handed
/// back without copying. On platforms without isolates (web) everything is
/// decoded in place as before. Errors are the same in both cases.
Future<SyncUpdate> decodeSyncUpdate(Uint8List body) {
  if (body.length < syncUpdateIsolateDecodeThreshold) {
    return Future.sync(() => decodeSyncUpdateInPlace(body));
  }
  return runOffMainIsolate(_decoderFor(body));
}

/// The computation sent to the isolate. Built in a plain (non async) function
/// so that the closure captures nothing but [body].
SyncUpdate Function() _decoderFor(Uint8List body) =>
    () => decodeSyncUpdateInPlace(body);

/// Decodes [body] on the current isolate.
SyncUpdate decodeSyncUpdateInPlace(Uint8List body) {
  final json = jsonDecode(utf8.decode(body));
  return SyncUpdate.fromJson(json as Map<String, Object?>);
}
