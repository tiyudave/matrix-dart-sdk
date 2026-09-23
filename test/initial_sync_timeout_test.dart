import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:test/test.dart';

import 'fake_database.dart';

void main() {
  test('does not duplicate a slow initial sync request', () async {
    final api = _DelayedInitialSyncMatrixApi();
    final client = Client(
      'slow-initial-sync-client',
      httpClient: api,
      databaseBuilder: getDatabase,
    )..syncErrorTimeoutSec = 0;

    final initFuture = runZoned(
      () => client.init(
        newToken: 'abcd',
        newUserID: '@test:fakeServer.notExisting',
        newHomeserver: Uri.parse('https://fakeserver.notexisting'),
        newDeviceName: 'Slow Initial Sync Client',
        newDeviceID: 'SLOWINITIALSYNC',
      ),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          final scaledDuration = duration == const Duration(seconds: 10)
              ? const Duration(milliseconds: 10)
              : duration;
          return parent.createTimer(zone, scaledDuration, callback);
        },
      ),
    );

    try {
      await api.firstInitialSyncStarted;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(api.initialSyncRequestCount, 1);
    } finally {
      api.completeInitialSync();
      await initFuture;
      await client.abortSync();
      await client.dispose();
    }
  });
}

class _DelayedInitialSyncMatrixApi extends FakeMatrixApi {
  final Completer<void> _initialSyncCompleter = Completer<void>();
  final Completer<void> _firstInitialSyncStarted = Completer<void>();
  int initialSyncRequestCount = 0;

  Future<void> get firstInitialSyncStarted => _firstInitialSyncStarted.future;

  void completeInitialSync() {
    if (!_initialSyncCompleter.isCompleted) {
      _initialSyncCompleter.complete();
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/sync') &&
        !request.url.queryParameters.containsKey('since')) {
      initialSyncRequestCount++;
      if (!_firstInitialSyncStarted.isCompleted) {
        _firstInitialSyncStarted.complete();
      }
      await _initialSyncCompleter.future;
    }
    return super.send(request);
  }
}
