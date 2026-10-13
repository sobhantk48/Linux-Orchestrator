import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/terminal_view.dart';

class TerminalGestureHandler extends StatefulWidget {
  const TerminalGestureHandler({
    Key? key,
    required this.terminalView,
    required this.terminalController,
    this.onTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.readOnly = false,
    required this.child,
  }) : super(key: key);

  final TerminalViewState terminalView;
  final TerminalController terminalController;
  final GestureTapUpCallback? onTapUp;
  final GestureTapDownCallback? onTapDown;
  final GestureTapDownCallback? onSecondaryTapDown;
  final GestureTapUpCallback? onSecondaryTapUp;
  final bool readOnly;
  final Widget child;

  @override
  State<TerminalGestureHandler> createState() => _TerminalGestureHandlerState();
}

class _TerminalGestureHandlerState extends State<TerminalGestureHandler> {
  Offset? _dragStart;

  RenderTerminal get renderTerminal => widget.terminalView.renderTerminal;
  TerminalController get controller => widget.terminalController;

  void _onDoubleTapDown(TapDownDetails details) {
    renderTerminal.selectWord(details.localPosition);
  }

  void _onPanStart(DragStartDetails details) {
    _dragStart = details.localPosition;
    if (details.kind != PointerDeviceKind.mouse) {
      renderTerminal.selectWord(details.localPosition);
    } else {
      renderTerminal.selectCharacters(details.localPosition);
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_dragStart != null) {
      renderTerminal.updateSelection(details.localPosition);
    }
  }

  void _onPanEnd(DragEndDetails details) {
    _dragStart = null;
  }

  void _onTapUp(TapUpDetails details) {
    controller.clearSelection();
    widget.onTapUp?.call(details);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (controller.shouldSendPointerInput(PointerInput.scroll)) {
        // Handled by controller/terminal
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      behavior: HitTestBehavior.translucent,
      child: GestureDetector(
        onTapDown: widget.onTapDown,
        onTapUp: _onTapUp,
        onSecondaryTapDown: widget.onSecondaryTapDown,
        onSecondaryTapUp: widget.onSecondaryTapUp,
        onDoubleTapDown: _onDoubleTapDown,
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        behavior: HitTestBehavior.translucent,
        child: widget.child,
      ),
    );
  }
}
