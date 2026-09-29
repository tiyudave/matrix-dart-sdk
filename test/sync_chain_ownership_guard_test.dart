/// F3（同步链归属守卫，[Client.guardSyncChainOwnership]）的行为测试。
///
/// 上游缺陷：[Client.abortSync] 把当前链置空后并不等旧链结束；旧链停在
/// cleaningUp 阶段或在途的 sync() 上时，调用方随后拉起新链（clearCache 末尾的
/// `backgroundSync = true`），旧链收尾会清掉新链的记录并再起一条，两条同步链并发。
/// 开关关闭（缺省）的用例锁住上游现状，证明开关关闭时行为不变、且用例能识别缺陷；
/// 开关打开的用例证明同一时序下只有一条链，正常的续起不受影响。
library;

import 'dart:async';
import 'dart:collection';

import 'package:test/test.dart';

import 'package:matrix/matrix.dart';
import 'fake_database.dart';

/// 等待「应当发生的事」的上限；超时即判定用例失败。
const _eventTimeout = Duration(seconds: 5);

/// 判定「不该发生的事确实没发生」之前的观察窗口，让可能出现的多余链有机会冒头。
const _settleWindow = Duration(milliseconds: 100);

/// 测试入口：缺省值一组，另按开关关闭、打开各跑一遍同样的时序。
///
/// 开关关闭的断言是上游现状（含缺陷），开关打开的断言是 F3 的目标行为。
void main() {
  group('缺省值', () {
    test('Client 缺省不开启同步链归属守卫', () {
      final client = Client(
        'sync-chain-guard-default',
        httpClient: FakeMatrixApi(),
        databaseBuilder: getDatabase,
      );
      expect(client.guardSyncChainOwnership, isFalse);
    });
  });
  _abortThenClearCacheTests();
  _clearCacheOnlyTests();
  _parkedInSyncTests();
  _noRestartTests();
  _normalLoopTests();
}

/// D-09 验证口径：cleaningUp 阶段先 abortSync、随后 clearCache。
///
/// 关闭时旧链收尾清掉新链并再起一条（并发 2）；打开时只有新链（并发恒为 1），
/// 新链完成后照常续起下一轮。
void _abortThenClearCacheTests() {
  group('cleaningUp 阶段先 abortSync、随后 clearCache', () {
    test('开关关闭（上游现状）：旧链收尾清掉新链并再起一条，同一时刻并发 2', () async {
      final client = await _prepareClient(guard: false);
      final scene = await _parkChainInCleaningUp(client);
      await client.abortSync();
      await client.clearCache();
      await _expectNewChainEntered(client, scene.holdB);

      scene.gate.release();
      await scene.chainA.timeout(_eventTimeout);
      final callC = await scene.holdC.entered.timeout(_eventTimeout);

      expect(callC.since, isNull, reason: '旧链收尾又起了一条从头开始的链');
      expect(client.inFlightSyncs, 2, reason: '新链仍在途，旧链收尾又起了第二条');
      expect(client.maxInFlightSyncs, 2);
    });

    test('开关打开：旧链收尾不碰新链，同一时刻并发恒为 1，新链完成后照常续起', () async {
      final client = await _prepareClient(guard: true);
      final scene = await _parkChainInCleaningUp(client);
      await client.abortSync();
      await client.clearCache();
      await _expectNewChainEntered(client, scene.holdB);

      scene.gate.release();
      await scene.chainA.timeout(_eventTimeout);
      await Future<void>.delayed(_settleWindow);

      expect(scene.holdC.hasEntered, isFalse, reason: '旧链收尾不得再起链');
      expect(client.inFlightSyncs, 1);
      expect(client.maxInFlightSyncs, 1);
      expect(client.syncPending, isTrue, reason: '新链的记录没有被旧链清掉');

      await _expectNormalRestart(client, scene);
    });
  });
}

