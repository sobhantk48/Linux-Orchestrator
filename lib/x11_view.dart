import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class X11View extends StatefulWidget {
  final VoidCallback onBackToTerminal;

  const X11View({super.key, required this.onBackToTerminal});

  @override
  State<X11View> createState() => _X11ViewState();
}

class _X11ViewState extends State<X11View> {
  static const MethodChannel _channel = MethodChannel('com.sobhan.term/x11_display');
  final FocusNode _focusNode = FocusNode();
  final TextEditingController _textController = TextEditingController();
  bool _isConnected = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    try {
      final res = await _channel.invokeMethod('connectTouch');
      if (res == true && mounted) {
        setState(() {
          _isConnected = true;
        });
      }
    } catch (_) {}
  }

  void _sendKey(int keysym) {
    if (!_isConnected) return;
    _channel.invokeMethod('sendKeyEvent', {'type': 3, 'keysym': keysym});
    Future.delayed(const Duration(milliseconds: 30), () {
      _channel.invokeMethod('sendKeyEvent', {'type': 4, 'keysym': keysym});
    });
  }

  void _handleTextInput(String text) {
    if (text.isEmpty) return;
    for (int i = 0; i < text.length; i++) {
      int code = text.codeUnitAt(i);
      _sendKey(code);
    }
    _textController.clear();
  }

  void _sendTouchEvent(int type, Offset pos, Size size) {
    if (!_isConnected) return;
    int targetW = 2400;
    int targetH = 1080;
    int x = ((pos.dx / size.width) * targetW).clamp(0, targetW).toInt();
    int y = ((pos.dy / size.height) * targetH).clamp(0, targetH).toInt();

    _channel.invokeMethod('sendTouchEvent', {'type': type, 'x': x, 'y': y});
  }

  @override
  void dispose() {
    _channel.invokeMethod('disconnectTouch');
    _focusNode.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanDown: (details) {
              _sendTouchEvent(0, details.localPosition, screenSize);
              _sendTouchEvent(1, details.localPosition, screenSize);
            },
            onPanUpdate: (details) {
              _sendTouchEvent(0, details.localPosition, screenSize);
            },
            onPanEnd: (_) {
              _channel.invokeMethod('sendTouchEvent', {'type': 2, 'x': 0, 'y': 0});
            },
            onPanCancel: () {
              _channel.invokeMethod('sendTouchEvent', {'type': 2, 'x': 0, 'y': 0});
            },
            child: const SizedBox.expand(),
          ),
          Positioned(
            left: -100,
            top: -100,
            width: 1,
            height: 1,
            child: KeyboardListener(
              focusNode: _focusNode,
              onKeyEvent: (event) {
                if (event is KeyDownEvent) {
                  if (event.logicalKey == LogicalKeyboardKey.backspace) {
                    _sendKey(0xff08);
                  } else if (event.logicalKey == LogicalKeyboardKey.enter) {
                    _sendKey(0xff0d);
                  } else if (event.logicalKey == LogicalKeyboardKey.tab) {
                    _sendKey(0xff09);
                  } else if (event.logicalKey == LogicalKeyboardKey.escape) {
                    _sendKey(0xff1b);
                  }
                }
              },
              child: TextField(
                controller: _textController,
                autofocus: false,
                onChanged: _handleTextInput,
                decoration: const InputDecoration(border: InputBorder.none),
              ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'kbd_toggle',
                  backgroundColor: Colors.blueGrey.shade800,
                  onPressed: () {
                    FocusScope.of(context).requestFocus(_focusNode);
                    SystemChannels.textInput.invokeMethod('TextInput.show');
                  },
                  child: const Icon(Icons.keyboard, color: Colors.white),
                ),
                const SizedBox(width: 8),
                FloatingActionButton.small(
                  heroTag: 'back_term',
                  backgroundColor: Colors.blueGrey.shade800,
                  onPressed: widget.onBackToTerminal,
                  child: const Icon(Icons.terminal, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
