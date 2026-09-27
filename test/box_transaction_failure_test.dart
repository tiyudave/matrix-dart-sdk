@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import 'package:matrix/matrix.dart';
import 'package:matrix/src/database/sqflite_box.dart';
import 'fake_database.dart';

/// 测试专用异常，用来校验事务失败时异常原样抛出（类型与实例不变）。
class _TestFailure implements Exception {
  @override
  String toString() => '_TestFailure';
}

/// 转发型 Database：只转发 BoxCollection/Box 用到的成员，并让首个 batch 的
/// commit 停在测试可控的闸门上，用来确定性地观察「提交在途」时的行为。
class _CommitGatedDatabase implements Database {
  _CommitGatedDatabase(this._inner);

  final Database _inner;

  /// 首个 batch 进入 commit 时完成。
  final commitStarted = Completer<void>();

  /// 测试放行后，被拦住的 commit 才真正提交。
  final releaseCommit = Completer<void>();

  @override
  Batch batch() => _CommitGatedBatch(_inner.batch(), this);

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) =>
      _inner.insert(
        table,
        values,
        nullColumnHack: nullColumnHack,
        conflictAlgorithm: conflictAlgorithm,
      );

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _inner.delete(table, where: where, whereArgs: whereArgs);

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试替身未转发 ${invocation.memberName}');
}

/// 配合 [_CommitGatedDatabase] 的 Batch：写操作原样转发，commit 先过闸门。
class _CommitGatedBatch implements Batch {
  _CommitGatedBatch(this._inner, this._db);

  final Batch _inner;
  final _CommitGatedDatabase _db;

  @override
  Future<List<Object?>> commit({
    bool? exclusive,
    bool? noResult,
    bool? continueOnError,
  }) async {
    if (!_db.commitStarted.isCompleted) _db.commitStarted.complete();
    await _db.releaseCommit.future;
    return _inner.commit(
      exclusive: exclusive,
      noResult: noResult,
      continueOnError: continueOnError,
    );
  }

  @override
  void insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) =>
      _inner.insert(
        table,
        values,
        nullColumnHack: nullColumnHack,
        conflictAlgorithm: conflictAlgorithm,
      );

  @override
  void delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _inner.delete(table, where: where, whereArgs: whereArgs);

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试替身未转发 ${invocation.memberName}');
}