/// cleaningUp 阶段直接 clearCache（ignoreUser、unignoreUser、`/clearcache` 的路径）。
///
/// clearCache 内部先 abortSync 再在末尾拉起新链，时序与上一组等价。
void _clearCacheOnlyTests() {
  group('cleaningUp 阶段直接 clearCache', () {
    test('开关关闭（上游现状）：并发 2', () async {
      final client = await _prepareClient(guard: false);
      final scene = await _parkChainInCleaningUp(client);
      await client.clearCache();
      await _expectNewChainEntered(client, scene.holdB);

      scene.gate.release();
      await scene.chainA.timeout(_eventTimeout);
      await scene.holdC.entered.timeout(_eventTimeout);

      expect(client.inFlightSyncs, 2);
      expect(client.maxInFlightSyncs, 2);
    });

    test('开关打开：并发恒为 1', () async {
      final client = await _prepareClient(guard: true);
      final scene = await _parkChainInCleaningUp(client);
      await client.clearCache();
      await _expectNewChainEntered(client, scene.holdB);

      scene.gate.release();
      await scene.chainA.timeout(_eventTimeout);
      await Future<void>.delayed(_settleWindow);

      expect(scene.holdC.hasEntered, isFalse);
      expect(client.inFlightSyncs, 1);
      expect(client.maxInFlightSyncs, 1);
      expect(client.syncPending, isTrue);

      await _expectNormalRestart(client, scene);
    });
  });
}

/// 旧链停在在途的 sync() 上时 abortSync + clearCache。
///
/// 旧请求本身不会被取消（上游只丢弃它的结果），所以新链进入时并发必然到 2；
/// 这里比的是旧结果回来之后：关闭时旧链收尾再起第三条链，打开时不再起链。
void _parkedInSyncTests() {
  group('旧链停在在途的 sync()', () {
    test('开关关闭（上游现状）：旧结果被丢弃后，旧链收尾再起一条，新链与它并发', () async {
      final client = await _prepareClient(guard: false);
      final scene = await _parkChainInSync(client);
      await client.abortSync();
      await client.clearCache();
      await scene.holdB.entered.timeout(_eventTimeout);

      scene.holdA.complete(SyncUpdate(nextBatch: 'chain_a'));
      await scene.chainA.timeout(_eventTimeout);
      await scene.holdC.entered.timeout(_eventTimeout);

      expect(client.inFlightSyncs, 2, reason: '新链与旧链收尾起的第三条链并发');
    });

    test('开关打开：旧结果被丢弃后不清新链、不再起链，在途数回到 1', () async {
      final client = await _prepareClient(guard: true);
      final scene = await _parkChainInSync(client);
      await client.abortSync();
      await client.clearCache();
      await scene.holdB.entered.timeout(_eventTimeout);

      scene.holdA.complete(SyncUpdate(nextBatch: 'chain_a'));
      await scene.chainA.timeout(_eventTimeout);
      await Future<void>.delayed(_settleWindow);

      expect(scene.holdC.hasEntered, isFalse);
      expect(client.inFlightSyncs, 1, reason: '只剩新链在途');
      expect(client.syncPending, isTrue);
      expect(client.prevBatch, isNull, reason: '被丢弃的旧结果没有推进游标');
    });
  });
}

/// abortSync 之后没有任何人拉起新链：开关开与关的行为一致，旧链收尾不再起链。
///
/// 覆盖 dispose、logout 前的 abortSync 等「只停不起」的路径。
void _noRestartTests() {
  group('abortSync 后无人拉起新链', () {
    for (final guard in [false, true]) {
      test('开关${guard ? '打开' : '关闭'}：旧链收尾后不起链、syncPending 为 false', () async {
        final client = await _prepareClient(guard: guard);
        final scene = await _parkChainInCleaningUp(client);
        final callsBefore = client.syncCalls.length;
        await client.abortSync();

        scene.gate.release();
        await scene.chainA.timeout(_eventTimeout);
        await Future<void>.delayed(_settleWindow);

        expect(client.syncCalls, hasLength(callsBefore));
        expect(client.syncPending, isFalse);
        expect(client.inFlightSyncs, 0);
      });
    }
  });
}

/// 正常的后台同步循环：开关打开时每轮收尾照常续起下一轮，任何时刻只有一条链。
///
/// 证明守卫只拦被放弃的旧链，不影响当前链的续起。
void _normalLoopTests() {
  group('正常后台循环', () {
    test('开关打开：每轮收尾照常续起下一轮，游标逐轮前进，并发恒为 1', () async {
      final client = await _prepareClient(guard: true);
      final callsBefore = client.syncCalls.length;
      client
        ..enqueueBatch(SyncUpdate(nextBatch: 'loop_1'))
        ..enqueueBatch(SyncUpdate(nextBatch: 'loop_2'))
        ..enqueueBatch(SyncUpdate(nextBatch: 'loop_3'));
      final parked = client.enqueueHold();

      client.backgroundSync = true;
      final call = await parked.entered.timeout(_eventTimeout);
      addTearDown(() async {
        client.backgroundSync = false;
        parked.complete(SyncUpdate(nextBatch: 'loop_4'));
        await _waitUntilIdle(client);
      });

      expect(
        client.syncCalls.skip(callsBefore).map((c) => c.since),
        [_initialBatch, 'loop_1', 'loop_2', 'loop_3'],
      );
      expect(call.since, 'loop_3');
      expect(client.maxInFlightSyncs, 1);
    });
  });
}

