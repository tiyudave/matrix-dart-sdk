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

/// Hands control back to the event loop once a CPU bound loop has kept the
/// isolate busy for longer than [slice].
///
/// Long synchronous loops (e.g. turning tens of thousands of stored rows into
/// objects at startup) otherwise run as one uninterrupted block. With Flutter's
/// merged platform/UI thread on Android, such a block also stalls input
/// handling and can trigger an ANR.
///
/// Check [shouldYield] synchronously and only `await` [yieldNow] when it is
/// true, so the loop does not pay a microtask hop for every item.
class EventLoopYielder {
  EventLoopYielder({this.slice = const Duration(milliseconds: 8)});

  /// Maximum time the loop may run between two yields.
  final Duration slice;

  final Stopwatch _watch = Stopwatch()..start();

  /// Whether the current slice is used up.
  bool get shouldYield => _watch.elapsed >= slice;

  /// Lets timers, I/O callbacks and platform messages run, then starts a new
  /// slice.
  Future<void> yieldNow() async {
    await Future<void>.delayed(Duration.zero);
    _watch.reset();
  }
}
