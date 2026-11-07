import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Bridges the soft keyboard (IME) to [onInput] using a real, tiny TextField
/// that owns the text input connection.
class ImeBridge extends StatefulWidget {
  const ImeBridge({
    super.key,
    required this.onInput,
    required this.child,
    this.autofocus = false,
    this.onKeyEvent,
    this.onPaste,
  });

  final void Function(String text) onInput;
  final Widget child;
  final bool autofocus;
  final FocusOnKeyEventCallback? onKeyEvent;

  /// M4: called instead of [onInput] for multi-line text so the owner can wrap
  /// it in bracketed-paste markers when the terminal enabled that mode.
  final void Function(String text)? onPaste;

  @override
  State<ImeBridge> createState() => ImeBridgeState();
}

class ImeBridgeState extends State<ImeBridge> {
  static const String _sentinel = '  ';
  static const TextEditingValue _init = TextEditingValue(
    text: _sentinel,
    selection: TextSelection.collapsed(offset: 2),
  );

  final TextEditingController _controller =
      TextEditingController.fromValue(_init);
  final FocusNode _focusNode = FocusNode(debugLabel: 'ime-bridge');
  bool _resetting = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _focusNode.addListener(_onFocusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.autofocus) requestKeyboard();
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _focusNode.removeListener(_onFocusChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool isKeyboardVisible = false;

  // M1: keep the flag in sync with real focus (system back button, IME close).
  void _onFocusChanged() {
    final bool has = _focusNode.hasFocus;
    if (mounted && has != isKeyboardVisible) {
      setState(() => isKeyboardVisible = has);
    }
  }

  Future<void> _textInput(String method) async {
    try {
      await SystemChannels.textInput.invokeMethod<void>(method);
    } catch (e) {
      debugPrint('[ImeBridge] $method failed: $e'); // M2
    }
  }

  void requestKeyboard() {
    if (!_focusNode.hasFocus) _focusNode.requestFocus();
    unawaited(_textInput('TextInput.show'));
    if (mounted) setState(() => isKeyboardVisible = true);
  }

  void hideKeyboard() {
    _focusNode.unfocus();
    unawaited(_textInput('TextInput.hide'));
    if (mounted) setState(() => isKeyboardVisible = false);
  }

  void toggleKeyboard() {
    if (isKeyboardVisible && _focusNode.hasFocus) {
      hideKeyboard();
    } else {
      requestKeyboard();
    }
  }

  void _onChanged() {
    if (_resetting) return;
    final String text = _controller.text;
    // M3: compare with the sentinel by common prefix, so replacements
    // (autocorrect) are handled as "backspace N + insert the rest".
    int p = 0;
    while (p < _sentinel.length &&
        p < text.length &&
        text.codeUnitAt(p) == _sentinel.codeUnitAt(p)) {
      p++;
    }
    final int backspaces = _sentinel.length - p;
    final String delta = text.substring(p);
    if (backspaces > 0) widget.onInput('\x7f' * backspaces);
    if (delta.isNotEmpty) {
      final String norm = delta.replaceAll('\r\n', '\n').replaceAll('\n', '\r');
      if (norm.contains('\r') && norm.length > 1 && widget.onPaste != null) {
        widget.onPaste!(norm);
      } else {
        widget.onInput(norm);
      }
    }
    _resetting = true;
    _controller.value = _init;
    _resetting = false;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: widget.onKeyEvent,
      child: Stack(
      children: <Widget>[
        // [kbfix3] tap دیگر کیبورد را باز نمی‌کند؛ فقط دکمهٔ KEYS.
        Positioned.fill(child: widget.child),
        Positioned(
          left: 0,
          top: 0,
          child: SizedBox(
            width: 2,
            height: 2,
            child: Opacity(
              opacity: 0.01,
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                autofocus: widget.autofocus,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => widget.onInput('\r'),
                style: const TextStyle(fontSize: 2),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
    );
  }
}