/// init 首轮同步（脚本为空时）返回的 `next_batch`。
const _initialBatch = 'sync_chain_initial';

/// 准备一个已登录、后台同步关闭、没有在途链的探针 Client。
///
/// init 之前先关后台同步，init 的首轮同步结束后不会续起，用例从空闲状态开始；
/// 重试延迟归零，免得错误路径等 3 秒。
Future<_ChainProbeClient> _prepareClient({required bool guard}) async {
  final client = _ChainProbeClient(guardSyncChainOwnership: guard)
    ..syncErrorTimeoutSec = 0
    ..backgroundSync = false;
  await client.init(
    newToken: 'abcd',
    newUserID: '@test:fakeServer.notExisting',
    newHomeserver: Uri.parse('https://fakeserver.notexisting'),
    newDeviceName: 'Sync Chain Guard Client',
    newDeviceID: 'SYNCCHAINGUARD',
  );
  expect(client.prevBatch, _initialBatch);
  expect(client.syncPending, isFalse);
  client.resetInFlightStats();
  addTearDown(() async {
    client.backgroundSync = false;
    client.releaseAllHolds();
    await _waitUntilIdle(client);
    await client.dispose();
  });
  return client;
}

/// 旧链停在 cleaningUp 的场景抓手：旧链 A 的 Future、挂住它的闸门，以及为新链 B、
/// 多余链 C 预排的两个挂起脚本项。
///
/// B 由 clearCache 末尾拉起的那条链吃到；C 只有旧链收尾再起链时才会被吃到。
typedef _CleaningUpScene = ({
  Future<void> chainA,
  _Gate gate,
  _SyncHold holdB,
  _SyncHold holdC,
});

/// 旧链停在在途 sync() 的场景抓手：旧链 A 的 Future 与它的在途请求，以及为 B、C
/// 预排的两个挂起脚本项。
///
/// B、C 的含义同 [_CleaningUpScene]。
typedef _InSyncScene = ({
  Future<void> chainA,
  _SyncHold holdA,
  _SyncHold holdB,
  _SyncHold holdC,
});

/// 起旧链 A 并让它停在 cleaningUp（结果已提交、游标已前进、finished 未发），
/// 随后为 B、C 预排挂起项。
///
/// 返回时 A 仍是当前链。
Future<_CleaningUpScene> _parkChainInCleaningUp(
  _ChainProbeClient client,
) async {
  final gate = client.holdNextCleaningUp();
  client.enqueueBatch(SyncUpdate(nextBatch: 'chain_a'));
  final chainA = client.oneShotSync();
  await gate.entered.timeout(_eventTimeout);
  expect(client.prevBatch, 'chain_a');
  return (
    chainA: chainA,
    gate: gate,
    holdB: client.enqueueHold(),
    holdC: client.enqueueHold(),
  );
}

/// 起旧链 A 并让它停在在途的 sync() 上，随后为 B、C 预排挂起项。
///
/// 返回时 A 仍是当前链，它的请求尚未返回。
Future<_InSyncScene> _parkChainInSync(_ChainProbeClient client) async {
  final holdA = client.enqueueHold();
  final chainA = client.oneShotSync();
  await holdA.entered.timeout(_eventTimeout);
  return (
    chainA: chainA,
    holdA: holdA,
    holdB: client.enqueueHold(),
    holdC: client.enqueueHold(),
  );
}

/// 断言 clearCache 拉起的新链 B 已进入 sync()：从头同步，且此刻只有它在途。
///
/// 旧链 A 停在 cleaningUp 时它的请求早已返回，所以在途数恰为 1。
Future<void> _expectNewChainEntered(
  _ChainProbeClient client,
  _SyncHold holdB,
) async {
  final callB = await holdB.entered.timeout(_eventTimeout);
  expect(callB.since, isNull, reason: 'clearCache 之后从头同步');
  expect(client.inFlightSyncs, 1);
}

