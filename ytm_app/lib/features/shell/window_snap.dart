import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as ffi_c;
import 'package:flutter/widgets.dart' show WidgetsBinding, Rect;
import 'package:window_manager/window_manager.dart';

/// The snap half-screen operations behind the maximize button's snap menu.
///
/// The Win32 maximize-button flyout ("Snap layouts") cannot be hosted by a
/// custom-drawn title bar: the OS only shows it over a native caption button,
/// which `TitleBarStyle.hidden` removes. These operations deliver the same
/// result through the menu this app draws — the window docks to the left or
/// right half of the *work area of the monitor it sits on*, restoring from
/// maximize first. (Win+Arrow OS snapping keeps working regardless.)
///
/// Work-area discovery is plain `user32` through `dart:ffi`
/// (`MonitorFromWindow` + `GetMonitorInfoW`), so the half-window lands on the
/// monitor the window is actually on rather than assuming the primary display.
class WindowSnap {
  WindowSnap._();

  static const int _monitorDefaultToNearest = 2;

  static const double _half = 0.5;

  static Future<void> snapLeft() => _snap(isLeft: true);

  static Future<void> snapRight() => _snap();

  static Future<void> _snap({bool isLeft = false}) async {
    if (!Platform.isWindows) return;

    final Rect workArea = _workArea();
    if (workArea == Rect.zero) {
      // No usable work area: leave the window where it is rather than
      // guessing half of zero.
      return;
    }
    final double halfWidth = workArea.width * _half;
    final Rect half = Rect.fromLTRB(
      isLeft ? workArea.left : workArea.left + halfWidth,
      workArea.top,
      isLeft ? workArea.left + halfWidth : workArea.right,
      workArea.bottom,
    );

    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    }
    // window_manager expects Flutter logical pixels and scales them itself;
    // GetMonitorInfoW reports physical pixels, so divide by the view's dpr.
    final double dpr =
        WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    await windowManager.setBounds(
      Rect.fromLTRB(
        half.left / dpr,
        half.top / dpr,
        half.right / dpr,
        half.bottom / dpr,
      ),
    );
  }

  /// The work area (clipped by the taskbar) of the monitor the focused window
  /// is on, in physical pixels. GetForegroundWindow is the app's own window:
  /// the menu that requested the snap is open inside it.
  static Rect _workArea() {
    final ffi.DynamicLibrary user32 = ffi.DynamicLibrary.open('user32.dll');

    final int Function() getForegroundWindow = user32
        .lookupFunction<ffi.IntPtr Function(), int Function()>(
          'GetForegroundWindow',
        );
    final int Function(int, int) monitorFromWindow = user32
        .lookupFunction<
          ffi.IntPtr Function(ffi.IntPtr, ffi.Uint32),
          int Function(int, int)
        >('MonitorFromWindow');
    final int Function(int, ffi.Pointer<_MonitorInfo>) getMonitorInfo = user32
        .lookupFunction<
          ffi.IntPtr Function(ffi.IntPtr, ffi.Pointer<_MonitorInfo>),
          int Function(int, ffi.Pointer<_MonitorInfo>)
        >('GetMonitorInfoW');

    final int window = getForegroundWindow();
    if (window == 0) return Rect.zero;
    final int monitor = monitorFromWindow(window, _monitorDefaultToNearest);
    if (monitor == 0) return Rect.zero;

    final ffi.Pointer<_MonitorInfo> info = ffi_c.calloc<_MonitorInfo>();
    try {
      info.ref.cbSize = ffi.sizeOf<_MonitorInfo>();
      final int ok = getMonitorInfo(monitor, info);
      if (ok == 0) return Rect.zero;
      final _Rect work = info.ref.rcWork;
      return Rect.fromLTRB(
        work.left.toDouble(),
        work.top.toDouble(),
        work.right.toDouble(),
        work.bottom.toDouble(),
      );
    } finally {
      ffi_c.calloc.free(info);
    }
  }
}

/// The part of [_MonitorInfo] this module reads.
final class _Rect extends ffi.Struct {
  @ffi.Int32()
  external int left;

  @ffi.Int32()
  external int top;

  @ffi.Int32()
  external int right;

  @ffi.Int32()
  external int bottom;
}

/// `user32.MONITORINFO` (Windows: always this layout on the versions the app
/// ships for).
final class _MonitorInfo extends ffi.Struct {
  @ffi.Int32()
  external int cbSize;

  external _Rect rcMonitor;

  external _Rect rcWork;

  @ffi.Uint32()
  external int dwFlags;
}