void main() {
  group('BoxCollection 事务失败路径', () {
    late Database db;
    late BoxCollection collection;
    const boxNames = {'cats', 'dogs'};

    /// 绕过 Box 与快取缓存，直接读库里某个键的原始值。
    Future<String?> rawValue(String table, String key) async {
      final rows = await db.query(table, where: 'k = ?', whereArgs: [key]);
      return rows.isEmpty ? null : rows.single['v'] as String?;
    }

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(':memory:');
      collection = await BoxCollection.open(
        'testbox',
        boxNames,
        sqfliteDatabase: db,
        sqfliteFactory: databaseFactoryFfi,
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('action 抛错后 _activeBatch 已复位：之后的非事务写立即落盘', () async {
      final box = collection.openBox<String>('cats');

      await expectLater(
        collection.transaction(() async {
          await box.put('in_failed_tx', 'x');
          throw _TestFailure();
        }),
        throwsA(isA<_TestFailure>()),
      );

      // 若 _activeBatch 没复位，这些写会落进永不提交的孤儿 batch。
      await box.put('after_put', 'y');
      await box.put('to_delete', 'z');
      await box.delete('to_delete');
      await box.put('to_delete_all', 'w');
      await box.deleteAll(['to_delete_all']);

      expect(await rawValue('cats', 'after_put'), 'y');
      expect(await rawValue('cats', 'to_delete'), isNull);
      expect(await rawValue('cats', 'to_delete_all'), isNull);
      expect(await rawValue('cats', 'in_failed_tx'), isNull);

      // 之后的成功事务照常提交。
      await collection.transaction(() async {
        await box.put('next_tx', 'ok');
      });
      expect(await rawValue('cats', 'next_tx'), 'ok');
    });

    test('action 抛错后不留幻影：get 返回库里真实值，getAllKeys 不含幻影键', () async {
      final box = collection.openBox<String>('cats');
      await box.put('existing', 'old');
      await box.put('to_delete', 'keep');
      await box.put('to_delete_all', 'keep_too');
      // 预热键缓存，确认失败后键缓存也被作废。
      expect(
        await box.getAllKeys(),
        unorderedEquals(['existing', 'to_delete', 'to_delete_all']),
      );

      await expectLater(
        collection.transaction(() async {
          await box.put('existing', 'phantom');
          await box.put('phantom_key', 'phantom');
          await box.delete('to_delete');
          await box.deleteAll(['to_delete_all']);
          // 事务内仍能读到本事务的写（读己之写，成功路径语义不变）。
          expect(await box.get('existing'), 'phantom');
          throw _TestFailure();
        }),
        throwsA(isA<_TestFailure>()),
      );

      expect(await box.get('existing'), 'old');
      expect(await box.get('phantom_key'), isNull);
      expect(await box.get('to_delete'), 'keep');
      expect(await box.get('to_delete_all'), 'keep_too');
      expect(
        await box.getAll(['existing', 'phantom_key', 'to_delete']),
        ['old', null, 'keep'],
      );
      expect(
        await box.getAllKeys(),
        unorderedEquals(['existing', 'to_delete', 'to_delete_all']),
      );
    });

    test('batch.commit 抛错后不留幻影、异常原样抛出、之后的非事务写能落盘', () async {
      await db.execute(
        "CREATE TRIGGER cats_boom BEFORE INSERT ON cats WHEN NEW.k = 'boom' "
        "BEGIN SELECT RAISE(ABORT, 'boom'); END",
      );
      final box = collection.openBox<String>('cats');
      await box.put('existing', 'old');
      expect(await box.getAllKeys(), ['existing']);

      await expectLater(
        collection.transaction(() async {
          await box.put('existing', 'phantom');
          await box.put('fresh', 'phantom');
          // action 本身成功，提交时被触发器打断，整个 batch 回滚。
          await box.put('boom', 'x');
        }),
        throwsA(
          isA<DatabaseException>().having(
            (e) => e.toString(),
            'toString()',
            contains('boom'),
          ),
        ),
      );

      expect(await rawValue('cats', 'existing'), 'old');
      expect(await rawValue('cats', 'fresh'), isNull);
      expect(await box.get('existing'), 'old');
      expect(await box.get('fresh'), isNull);
      expect(await box.get('boom'), isNull);
      expect(await box.getAllKeys(), ['existing']);

      await box.put('after_put', 'y');
      expect(await rawValue('cats', 'after_put'), 'y');
    });

    test('失败清缓存覆盖同一 BoxCollection 下的所有 Box（含同名多实例）', () async {
      final cats = collection.openBox<String>('cats');
      final catsAgain = collection.openBox<String>('cats');
      final dogs = collection.openBox<Map>('dogs');
      await cats.put('c', 'old_cat');
      await dogs.put('d', {'name': 'old_dog'});
      // 让第二个同名实例也缓存上旧值。
      expect(await catsAgain.get('c'), 'old_cat');

      await expectLater(
        collection.transaction(() async {
          await cats.put('c', 'phantom_cat');
          await catsAgain.put('c2', 'phantom_cat2');
          await dogs.put('d', {'name': 'phantom_dog'});
          await dogs.put('d2', {'name': 'phantom_dog2'});
          throw _TestFailure();
        }),
        throwsA(isA<_TestFailure>()),
      );

      expect(await cats.get('c'), 'old_cat');
      expect(await catsAgain.get('c'), 'old_cat');
      expect(await catsAgain.get('c2'), isNull);
      expect(await cats.get('c2'), isNull);
      expect(await dogs.get('d'), {'name': 'old_dog'});
      expect(await dogs.get('d2'), isNull);
    });

    test('成功路径不清缓存：成功事务后绕过 Box 改库，get 仍返回缓存值', () async {
      final cats = collection.openBox<String>('cats');
      final dogs = collection.openBox<String>('dogs');
      await dogs.put('cached_before', 'dog_cached');

      await collection.transaction(() async {
        await cats.put('k1', 'v1');
      });
      expect(await rawValue('cats', 'k1'), 'v1');

      await db.update(
        'cats',
        {'v': 'changed'},
        where: 'k = ?',
        whereArgs: ['k1'],
      );
      await db.update(
        'dogs',
        {'v': 'changed'},
        where: 'k = ?',
        whereArgs: ['cached_before'],
      );

      expect(await cats.get('k1'), 'v1');
      expect(await dogs.get('cached_before'), 'dog_cached');
    });

    test('成功路径先置 null 再提交：提交在途时的非事务写直接落盘', () async {
      final gated = _CommitGatedDatabase(db);
      final gatedCollection = BoxCollection(gated, boxNames, 'gated');
      final box = gatedCollection.openBox<String>('cats');

      final tx = gatedCollection.transaction(() async {
        await box.put('in_tx', 'a');
      });
      await gated.commitStarted.future;

      // action 已结束、batch 提交在途。Box.put 只看 _activeBatch 字段，若顺序
      // 反成「先提交再置 null」，这条写会进正在提交的 batch 而不是直接落盘。
      await box.put('during_commit', 'v');
      expect(await rawValue('cats', 'during_commit'), 'v');
      expect(await rawValue('cats', 'in_tx'), isNull);

      gated.releaseCommit.complete();
      await tx;
      expect(await rawValue('cats', 'in_tx'), 'a');
    });

    test('嵌套事务成功路径与现状一致：内层提交后外层后续写直接落盘', () async {
      final box = collection.openBox<String>('cats');

      await collection.transaction(() async {
        await box.put('outer_before', 'a');
        await collection.transaction(() async {
          await box.put('inner', 'b');
        });
        // 既有怪癖：内层成功会把 _activeBatch 置 null 并提交内层 batch，
        // 之后外层的写不再进外层 batch 而是直接落盘。
        expect(await rawValue('cats', 'inner'), 'b');
        await box.put('outer_after', 'c');
        expect(await rawValue('cats', 'outer_after'), 'c');
        // 外层 batch 尚未提交。
        expect(await rawValue('cats', 'outer_before'), isNull);
      });

      expect(await rawValue('cats', 'outer_before'), 'a');

      // 嵌套成功也不清缓存。
      await db.update(
        'cats',
        {'v': 'changed'},
        where: 'k = ?',
        whereArgs: ['inner'],
      );
      expect(await box.get('inner'), 'b');
    });

    for (final innerCommitFails in [false, true]) {
      final label = innerCommitFails ? '内层提交失败' : '内层 action 抛错';
      test('嵌套事务$label并向外传播：外层 batch 不提交、无幻影、之后非事务写能落盘', () async {
        await db.execute(
          "CREATE TRIGGER cats_boom BEFORE INSERT ON cats WHEN NEW.k = 'boom' "
          "BEGIN SELECT RAISE(ABORT, 'boom'); END",
        );
        final box = collection.openBox<String>('cats');
        await box.put('K', 'old');

        await expectLater(
          collection.transaction(() async {
            await box.put('K', 'outer');
            await box.put('outer_only', 'o');
            await collection.transaction(() async {
              await box.put('inner_only', 'i');
              if (innerCommitFails) {
                // 内层 action 成功，内层 batch 提交时被触发器打断。
                await box.put('boom', 'x');
              } else {
                throw _TestFailure();
              }
            });
          }),
          throwsA(
            innerCommitFails ? isA<DatabaseException>() : isA<_TestFailure>(),
          ),
        );

        expect(await rawValue('cats', 'K'), 'old');
        expect(await rawValue('cats', 'outer_only'), isNull);
        expect(await rawValue('cats', 'inner_only'), isNull);
        expect(await box.get('K'), 'old');
        expect(await box.get('outer_only'), isNull);
        expect(await box.get('inner_only'), isNull);

        await box.put('after', 'a');
        expect(await rawValue('cats', 'after'), 'a');
      });
    }

    // 特征测试：锁定「内层失败被外层吞掉」的当前语义，其中 K 的两条断言是已知
    // 限制（失败时全量清缓存，连外层未提交的写也清掉）。若日后改语义（如在最外层
    // 事务结束时再清一次缓存），须同步改这里的断言。
    test('嵌套事务内层失败被外层吞掉：内层无幻影、外层后续写直接落盘（含已知限制）', () async {
      final box = collection.openBox<String>('cats');
      await box.put('K', 'old');

      await collection.transaction(() async {
        // 进外层 batch，尚未提交。
        await box.put('K', 'new');
        try {
          await collection.transaction(() async {
            await box.put('X', 'inner');
            throw _TestFailure();
          });
        } on _TestFailure {
          // 模拟 requestUser(ignoreErrors: true) 这类吞掉内层异常的调用方。
        }
        // 内层失败已把 _activeBatch 复位为 null，外层之后的写直接落盘（非原子）。
        await box.put('Y', 'after_inner');
        expect(await rawValue('cats', 'Y'), 'after_inner');
        // 已知限制：外层读不到自己刚写的 K，回源读到库里的旧值。
        expect(await box.get('K'), 'old');
      });

      expect(await rawValue('cats', 'K'), 'new');
      expect(await rawValue('cats', 'X'), isNull);
      expect(await box.get('X'), isNull);
      expect(await box.get('Y'), 'after_inner');
      // 已知限制：外层提交后 K 的缓存仍是回源读到的旧值，与库不一致。
      expect(await box.get('K'), 'old');
    });

    test('事务进行中其它 zone 的非事务写：事务失败后 get 与库一致', () async {
      final box = collection.openBox<String>('cats');
      final gate = Completer<void>();

      final tx = collection.transaction(() async {
        await box.put('in_tx', 't');
        await gate.future;
        throw _TestFailure();
      });
      // 既有行为：Box.put 只看 _activeBatch 字段，事务进行中其它 zone 的写也会
      // 落进事务的 batch，随事务失败一起丢弃。
      await Zone.root.run(() => box.put('other_zone', 'z'));
      gate.complete();
      await expectLater(tx, throwsA(isA<_TestFailure>()));

      expect(await rawValue('cats', 'other_zone'), isNull);
      expect(await box.get('other_zone'), isNull);
      expect(await box.get('in_tx'), isNull);
    });

    test('异常原样 rethrow：类型与实例都不变（含非 Exception 对象）', () async {
      final error = _TestFailure();
      Object? caught;
      try {
        await collection.transaction(() async {
          throw error;
        });
      } catch (e) {
        caught = e;
      }
      expect(identical(caught, error), isTrue);

      const plain = 'plain string error';
      Object? caughtPlain;
      try {
        await collection.transaction(() async {
          throw plain;
        });
      } catch (e) {
        caughtPlain = e;
      }
      expect(identical(caughtPlain, plain), isTrue);
    });
  });

  group('MatrixSdkDatabase 事务失败回归', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('box_tx_failure_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('事务失败后同批重投：时间线片段必须落盘（重投丢时间线回归）', () async {
      Logs().level = Level.error;
      final path = '${tempDir.path}/regression.sqlite';
      final client = Client('testclient');
      final room = Room(id: '!f1room:example.org', client: client);
      final event = MatrixEvent.fromJson({
        'type': 'm.room.message',
        'origin_server_ts': 100,
        'content': <String, dynamic>{'msgtype': 'm.text', 'body': 'hello'},
        'event_id': '\$f1-event',
        'sender': '@alice:example.org',
      });

      var database = await getMatrixSdkDatabase(client, path: path);

      // 第一次投递：写完事件后事务失败，batch 不提交。
      await expectLater(
        database.transaction(() async {
          await database.storeEventUpdate(
            room.id,
            event,
            EventUpdateType.timeline,
            client,
          );
          throw _TestFailure();
        }),
        throwsA(isA<_TestFailure>()),
      );

      // 同批重投：成功事务里再存同一事件。
      await database.transaction(() async {
        await database.storeEventUpdate(
          room.id,
          event,
          EventUpdateType.timeline,
          client,
        );
      });

      // 裸查时间线片段表，确认片段已落盘。
      final rows = await database.database!.query(
        'box_timeline_fragments',
        where: 'k = ?',
        whereArgs: [TupleKey(room.id, '').toString()],
      );
      expect(rows, hasLength(1));
      expect(rows.single['v'] as String, contains('\$f1-event'));

      // 关闭后重开同一文件库（缓存全新），时间线里必须有该事件。
      await database.close();
      database = await getMatrixSdkDatabase(client, path: path);
      final events = await database.getEventList(room);
      expect(events.map((e) => e.eventId), contains('\$f1-event'));
      await database.close();
    });

    // 覆盖「先读缓存再按条件写」的另外两条路径：SENDING 片段移除与 removeEvent。
    // 原实现下重投读到幻影而跳过写入，库里只剩卡在发送中的 txn 片段。
    test('事务失败后同批重投服务器回显：SENDING 片段移除与 removeEvent 必须落盘', () async {
      Logs().level = Level.error;
      final path = '${tempDir.path}/sending.sqlite';
      final client = Client('testclient');
      final room = Room(id: '!f1sending:example.org', client: client);
      const transactionId = 'f1-txn';
      const realEventId = '\$f1-real';
      Event buildEvent(String eventId, EventStatus status, int ts) => Event(
            status: status,
            content: <String, dynamic>{'msgtype': 'm.text', 'body': 'hi'},
            type: 'm.room.message',
            eventId: eventId,
            senderId: '@me:example.org',
            originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
            unsigned: {'transaction_id': transactionId},
            room: room,
          );
      final sending = buildEvent(transactionId, EventStatus.sending, 1);
      final echo = buildEvent(realEventId, EventStatus.synced, 2);

      var database = await getMatrixSdkDatabase(client, path: path);
      Future<void> store(Event event) => database.storeEventUpdate(
            room.id,
            event,
            EventUpdateType.timeline,
            client,
          );

      /// 绕过缓存裸查某个时间线片段。
      Future<List<dynamic>?> rawFragment(String part) async {
        final rows = await database.database!.query(
          'box_timeline_fragments',
          where: 'k = ?',
          whereArgs: [TupleKey(room.id, part).toString()],
        );
        if (rows.isEmpty) return null;
        return jsonDecode(rows.single['v'] as String) as List<dynamic>;
      }

      // 本地发送中的消息先落盘。
      await database.transaction(() => store(sending));
      expect(await rawFragment('SENDING'), [transactionId]);

      // 服务器回显第一次投递：写完后事务失败，batch 不提交。
      await expectLater(
        database.transaction(() async {
          await store(echo);
          throw _TestFailure();
        }),
        throwsA(isA<_TestFailure>()),
      );

      // 同批重投。
      await database.transaction(() => store(echo));

      expect(await rawFragment('SENDING'), isEmpty);
      expect(await rawFragment(''), [realEventId]);
      final txnRows = await database.database!.query(
        'box_events',
        where: 'k = ?',
        whereArgs: [TupleKey(room.id, transactionId).toString()],
      );
      expect(txnRows, isEmpty);

      // 关闭后重开（缓存全新）：只剩真正的消息，没有卡在发送中的那条。
      await database.close();
      database = await getMatrixSdkDatabase(client, path: path);
      final events = await database.getEventList(room);
      expect(events.map((e) => e.eventId), [realEventId]);
      await database.close();
    });
  });
}
