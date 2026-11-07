import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// SOB-USER: مدل و دیالوگ ساخت کاربر لینوکس در اولین نصب.
// فقط نام کاربری ذخیره می‌شود؛ رمز یک‌بار برای chpasswd استفاده می‌شود.
// ---------------------------------------------------------------------------

class LinuxUser {
  final String username;
  final String password;

  const LinuxUser({required this.username, required this.password});

  static final RegExp _nameRe = RegExp(r'^[a-z][a-z0-9_-]{2,31}$');

  static const List<String> reservedNames = <String>[
    'root',
    'daemon',
    'bin',
    'sys',
    'sync',
    'games',
    'man',
    'lp',
    'mail',
    'news',
    'uucp',
    'proxy',
    'backup',
    'list',
    'irc',
    'gnats',
    'nobody',
    'systemd',
    'messagebus',
    'sshd',
    'ubuntu',
    'admin',
    'user',
  ];

  static bool isValidName(String v) => _nameRe.hasMatch(v.trim());

  static bool isReserved(String v) =>
      reservedNames.contains(v.trim().toLowerCase());

  static bool isValidPassword(String v) => v.length >= 4;

  /// پیام خطای نام کاربری یا رشتهٔ خالی اگر معتبر باشد.
  static String nameError(String v) {
    final String s = v.trim();
    if (s.isEmpty) return 'نام کاربری را وارد کنید';
    if (isReserved(s)) return 'این نام رزرو شده است';
    if (!isValidName(s)) {
      return 'فقط حروف کوچک انگلیسی، عدد، خط تیره و آندرلاین؛ شروع با حرف؛ ۳ تا ۳۲ نویسه';
    }
    return '';
  }

  /// پیام خطای رمز یا رشتهٔ خالی اگر معتبر باشد.
  static String passwordError(String v, String confirm) {
    if (v.isEmpty) return 'رمز عبور را وارد کنید';
    if (!isValidPassword(v)) return 'رمز باید حداقل ۴ نویسه باشد';
    if (v != confirm) return 'تکرار رمز مطابقت ندارد';
    return '';
  }
}

/// دیالوگ اولین اجرا: نام کاربری + رمز + تکرار رمز.
class LinuxUserSetupDialog extends StatefulWidget {
  final String initialName;

  const LinuxUserSetupDialog({super.key, this.initialName = ''});

  @override
  State<LinuxUserSetupDialog> createState() => _LinuxUserSetupDialogState();
}

class _LinuxUserSetupDialogState extends State<LinuxUserSetupDialog> {
  late final TextEditingController _name;
  final TextEditingController _pass = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  bool _obscure = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _name.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _name.text.trim();
    final String p1 = _pass.text;
    final String p2 = _confirm.text;

    String err = LinuxUser.nameError(name);
    if (err.isEmpty) err = LinuxUser.passwordError(p1, p2);
    if (err.isNotEmpty) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, LinuxUser(username: name, password: p1));
  }

  InputDecoration _deco(String hint, IconData icon) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
        prefixIcon: Icon(icon, color: Colors.white38, size: 18),
        isDense: true,
        enabledBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: Colors.white24)),
        focusedBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: Color(0xFF00E676))),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF111111),
      title: const Text(
        'ساخت کاربر لینوکس',
        style: TextStyle(color: Colors.white, fontSize: 16),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'این کاربر ساخته می‌شود و میزکار با همین حساب بالا می‌آید. '
              'دسترسی sudo هم دارد.',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: _deco('نام کاربری', Icons.person_outline),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _pass,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: _deco('رمز عبور', Icons.lock_outline),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _confirm,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: _deco('تکرار رمز عبور', Icons.lock_outline),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Checkbox(
                  value: _obscure,
                  activeColor: const Color(0xFF00E676),
                  onChanged: (bool? v) =>
                      setState(() => _obscure = v ?? true),
                ),
                const Text(
                  'پنهان‌سازی رمز',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _error,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('انصراف',
              style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('ساخت کاربر',
              style: TextStyle(color: Color(0xFF00E676))),
        ),
      ],
    );
  }
}

/// نمایش دیالوگ و برگرداندن نتیجه؛ null یعنی انصراف.
Future<LinuxUser?> showLinuxUserSetup(
  BuildContext context, {
  String initialName = '',
}) {
  return showDialog<LinuxUser>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) =>
        LinuxUserSetupDialog(initialName: initialName),
  );
}
