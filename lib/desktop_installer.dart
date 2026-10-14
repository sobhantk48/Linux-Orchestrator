import 'dart:io';
import 'package:flutter/services.dart';

class DesktopInstaller {
  static const String ubuntuRoot = '/data/ubuntu';
  static const String targetBundlePath = '$ubuntuRoot/tmp/desktop_bundle.tar.gz';

  /// بررسی و آماده‌سازی باندل دسکتاپ در مسیر چروت اوبونتو
  static Future<bool> prepareAndRunSetup({Function(String)? onLog}) void async {
    void log(String msg) {
      if (onLog != null) onLog(msg);
    }

    try {
      log('[+] Checking desktop bundle requirements...');

      // ۱. بررسی وجود پوشه tmp در روت اوبونتو
      final tmpDir = Directory('$ubuntuRoot/tmp');
      if (!await tmpDir.exists()) {
        await Process.run('su', ['-c', 'mkdir -p $ubuntuRoot/tmp && chmod 1777 $ubuntuRoot/tmp']);
      }

      // ۲. بررسی وجود فایل در مسیر مقصد
      final checkBundle = await Process.run('su', ['-c', '[ -f $targetBundlePath ] && echo "exists" || echo "missing"']);
      if (!checkBundle.stdout.toString().contains('exists')) {
        log('[+] Copying desktop bundle from assets...');
        
        // خواندن از Asset و نوشتن به کش محلی موقت
        final byteData = await rootBundle.load('assets/desktop_bundle.tar.gz');
        final tempFile = File('/data/local/tmp/desktop_bundle.tar.gz');
        await tempFile.writeAsBytes(byteData.buffer.asUint8List(), flush: true);

        // انتقال با دسترسی روت به چروت
        await Process.run('su', ['-c', 'mv /data/local/tmp/desktop_bundle.tar.gz $targetBundlePath && chmod 644 $targetBundlePath']);
        log('[+] Desktop bundle placed in /tmp.');
      } else {
        log('[✓] Desktop bundle already present in /tmp.');
      }

      // ۳. کپی و آماده‌سازی setup_desktop.sh
      final scriptData = await rootBundle.loadString('assets/scripts/setup_desktop.sh');
      final tempScript = File('/data/local/tmp/setup_desktop.sh');
      await tempScript.writeAsString(scriptData, flush: true);

      await Process.run('su', ['-c', 'mv /data/local/tmp/setup_desktop.sh $ubuntuRoot/tmp/setup_desktop.sh && chmod +x $ubuntuRoot/tmp/setup_desktop.sh']);

      // ۴. اجرای اسکریپت با دستور chroot
      log('[+] Running setup_desktop.sh inside chroot...');
      final result = await Process.run('su', [
        '-c',
        'chroot $ubuntuRoot /bin/bash /tmp/setup_desktop.sh'
      ]);

      log(result.stdout.toString());
      if (result.stderr.toString().isNotEmpty) {
        log('[!] Stderr: ${result.stderr}');
      }

      log('[✓] Desktop environment setup completed.');
      return true;
    } catch (e) {
      log('[✗] Desktop setup failed: $e');
      return false;
    }
  }
}
