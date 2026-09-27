import 'dart:async';
import 'dart:convert';

import 'package:sqflite_common/sqflite.dart';

import 'package:matrix/src/database/zone_transaction_mixin.dart';

/// Key-Value store abstraction over Sqflite so that the sdk database can use
/// a single interface for all platforms. API is inspired by Hive.
class BoxCollection with ZoneTransactionMixin {
  final Database _db;
  final Set<String> boxNames;
  final String name;

  BoxCollection(this._db, this.boxNames, this.name);

  static Future<BoxCollection> open(
    String name,
    Set<String> boxNames, {
    Object? sqfliteDatabase,
    DatabaseFactory? sqfliteFactory,
    dynamic idbFactory,
    int version = 1,
  }) async {
    if (sqfliteDatabase is! Database) {
      throw ('You must provide a Database `sqfliteDatabase` for use on native.');
    }
    final batch = sqfliteDatabase.batch();
    for (final name in boxNames) {
      batch.execute(
        'CREATE TABLE IF NOT EXISTS $name (k TEXT PRIMARY KEY NOT NULL, v TEXT)',
      );
      batch.execute('CREATE INDEX IF NOT EXISTS k_index ON $name (k)');
    }
    await batch.commit(noResult: true);
    return BoxCollection(sqfliteDatabase, boxNames, name);
  }

  Box<V> openBox<V>(String name) {
    if (!boxNames.contains(name)) {
      throw ('Box with name $name is not in the known box names of this collection.');
    }
    final box = Box<V>(name, this);
    _registerBox(box);
    return box;
  }

  /// 本集合开出的全部 Box，供事务失败时统一清空快取缓存。
  /// 用弱引用登记，避免让调用方已丢弃的 Box 常驻内存；Box 被回收后其缓存
  /// 也随之消失，无需再清。
  final List<WeakReference<Box>> _openedBoxes = [];

  /// 登记新开出的 Box，并顺手剔除已被回收的弱引用，防止列表无限增长。
  /// 同名 Box 开多次会得到多个实例（各自有缓存），因此按实例登记而非按名字。
  void _registerBox(Box box) {
    _openedBoxes.removeWhere((ref) => ref.target == null);
    _openedBoxes.add(WeakReference(box));
  }

  /// 清空本集合下全部 Box 的快取缓存，仅在事务失败时调用。
  /// 失败事务里的 put/delete 已改写缓存但 batch 未落盘，不清会留下「幻影」值，
  /// 后续读到幻影会误判数据已存在而跳过写入（例如时间线片段永不落盘）。
  ///
  /// 已知限制：清的是全部缓存，不区分键属于哪个 batch。若此刻还有别的未提交
  /// batch（嵌套事务的外层，或事务 zone 内并行派生的嵌套事务），它写过的键也被
  /// 清掉，之后回源读到库里的旧值：外层事务读不到自己的写，该 batch 提交后缓存
  /// 比库旧，对同键读改写还会覆盖已提交数据。只在「内层失败被外层吞掉」或并行
  /// 嵌套事务里出现，见 test/box_transaction_failure_test.dart 的特征测试。
  void _clearAllQuickAccessCaches() {
    for (final ref in _openedBoxes) {
      ref.target?.clearQuickAccessCache();
    }
  }

  Batch? _activeBatch;

  Future<void> transaction(
    Future<void> Function() action, {
    List<String>? boxNames,
    bool readOnly = false,
  }) =>
      zoneTransaction(() async {
        final batch = _db.batch();
        _activeBatch = batch;
        try {
          try {
            await action();
          } finally {
            // action 抛错时也必须复位，否则之后的非事务写会落进永不提交的
            // 孤儿 batch。成功路径与原实现一致：先置 null 再提交。
            _activeBatch = null;
          }
          await batch.commit(noResult: true);
        } catch (_) {
          // action 或提交失败：batch 未落盘，清掉缓存里的幻影后原样抛出。
          _clearAllQuickAccessCaches();
          rethrow;
        }
      });

  Future<void> clear() => transaction(
        () async {
          for (final name in boxNames) {
            await _db.delete(name);
          }
        },
      );

  Future<void> close() => zoneTransaction(() => _db.close());

  @Deprecated('use collection.deleteDatabase now')
  static Future<void> delete(String path, [dynamic factory]) =>
      (factory ?? databaseFactory).deleteDatabase(path);

  Future<void> deleteDatabase(String path, [dynamic factory]) async {
    await close();
    await (factory ?? databaseFactory).deleteDatabase(path);
  }
}

class Box<V> {
  final String name;
  final BoxCollection boxCollection;
  final Map<String, V?> _quickAccessCache = {};

  /// _quickAccessCachedKeys is only used to make sure that if you fetch all keys from a
  /// box, you do not need to have an expensive read operation twice. There is
  /// no other usage for this at the moment. So the cache is never partial.
  /// Once the keys are cached, they need to be updated when changed in put and
  /// delete* so that the cache does not become outdated.
  Set<String>? _quickAccessCachedKeys;

  static const Set<Type> allowedValueTypes = {
    List<dynamic>,
    Map<dynamic, dynamic>,
    String,
    int,
    double,
    bool,
  };

  Box(this.name, this.boxCollection) {
    if (!allowedValueTypes.any((type) => V == type)) {
      throw Exception(
        'Illegal value type for Box: "${V.toString()}". Must be one of $allowedValueTypes',
      );
    }
  }

