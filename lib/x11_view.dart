import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class X11DisplayView extends StatefulWidget {
  final String socketName;
  final VoidCallback? onBackToTerminal;

  const X11DisplayView({
    super.key,
    this.socketName = 'sobhan_x11_frame',
    this.onBackToTerminal,
  });

  @override
  State<X11DisplayView> createState() => _X11DisplayViewState();
}

class _X11DisplayViewState extends State<X11DisplayView> {
  static const MethodChannel _channel = MethodChannel('com.sobhan.term/x11_display');

  int? _textureId;
  int _width = 0;
  int _height = 0;
  bool _isLoading = true;
  String? _errorMessage;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _startDisplay();
  }

  Future<void> _startDisplay() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await _channel.invokeMethod<Map>('startDisplay', {
        'socketName': widget.socketName,
      });

      if (result != null && mounted) {
        setState(() {
          _textureId = result['textureId'] as int?;
          _width = (result['width'] as int?) ?? 0;
          _height = (result['height'] as int?) ?? 0;
          _isLoading = false;
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.message ?? 'خطا در اتصال به سرور گرافیکی X11';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _stopDisplay() async {
    try {
      await _channel.invokeMethod('stopDisplay');
    } catch (_) {}
  }

  void _sendTouchEvent(int type, Offset localPosition, Size renderSize) {
    if (_width <= 0 || _height <= 0 || renderSize.width <= 0 || renderSize.height <= 0) {
      return;
    }

    final double scaleX = _width / renderSize.width;
    final double scaleY = _height / renderSize.height;

    final int targetX = (localPosition.dx * scaleX).clamp(0, _width - 1).toInt();
    final int targetY = (localPosition.dy * scaleY).clamp(0, _height - 1).toInt();

    _channel.invokeMethod('sendTouchEvent', {
      'type': type,
      'x': targetX,
      'y': targetY,
    });
  }

  void _toggleKeyboard() {
    if (_focusNode.hasFocus) {
      _focusNode.unfocus();
    } else {
      FocusScope.of(context).requestFocus(_focusNode);
      SystemChannels.textInput.invokeMethod('TextInput.show');
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _stopDisplay();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        color: const Color(0xFF1E1E1E),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF388E3C)),
              SizedBox(height: 12),
              Text(
                'در حال اتصال به سرور تصویر X11...',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Container(
        color: const Color(0xFF1E1E1E),
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
              const SizedBox(height: 10),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF388E3C),
                ),
                onPressed: _startDisplay,
                icon: const Icon(Icons.refresh, color: Colors.white),
                label: const Text('تلاش مجدد', style: TextStyle(color: Colors.white)),
              ),
              if (widget.onBackToTerminal != null) ...[
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: widget.onBackToTerminal,
                  icon: const Icon(Icons.arrow_back, color: Colors.white70),
                  label: const Text('بازگشت به ترمینال', style: TextStyle(color: Colors.white70)),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (_textureId != null) {
      return Stack(
        children: [
          // فیلد مخفی برای پذیرش رویدادهای کیبورد و فعال کردن کیبورد نرم‌افزاری
          Positioned(
            left: -100,
            top: -100,
            width: 1,
            height: 1,
            child: TextField(
              focusNode: _focusNode,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (text) {
                // ارسال مستقیم متن به متد چنل در صورت نیاز
              },
            ),
          ),
          // نمایشگر اصلی X11
          Positioned.fill(
            child: Container(
              color: Colors.black,
              child: Center(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox(
                    width: _width > 0 ? _width.toDouble() : 1280,
                    height: _height > 0 ? _height.toDouble() : 720,
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (event) => _sendTouchEvent(0, event.localPosition, Size(_width.toDouble(), _height.toDouble())),
                      onPointerMove: (event) => _sendTouchEvent(1, event.localPosition, Size(_width.toDouble(), _height.toDouble())),
                      onPointerUp: (event) => _sendTouchEvent(2, event.localPosition, Size(_width.toDouble(), _height.toDouble())),
                      onPointerCancel: (event) => _sendTouchEvent(2, event.localPosition, Size(_width.toDouble(), _height.toDouble())),
                      child: Texture(textureId: _textureId!),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // نوار کنترل شناور و شیشه‌ای بالای صفحه (بدون اشغال فضای دسکتاپ)
          Positioned(
            top: 10,
            right: 10,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(160),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white24, width: 0.8),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.keyboard, color: Colors.white, size: 20),
                    tooltip: 'کیبورد',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: _toggleKeyboard,
                  ),
                  const SizedBox(width: 4),
                  if (widget.onBackToTerminal != null)
                    IconButton(
                      icon: const Icon(Icons.terminal, color: Colors.greenAccent, size: 20),
                      tooltip: 'بازگشت به ترمینال',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      onPressed: widget.onBackToTerminal,
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}