/// 开关打开时的收尾核对：新链 B 完成后按后台同步设置照常续起下一轮（吃到 C），
/// 并发仍恒为 1。
///
/// 证明守卫没有误拦当前链自己的续起。
Future<void> _expectNormalRestart(
  _ChainProbeClient client,
  _CleaningUpScene scene,
) async {
  scene.holdB.complete(SyncUpdate(nextBatch: 'chain_b'));
  final callC = await scene.holdC.entered.timeout(_eventTimeout);

  expect(callC.since, 'chain_b', reason: '续起的一轮沿用新链推进后的游标');
  expect(client.inFlightSyncs, 1);
  expect(client.maxInFlightSyncs, 1);
}

/// 等到没有在途的 sync() 且没有当前链，再多给一个观察窗口让收尾跑完。
///
/// 用于收尾：先放行所有挂起项，再等循环真正停下，避免 dispose 撞上在途链。
Future<void> _waitUntilIdle(_ChainProbeClient client) async {
  final deadline = DateTime.now().add(_eventTimeout);
  while (client.inFlightSyncs > 0 || client.syncPending) {
    if (DateTime.now().isAfter(deadline)) {
      fail('同步链没有在 $_eventTimeout 内停下');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await Future<void>.delayed(_settleWindow);
}

/// 一次 `sync()` 调用的入参快照（只记用例关心的 since 与 timeout）。
///
/// 由 [_ChainProbeClient.sync] 在进入时创建。
class _SyncCall {
  /// 记录本次调用的游标与长轮询时长。
  ///
  /// 两个字段与 `Api.sync` 的同名参数一致。
  _SyncCall({required this.since, required this.timeout});

  /// since 参数。
  final String? since;

  /// 服务端长轮询 timeout（毫秒）。
  final int? timeout;
}

/// 被挂起的一次 `sync()`：先等它进入，再由用例决定何时返回。
///
/// 预排后若从未被调用到，[hasEntered] 保持 false，用来断言「没有多余的链」。
class _SyncHold {
  final Completer<_SyncCall> _entered = Completer<_SyncCall>();
  final Completer<SyncUpdate> _response = Completer<SyncUpdate>();

  /// SDK 调用到这一项时完成，值为本次调用的入参快照。
  ///
  /// 用例据此确认请求已经在途。
  Future<_SyncCall> get entered => _entered.future;

  /// 这一项是否已被某条链调用到。
  ///
  /// 为 false 说明预排后没有链吃到它。
  bool get hasEntered => _entered.isCompleted;

  /// 以同步批完成这次在途请求；尚未进入或已完成时忽略。
  ///
  /// 一律以值完成：错误不能跨 error zone（B 由 runInRoot 拉起，在 root zone）。
  void complete(SyncUpdate update) {
    if (!_entered.isCompleted || _response.isCompleted) return;
    _response.complete(update);
  }

  /// 作为脚本项被调用：标记已进入并返回挂起的结果。
  ///
  /// 只由 [_ChainProbeClient.sync] 调用。
  Future<SyncUpdate> _respond(_SyncCall call) {
    _entered.complete(call);
    return _response.future;
  }
}

/// 把同步链挂在 cleaningUp 阶段（`updateUserDeviceKeys` 入口）的一次性闸门。
///
/// 进入时本轮结果已提交、游标已前进、cleaningUp 已发出，finished 未发。
class _Gate {
  final Completer<void> _entered = Completer<void>();
  final Completer<void> _released = Completer<void>();

  /// 同步链到达闸门时完成。
  ///
  /// 用例据此确认旧链已停在 cleaningUp。
  Future<void> get entered => _entered.future;

  /// 放行：同步链继续执行 cleaningUp 余下步骤并发出 finished；重复调用忽略。
  ///
  /// 收尾时也会调用，保证没有链永远卡在闸门上。
  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

/// 按脚本应答 `sync()` 的测试 Client，记录并发数，可把同步链挂在 cleaningUp 阶段。
///
/// 不改 SDK 的同步流程，只替换网络层的 sync 请求与 cleaningUp 入口的时序。
class _ChainProbeClient extends Client {
  /// 以内存库与 FakeMatrixApi 构造；[guardSyncChainOwnership] 决定是否开启 F3。
  ///
  /// 客户端名按开关区分，便于在日志里分辨两组用例。
  _ChainProbeClient({required this.guardSyncChainOwnership})
      : super(
          'sync-chain-guard-${guardSyncChainOwnership ? 'on' : 'off'}',
          httpClient: FakeMatrixApi(),
          databaseBuilder: getDatabase,
        );

  /// F3 开关：由构造参数决定（生产里由子类固定覆写）。
  @override
  final bool guardSyncChainOwnership;

  /// 每次 `sync()` 的入参，按调用顺序记录。
  final List<_SyncCall> syncCalls = [];

  /// 当前尚未返回的 `sync()` 调用数。
  int inFlightSyncs = 0;

  /// 自上次 [resetInFlightStats] 以来同时在途的 `sync()` 最大值。
  int maxInFlightSyncs = 0;

  final Queue<Future<SyncUpdate> Function(_SyncCall call)> _script =
      Queue<Future<SyncUpdate> Function(_SyncCall call)>();

  final List<_SyncHold> _holds = [];

  _Gate? _cleaningUpGate;

  final List<_Gate> _gates = [];

  /// 追加一个直接返回 [update] 的脚本项（先进先出）。
  ///
  /// SDK 会原地修改批次，同一对象不要重复入队。
  void enqueueBatch(SyncUpdate update) =>
      _script.add((_) => Future<SyncUpdate>.value(update));

  /// 追加一个挂起的脚本项并返回其控制句柄。
  ///
  /// 调用到这一项时请求在途，直到用例调用 [_SyncHold.complete]。
  _SyncHold enqueueHold() {
    final hold = _SyncHold();
    _holds.add(hold);
    _script.add(hold._respond);
    return hold;
  }

  /// 挂住下一次 `updateUserDeviceKeys`（即下一轮同步的 cleaningUp 阶段）。
  ///
  /// 只作用一次；放行前本轮不会发出 finished。
  _Gate holdNextCleaningUp() {
    final gate = _Gate();
    _gates.add(gate);
    return _cleaningUpGate = gate;
  }

  /// 把并发统计清零，让用例只统计场景本身（不含 init 的首轮）。
  ///
  /// 调用时应当没有在途请求。
  void resetInFlightStats() => maxInFlightSyncs = inFlightSyncs;

  /// 收尾：丢弃未消费的脚本，放行全部闸门，并以空批完成全部已进入的挂起项。
  ///
  /// 之后的 `sync()` 走缺省空批，保证循环能停下。
  void releaseAllHolds() {
    _script.clear();
    for (final gate in _gates) {
      gate.release();
    }
    for (final hold in _holds) {
      hold.complete(SyncUpdate(nextBatch: 'released'));
    }
  }

  /// 记录入参与并发数，按脚本应答；脚本为空时返回沿用 since 的空批。
  ///
  /// 不发任何网络请求；并发计数在结果返回时递减。
  @override
  Future<SyncUpdate> sync({
    String? filter,
    String? since,
    bool? fullState,
    PresenceType? setPresence,
    int? timeout,
  }) {
    final call = _SyncCall(since: since, timeout: timeout);
    syncCalls.add(call);
    final responder =
        _script.isEmpty ? _defaultResponse : _script.removeFirst();
    inFlightSyncs++;
    if (inFlightSyncs > maxInFlightSyncs) maxInFlightSyncs = inFlightSyncs;
    return responder(call).whenComplete(() => inFlightSyncs--);
  }

  /// 脚本为空时的缺省应答：空批，token 沿用 since（首轮取 [_initialBatch]）。
  ///
  /// 空批不推进游标，循环据此空转到用例关掉后台同步为止。
  static Future<SyncUpdate> _defaultResponse(_SyncCall call) =>
      Future<SyncUpdate>.value(
        SyncUpdate(nextBatch: call.since ?? _initialBatch),
      );

  /// 有闸门时先在这里挂住（cleaningUp 阶段），放行后再交给 super。
  ///
  /// 闸门只作用一次，之后的轮次直接交给 super。
  @override
  Future<void> updateUserDeviceKeys({Set<String>? additionalUsers}) async {
    final gate = _cleaningUpGate;
    if (gate != null) {
      _cleaningUpGate = null;
      gate._entered.complete();
      await gate._released.future;
    }
    return super.updateUserDeviceKeys(additionalUsers: additionalUsers);
  }
}