  String? _toString(V? value) {
    if (value == null) return null;
    switch (V) {
      case const (List<dynamic>):
      case const (Map<dynamic, dynamic>):
        return jsonEncode(value);
      case const (String):
      case const (int):
      case const (double):
      case const (bool):
      default:
        return value.toString();
    }
  }

  V? _fromString(Object? value) {
    if (value == null) return null;
    if (value is! String) {
      throw Exception(
        'Wrong database type! Expected String but got one of type ${value.runtimeType}',
      );
    }
    switch (V) {
      case const (int):
        return int.parse(value) as V;
      case const (double):
        return double.parse(value) as V;
      case const (bool):
        return (value == 'true') as V;
      case const (List<dynamic>):
        return List.unmodifiable(jsonDecode(value)) as V;
      case const (Map<dynamic, dynamic>):
        return Map.unmodifiable(jsonDecode(value)) as V;
      case const (String):
      default:
        return value as V;
    }
  }

  Future<List<String>> getAllKeys([Transaction? txn]) async {
    if (_quickAccessCachedKeys != null) return _quickAccessCachedKeys!.toList();

    final executor = txn ?? boxCollection._db;

    final result = await executor.query(name, columns: ['k']);
    final keys = result.map((row) => row['k'] as String).toList();

    _quickAccessCachedKeys = keys.toSet();
    return keys;
  }

  Future<Map<String, V>> getAllValues([Transaction? txn]) async {
    final executor = txn ?? boxCollection._db;

    final result = await executor.query(name);
    return Map.fromEntries(
      result.map(
        (row) => MapEntry(
          row['k'] as String,
          _fromString(row['v']) as V,
        ),
      ),
    );
  }

  Future<V?> get(String key, [Transaction? txn]) async {
    if (_quickAccessCache.containsKey(key)) return _quickAccessCache[key];

    final executor = txn ?? boxCollection._db;

    final result = await executor.query(
      name,
      columns: ['v'],
      where: 'k = ?',
      whereArgs: [key],
    );

    final value = result.isEmpty ? null : _fromString(result.single['v']);
    _quickAccessCache[key] = value;
    return value;
  }

  Future<List<V?>> getAll(List<String> keys, [Transaction? txn]) async {
    if (!keys.any((key) => !_quickAccessCache.containsKey(key))) {
      return keys.map((key) => _quickAccessCache[key]).toList();
    }

    // The SQL operation might fail with more than 1000 keys. We define some
    // buffer here and half the amount of keys recursively for this situation.
    const getAllMax = 800;
    if (keys.length > getAllMax) {
      final half = keys.length ~/ 2;
      return [
        ...(await getAll(keys.sublist(0, half))),
        ...(await getAll(keys.sublist(half))),
      ];
    }

    final executor = txn ?? boxCollection._db;

    final list = <V?>[];

    final result = await executor.query(
      name,
      where: 'k IN (${keys.map((_) => '?').join(',')})',
      whereArgs: keys,
    );
    final resultMap = Map<String, V?>.fromEntries(
      result.map((row) => MapEntry(row['k'] as String, _fromString(row['v']))),
    );

    // We want to make sure that they values are returnd in the exact same
    // order than the given keys. That's why we do this instead of just return
    // `resultMap.values`.
    list.addAll(keys.map((key) => resultMap[key]));

    _quickAccessCache.addAll(resultMap);

    return list;
  }

  Future<void> put(String key, V val) async {
    final txn = boxCollection._activeBatch;

    final params = {
      'k': key,
      'v': _toString(val),
    };
    if (txn == null) {
      await boxCollection._db.insert(
        name,
        params,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } else {
      txn.insert(
        name,
        params,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    _quickAccessCache[key] = val;
    _quickAccessCachedKeys?.add(key);
    return;
  }

  Future<void> delete(String key, [Batch? txn]) async {
    txn ??= boxCollection._activeBatch;

    if (txn == null) {
      await boxCollection._db.delete(name, where: 'k = ?', whereArgs: [key]);
    } else {
      txn.delete(name, where: 'k = ?', whereArgs: [key]);
    }

    // Set to null instead remove() so that inside of transactions null is
    // returned.
    _quickAccessCache[key] = null;
    _quickAccessCachedKeys?.remove(key);
    return;
  }

  Future<void> deleteAll(List<String> keys, [Batch? txn]) async {
    txn ??= boxCollection._activeBatch;

    final placeholder = keys.map((_) => '?').join(',');
    if (txn == null) {
      await boxCollection._db.delete(
        name,
        where: 'k IN ($placeholder)',
        whereArgs: keys,
      );
    } else {
      txn.delete(
        name,
        where: 'k IN ($placeholder)',
        whereArgs: keys,
      );
    }

    for (final key in keys) {
      _quickAccessCache[key] = null;
      _quickAccessCachedKeys?.removeAll(keys);
    }
    return;
  }

  void clearQuickAccessCache() {
    _quickAccessCache.clear();
    _quickAccessCachedKeys = null;
  }

  Future<void> clear([Batch? txn]) async {
    txn ??= boxCollection._activeBatch;

    if (txn == null) {
      await boxCollection._db.delete(name);
    } else {
      txn.delete(name);
    }

    clearQuickAccessCache();
  }
}
