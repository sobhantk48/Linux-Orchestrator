package com.sobhan.term.my_terminal

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.*
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.*
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.tukaani.xz.XZInputStream
import java.io.DataInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.sobhan.term/linux_app"
    private var windowCounter = 1
    private var channel: MethodChannel? = null

    companion object {
        const val ACTION_LINUX_SHORTCUT = "com.sobhan.term.action.LINUX_SHORTCUT"
        private const val EXTRA_COMMAND = "command"
        private const val EXTRA_LABEL = "label"

        /** شورتکاتی که کاربر زده ولی Dart هنوز آن را برنداشته است. */
        @Volatile private var pendingShortcut: Map<String, String>? = null

        fun takePendingShortcut(): Map<String, String>? {
            val p = pendingShortcut
            pendingShortcut = null
            return p
        }

        /** کانال فعال Dart تا بتوانیم «بسته‌شدن پنجره» را به Dart خبر بدهیم. */
        @Volatile private var appChannelRef: MethodChannel? = null

        fun notifyDisplayClosed() {
            val ch = appChannelRef ?: return
            try {
                ch.invokeMethod("displayClosed", null)
            } catch (_: Exception) {
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureShortcutIntent(intent)
    }

    private fun captureShortcutIntent(incoming: Intent?) {
        if (incoming == null) return
        if (incoming.action != ACTION_LINUX_SHORTCUT) return
        val command = incoming.getStringExtra(EXTRA_COMMAND)?.trim().orEmpty()
        if (command.isEmpty()) return
        val label = incoming.getStringExtra(EXTRA_LABEL)?.trim().orEmpty().ifEmpty { command }
        pendingShortcut = mapOf("command" to command, "label" to label)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureShortcutIntent(intent)
        val payload = takePendingShortcut() ?: return
        val ch = channel
        if (ch == null) {
            pendingShortcut = payload
        } else {
            ch.invokeMethod("shortcutLaunched", payload)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = methodChannel
        appChannelRef = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "launchLinuxApp" -> {
                    val appTitle = call.argument<String>("title") ?: "Linux App #${windowCounter++}"
                    val framePort = call.argument<Int>("port") ?: 48001
                    val inputPort = call.argument<Int>("inputPort") ?: (framePort + 1)
                    val displayNum = call.argument<Int>("display") ?: ((framePort - 5566) / 2)
                    val rootDir = call.argument<String>("root") ?: "/data/ubuntu"

                    val intent = Intent(this, LinuxAppActivity::class.java).apply {
                        putExtra("APP_TITLE", appTitle)
                        putExtra("FRAME_PORT", framePort)
                        putExtra("INPUT_PORT", inputPort)
                        putExtra("DISPLAY_NUM", displayNum)
                        putExtra("ROOT_DIR", rootDir)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    }
                    startActivity(intent)
                    result.success("Launched $appTitle on port $framePort")
                }

                "createShortcut" -> {
                    val id = call.argument<String>("id")?.trim().orEmpty()
                    val label = call.argument<String>("label")?.trim().orEmpty()
                    val command = call.argument<String>("command")?.trim().orEmpty()
                    if (id.isEmpty() || label.isEmpty() || command.isEmpty()) {
                        result.error("bad_args", "id/label/command لازم است", null)
                    } else {
                        result.success(requestAppShortcut(id, label, command))
                    }
                }

                "removeShortcut" -> {
                    val id = call.argument<String>("id")?.trim().orEmpty()
                    result.success(removeAppShortcut(id))
                }

                "getPendingShortcut" -> {
                    val p = takePendingShortcut()
                    if (p == null) result.success(null) else result.success(p)
                }

                // #SOB-XZ-NATIVE
                // دیکود کردن .tar.xz داخل خود اپ (toybox اندروید xz ندارد).
                // فایل tar در cacheDir ساخته می‌شود و مسیرش برگردانده می‌شود؛
                // استخراج نهایی با su انجام می‌شود.
                "xzDecompress" -> {
                    val path = call.argument<String>("path")?.trim().orEmpty()
                    if (path.isEmpty()) {
                        result.error("bad_args", "path لازم است", null)
                        return@setMethodCallHandler
                    }
                    val main = Handler(Looper.getMainLooper())
                    thread(start = true, name = "sobhan-xz") {
                        try {
                            val src = File(path)
                            if (!src.isFile) {
                                main.post { result.error("no_file", "فایل پیدا نشد: $path", null) }
                                return@thread
                            }
                            val out = File(
                                cacheDir,
                                "sobhan-rootfs-" + System.currentTimeMillis() + ".tar"
                            )
                            var written = 0L
                            FileInputStream(src).use { fin ->
                                XZInputStream(fin).use { xz ->
                                    FileOutputStream(out).use { fos ->
                                        val buf = ByteArray(256 * 1024)
                                        while (true) {
                                            val n = xz.read(buf)
                                            if (n <= 0) break
                                            fos.write(buf, 0, n)
                                            written += n
                                        }
                                        fos.flush()
                                    }
                                }
                            }
                            if (written <= 0L) {
                                out.delete()
                                main.post { result.error("empty", "خروجی خالی بود", null) }
                            } else {
                                main.post { result.success(out.absolutePath) }
                            }
                        } catch (e: Throwable) {
                            main.post { result.error("xz_failed", e.message ?: e.toString(), null) }
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }

        // در شروع سرد، Dart خودش با getPendingShortcut شورتکات را برمی‌دارد؛
        // تا آن لحظه مقدار pending دست‌نخورده می‌ماند.
    }

    /** Intent اختصاصی هر شورتکات؛ باید صریح و دارای action باشد. */
    private fun shortcutIntentFor(command: String, label: String): Intent =
        Intent(this, MainActivity::class.java).apply {
            action = ACTION_LINUX_SHORTCUT
            putExtra(EXTRA_COMMAND, command)
            putExtra(EXTRA_LABEL, label)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }

    private fun requestAppShortcut(id: String, label: String, command: String): String {
        val target = shortcutIntentFor(command, label)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.SHORTCUT_SERVICE) as? ShortcutManager
                ?: return "این دستگاه از شورتکات پشتیبانی نمی‌کند"
            if (!manager.isRequestPinShortcutSupported) {
                return "لانچر اجازهٔ پین‌کردن شورتکات نمی‌دهد؛ از منوی خود لانچر پین کنید"
            }
            val info = ShortcutInfo.Builder(this, id)
                .setShortLabel(label)
                .setLongLabel(label)
                .setIcon(Icon.createWithResource(this, R.mipmap.launcher_icon))
                .setIntent(target)
                .build()
            val ok = manager.requestPinShortcut(info, null)
            return if (ok) "شورتکات «$label» روی صفحهٔ اصلی ساخته شد" else "درخواست شورتکات رد شد"
        }

        if (Build.VERSION.SDK_INT == Build.VERSION_CODES.N_MR1) {
            val install = Intent("com.android.launcher.action.INSTALL_SHORTCUT").apply {
                putExtra(Intent.EXTRA_SHORTCUT_INTENT, target)
                putExtra(Intent.EXTRA_SHORTCUT_NAME, label)
                putExtra(
                    Intent.EXTRA_SHORTCUT_ICON_RESOURCE,
                    Intent.ShortcutIconResource.fromContext(this@MainActivity, R.mipmap.launcher_icon)
                )
                putExtra("duplicate", false)
            }
            sendBroadcast(install)
            return "شورتکات «$label» ارسال شد"
        }

        return "اندروید این نسخه از شورتکات پین‌شده پشتیبانی نمی‌کند"
    }

    private fun removeAppShortcut(id: String): String {
        if (id.isEmpty()) return "شناسه خالی است"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.SHORTCUT_SERVICE) as? ShortcutManager
            return try {
                manager?.disableShortcuts(listOf(id), "removed by user")
                "شورتکات غیرفعال شد"
            } catch (e: Exception) {
                "حذف شورتکات ممکن نشد: ${e.message}"
            }
        }
        return "حذف شورتکات در این نسخهٔ اندروید ممکن نیست"
    }
}

class LinuxAppActivity : Activity() {
    private lateinit var surfaceView: LinuxSurfaceView
    private var isRightClickMode = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val appTitle = intent?.getStringExtra("APP_TITLE") ?: "Linux GUI App"
        val framePort = intent?.getIntExtra("FRAME_PORT", 48001) ?: 48001
        val inputPort = intent?.getIntExtra("INPUT_PORT", framePort + 1) ?: (framePort + 1)
        val displayNum = intent?.getIntExtra("DISPLAY_NUM", (framePort - 5566) / 2) ?: ((framePort - 5566) / 2)
        val rootDir = intent?.getStringExtra("ROOT_DIR") ?: "/data/ubuntu"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            @Suppress("DEPRECATION")
            setTaskDescription(ActivityManager.TaskDescription(appTitle))
        }

        val frameLayout = FrameLayout(this)
        surfaceView = LinuxSurfaceView(this, appTitle, framePort, inputPort, displayNum, rootDir)

        // نوار دکمه‌های شناور شیشه‌ای در گوشه بالا-راست
        val buttonLayout = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.TOP or Gravity.END
            setPadding(0, 70, 30, 0)
        }

        val btnKeyboard = Button(this).apply {
            text = "⌨️"
            alpha = 0.55f
            setOnClickListener {
                surfaceView.requestFocus()
                val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                imm.showSoftInput(surfaceView, InputMethodManager.SHOW_FORCED)
            }
        }

        val btnMouse = Button(this).apply {
            text = "🖱️ L"
            alpha = 0.55f
            setOnClickListener {
                isRightClickMode = !isRightClickMode
                text = if (isRightClickMode) "🖱️ R" else "🖱️ L"
                surfaceView.setRightClick(isRightClickMode)
            }
        }

        val btnClose = Button(this).apply {
            text = "❌"
            alpha = 0.55f
            setOnClickListener {
                surfaceView.requestShutdown()
                finishAndRemoveTask()
            }
        }

        buttonLayout.addView(btnKeyboard)
        buttonLayout.addView(btnMouse)
        buttonLayout.addView(btnClose)

        frameLayout.addView(surfaceView)
        frameLayout.addView(buttonLayout)

        setContentView(frameLayout)

        // تمام‌صفحهٔ واقعی: نوار وضعیت و نوار ناوبری پنهان می‌شوند
        applyImmersive()

        // فوکوس را به سطح بده تا کلیدهای سخت‌افزاری/بلوتوث به آن برسند
        surfaceView.requestFocus()
    }

    /**
     * کلیدهای کیبورد فیزیکی/بلوتوث/برخی IMEها اول به Activity می‌رسند؛
     * مستقیم به ویو منتقل می‌شوند تا فلش‌ها، Ctrl/Alt، F1..F12 و Space کار کنند.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (::surfaceView.isInitialized && surfaceView.handleKey(event)) return true
        return super.dispatchKeyEvent(event)
    }

    /** یک پنجره برای همهٔ برنامه‌ها: درخواست جدید فقط عنوان را عوض می‌کند. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val title = intent.getStringExtra("APP_TITLE") ?: "Linux GUI App"
        if (!::surfaceView.isInitialized) return
        surfaceView.updateTitle(title)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            @Suppress("DEPRECATION")
            setTaskDescription(ActivityManager.TaskDescription(title))
        }
        applyImmersive()
        surfaceView.requestFocus()
    }

    /** پنهان‌کردن نوارهای سیستم تا تصویر لینوکس کل صفحه را بگیرد. */
    private fun applyImmersive() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val lp = window.attributes
            lp.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            window.attributes = lp
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let { c ->
                c.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                c.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                )
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            applyImmersive()
            surfaceView.requestFocus()
        }
    }

    override fun onDestroy() {
        if (isFinishing) surfaceView.requestShutdown() else surfaceView.stopStreams()
        // به Dart خبر بده تا اجرای بعدی دوباره پنجره را باز کند
        MainActivity.notifyDisplayClosed()
        super.onDestroy()
    }
}

class LinuxSurfaceView(
    context: Context,
    private var appTitle: String,
    private val framePort: Int,
    private val inputPort: Int,
    private val displayNum: Int,
    private val rootDir: String
) : SurfaceView(context), SurfaceHolder.Callback {

    /** عنوان پنجره را بدون ساختن ویو جدید عوض می‌کند. */
    fun updateTitle(title: String) {
        if (title.isBlank() || title == appTitle) return
        appTitle = title
        postInvalidate()
    }

    @Volatile private var isRunning = false
    @Volatile private var generation = 0
    @Volatile private var frameSocket: Socket? = null
    @Volatile private var inputSocket: Socket? = null
    @Volatile private var inputOut: OutputStream? = null
    @Volatile private var rightClick = false
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val canvasLock = Any()
    private var renderThread: Thread? = null
    private var inputThread: Thread? = null

    // نگهداری آخرین مستطیل رسم برای نگاشت صحیح لمس (letterbox)
    @Volatile private var lastDst: Rect? = null

    private val bgPaint = Paint().apply { color = Color.parseColor("#0F111A") }
    private val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#7AA2F7")
        textSize = 44f
        typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
        textAlign = Paint.Align.CENTER
    }
    private val statusPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#9ECE6A")
        textSize = 28f
        typeface = Typeface.MONOSPACE
        textAlign = Paint.Align.CENTER
    }
    private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG)

    init {
        holder.addCallback(this)
        holder.setFormat(PixelFormat.RGBA_8888)
        isFocusable = true
        isFocusableInTouchMode = true
    }

    fun setRightClick(enabled: Boolean) {
        rightClick = enabled
    }

    override fun onCheckIsTextEditor(): Boolean = true

    // ---------- وضعیت کلیدهای اصلاح‌کننده (Hacker's Keyboard) ----------
    // sticky = قفل یک‌بارمصرف (لمس Ctrl در Hacker's Keyboard)
    @Volatile private var stickyCtrl = false
    @Volatile private var stickyAlt = false
    @Volatile private var stickyShift = false
    @Volatile private var stickyMeta = false
    // held = modifier فیزیکی که واقعاً پایین نگه داشته شده
    @Volatile private var heldCtrl = false
    @Volatile private var heldAlt = false
    @Volatile private var heldShift = false
    @Volatile private var heldMeta = false
    // آیا در همین نگه‌داشتن، کلیدی مصرف شد؟ (برای تصمیم قفل‌کردن)
    @Volatile private var modUsed = false

    private val textLock = Any()
    private val textBuf = StringBuilder()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val flushRunnable = Runnable { flushText() }

    private fun isModifierCode(code: Int): Boolean = when (code) {
        KeyEvent.KEYCODE_CTRL_LEFT, KeyEvent.KEYCODE_CTRL_RIGHT,
        KeyEvent.KEYCODE_ALT_LEFT, KeyEvent.KEYCODE_ALT_RIGHT,
        KeyEvent.KEYCODE_SHIFT_LEFT, KeyEvent.KEYCODE_SHIFT_RIGHT,
        KeyEvent.KEYCODE_META_LEFT, KeyEvent.KEYCODE_META_RIGHT -> true
        else -> false
    }

    /**
     * دو حالت را با هم پوشش می‌دهیم:
     *  * کیبورد فیزیکی: Ctrl پایین نگه داشته می‌شود (held).
     *  * Hacker's Keyboard: لمس Ctrl یک down+up فوری می‌فرستد؛ چون در فاصلهٔ
     *    down تا up هیچ کلیدی مصرف نشده، آن را «قفل» (sticky) می‌کنیم تا
     *    کلید بعدی با modifier برود.
     */
    private fun setModifier(code: Int, down: Boolean) {
        when (code) {
            KeyEvent.KEYCODE_CTRL_LEFT, KeyEvent.KEYCODE_CTRL_RIGHT -> {
                if (down) { heldCtrl = true; modUsed = false }
                else { heldCtrl = false; if (!modUsed) stickyCtrl = true }
            }
            KeyEvent.KEYCODE_ALT_LEFT, KeyEvent.KEYCODE_ALT_RIGHT -> {
                if (down) { heldAlt = true; modUsed = false }
                else { heldAlt = false; if (!modUsed) stickyAlt = true }
            }
            KeyEvent.KEYCODE_SHIFT_LEFT, KeyEvent.KEYCODE_SHIFT_RIGHT -> {
                if (down) { heldShift = true; modUsed = false }
                else { heldShift = false; if (!modUsed) stickyShift = true }
            }
            KeyEvent.KEYCODE_META_LEFT, KeyEvent.KEYCODE_META_RIGHT -> {
                if (down) { heldMeta = true; modUsed = false }
                else { heldMeta = false; if (!modUsed) stickyMeta = true }
            }
        }
    }

    private fun clearSticky() {
        stickyCtrl = false
        stickyAlt = false
        stickyShift = false
        stickyMeta = false
    }

    /** پیشوندهای xdotool (shift جداگانه) */
    private fun modPrefix(meta: Int): String {
        val sb = StringBuilder()
        if (stickyCtrl || heldCtrl || (meta and KeyEvent.META_CTRL_ON) != 0) sb.append("ctrl+")
        if (stickyAlt || heldAlt || (meta and KeyEvent.META_ALT_ON) != 0) sb.append("alt+")
        if (stickyMeta || heldMeta || (meta and KeyEvent.META_META_ON) != 0) sb.append("super+")
        return sb.toString()
    }

    private fun shiftActive(meta: Int): Boolean =
        stickyShift || heldShift || (meta and KeyEvent.META_SHIFT_ON) != 0 ||
            (meta and KeyEvent.META_SHIFT_LEFT_ON) != 0

    private fun keysymForCode(code: Int): String? = when (code) {
        KeyEvent.KEYCODE_ESCAPE -> "Escape"
        KeyEvent.KEYCODE_TAB -> "Tab"
        KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> "Return"
        KeyEvent.KEYCODE_DEL -> "BackSpace"
        KeyEvent.KEYCODE_FORWARD_DEL -> "Delete"
        KeyEvent.KEYCODE_DPAD_LEFT -> "Left"
        KeyEvent.KEYCODE_DPAD_RIGHT -> "Right"
        KeyEvent.KEYCODE_DPAD_UP -> "Up"
        KeyEvent.KEYCODE_DPAD_DOWN -> "Down"
        KeyEvent.KEYCODE_MOVE_HOME -> "Home"
        KeyEvent.KEYCODE_MOVE_END -> "End"
        KeyEvent.KEYCODE_PAGE_UP -> "Prior"
        KeyEvent.KEYCODE_PAGE_DOWN -> "Next"
        KeyEvent.KEYCODE_INSERT -> "Insert"
        KeyEvent.KEYCODE_SPACE -> "space"
        KeyEvent.KEYCODE_SYSRQ -> "Print"
        KeyEvent.KEYCODE_F1 -> "F1"
        KeyEvent.KEYCODE_F2 -> "F2"
        KeyEvent.KEYCODE_F3 -> "F3"
        KeyEvent.KEYCODE_F4 -> "F4"
        KeyEvent.KEYCODE_F5 -> "F5"
        KeyEvent.KEYCODE_F6 -> "F6"
        KeyEvent.KEYCODE_F7 -> "F7"
        KeyEvent.KEYCODE_F8 -> "F8"
        KeyEvent.KEYCODE_F9 -> "F9"
        KeyEvent.KEYCODE_F10 -> "F10"
        KeyEvent.KEYCODE_F11 -> "F11"
        KeyEvent.KEYCODE_F12 -> "F12"
        else -> null
    }

    /** نام keysym برای کاراکتری که همراه modifier فرستاده می‌شود */
    private fun keysymForChar(ch: Char): String? = when (ch) {
        in 'a'..'z' -> ch.toString()
        in 'A'..'Z' -> ch.lowercaseChar().toString()
        in '0'..'9' -> ch.toString()
        ' ' -> "space"
        '-' -> "minus"
        '=' -> "equal"
        '[' -> "bracketleft"
        ']' -> "bracketright"
        '\\' -> "backslash"
        ';' -> "semicolon"
        '\'' -> "apostrophe"
        ',' -> "comma"
        '.' -> "period"
        '/' -> "slash"
        '`' -> "grave"
        else -> null
    }

    /**
     * keysym پایه از روی keyCode.
     * وقتی Ctrl/Alt نگه داشته شده، unicodeChar کاراکتر کنترلی (۱..۲۶) می‌دهد
     * و به‌درد نمی‌خورد؛ پس باید از keyCode استفاده کنیم.
     */
    private fun keysymForKeyCode(code: Int): String? = when (code) {
        in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z ->
            ('a' + (code - KeyEvent.KEYCODE_A)).toString()
        in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 ->
            ('0' + (code - KeyEvent.KEYCODE_0)).toString()
        KeyEvent.KEYCODE_MINUS -> "minus"
        KeyEvent.KEYCODE_EQUALS -> "equal"
        KeyEvent.KEYCODE_LEFT_BRACKET -> "bracketleft"
        KeyEvent.KEYCODE_RIGHT_BRACKET -> "bracketright"
        KeyEvent.KEYCODE_BACKSLASH -> "backslash"
        KeyEvent.KEYCODE_SEMICOLON -> "semicolon"
        KeyEvent.KEYCODE_APOSTROPHE -> "apostrophe"
        KeyEvent.KEYCODE_COMMA -> "comma"
        KeyEvent.KEYCODE_PERIOD -> "period"
        KeyEvent.KEYCODE_SLASH -> "slash"
        KeyEvent.KEYCODE_GRAVE -> "grave"
        else -> null
    }

    private fun scheduleFlush() {
        mainHandler.removeCallbacks(flushRunnable)
        mainHandler.postDelayed(flushRunnable, 35)
    }

    private fun flushText() {
        val t = synchronized(textLock) {
            val v = textBuf.toString()
            textBuf.setLength(0)
            v
        }
        if (t.isNotEmpty()) sendInputEvent("TYPE $t")
    }

    /** متن را با بافر کوتاه می‌فرستد تا تایپ سریع کند نشود */
    private fun emitText(raw: String) {
        if (raw.isEmpty()) return
        val sb = StringBuilder()
        for (ch in raw) {
            if (ch == '\n' || ch == '\t') {
                if (sb.isNotEmpty()) {
                    flushText()
                    sendInputEvent("TYPE " + sb.toString())
                    sb.setLength(0)
                }
                sendInputEvent(if (ch == '\n') "KEY Return" else "KEY Tab")
            } else {
                sb.append(ch)
            }
        }
        if (sb.isNotEmpty()) {
            synchronized(textLock) { textBuf.append(sb) }
            scheduleFlush()
        }
    }

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or
            InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS or
            InputType.TYPE_TEXT_FLAG_MULTI_LINE
        outAttrs.imeOptions = EditorInfo.IME_ACTION_NONE or
            EditorInfo.IME_FLAG_NO_FULLSCREEN or
            EditorInfo.IME_FLAG_NO_EXTRACT_UI
        return object : BaseInputConnection(this, false) {
            override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
                val str = text?.toString() ?: return true
                if (str.isEmpty()) return true
                // بعضی کیبوردها Ctrl+A..Ctrl+Z را به‌صورت کاراکتر کنترلی می‌فرستند
                if (str.length == 1 && str[0].code in 1..26) {
                    flushText()
                    sendInputEvent("KEY ctrl+" + ('a' + (str[0].code - 1)))
                    return true
                }
                emitText(str)
                return true
            }

            override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean = true

            override fun finishComposingText(): Boolean = true

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                if (beforeLength > 0) {
                    flushText()
                    val n = beforeLength.coerceAtMost(32)
                    sendInputEvent("KEY " + List(n) { "BackSpace" }.joinToString(" "))
                    return true
                }
                return super.deleteSurroundingText(beforeLength, afterLength)
            }

            override fun sendKeyEvent(event: KeyEvent): Boolean = handleKey(event)
        }
    }

    /** پردازش مشترک کلید برای IME و کیبورد فیزیکی/بلوتوث */
    fun handleKey(event: KeyEvent): Boolean {
        val code = event.keyCode
        // کلیدهای سیستمی را نگیر (Back/Volume/Home/Menu/Recents)
        if (code == KeyEvent.KEYCODE_BACK ||
            code == KeyEvent.KEYCODE_VOLUME_UP ||
            code == KeyEvent.KEYCODE_VOLUME_DOWN ||
            code == KeyEvent.KEYCODE_VOLUME_MUTE ||
            code == KeyEvent.KEYCODE_HOME ||
            code == KeyEvent.KEYCODE_MENU ||
            code == KeyEvent.KEYCODE_APP_SWITCH ||
            code == KeyEvent.KEYCODE_POWER
        ) return false
        // بعضی کیبوردها متن چندکاراکتری را با ACTION_MULTIPLE می‌فرستند
        if (event.action == KeyEvent.ACTION_MULTIPLE) {
            val chars = event.characters
            if (!chars.isNullOrEmpty()) {
                emitText(chars)
                return true
            }
        }
        if (isModifierCode(code)) {
            setModifier(code, event.action == KeyEvent.ACTION_DOWN)
            return true
        }
        if (event.action == KeyEvent.ACTION_UP) return true

        val meta = event.metaState
        val mods = modPrefix(meta)
        val shift = shiftActive(meta)
        val repeats = (event.repeatCount + 1).coerceIn(1, 20)
        val special = keysymForCode(code)

        if (special != null) {
            flushText()
            val prefix = mods + if (shift) "shift+" else ""
            sendInputEvent("KEY " + List(repeats) { prefix + special }.joinToString(" "))
            if (prefix.isNotEmpty()) { modUsed = true; clearSticky() }
            return true
        }

        val u = event.unicodeChar
        // با نگه‌داشتن Ctrl/Alt مقدار unicodeChar کاراکتر کنترلی (<=32) است
        val ch: Char? = if (u > 32) u.toChar() else null

        if (mods.isEmpty()) {
            // Shift فیزیکی همین‌جا در unicodeChar اعمال شده؛ نباید قفل بماند
            if (shift) modUsed = true
            if (ch == null) return true
            emitText(ch.toString().repeat(repeats))
            return true
        }

        // modifier فعال است: اول keyCode، بعد کاراکتر چاپ‌شدنی
        val base = keysymForKeyCode(code) ?: ch?.let { keysymForChar(it) }
        if (base == null) {
            if (ch != null) emitText(ch.toString())
            return true
        }
        flushText()
        val prefix = mods + if (shift) "shift+" else ""
        sendInputEvent("KEY " + List(repeats) { prefix + base }.joinToString(" "))
        modUsed = true
        clearSticky()
        return true
    }

    @Volatile private var shutdownRequested = false

    /**
     * بستن قطعی اپ: QUIT به bridge (خودش Xvfb را می‌کشد).
     * اگر سوکت ورودی در دسترس نبود، seamless-stop داخل chroot اجرا می‌شود.
     */
    fun requestShutdown() {
        if (shutdownRequested) return
        shutdownRequested = true
        // سوکت را همین‌جا می‌گیریم؛ بعد از finishAndRemoveTask ممکن است null شود
        val out0 = inputOut
        thread(name = "seamless-shutdown") {
            // مسیر عادی: QUIT روی سوکت ورودی؛ bridge خودش Xvfb را می‌کشد (بدون su)
            var quitSent = false
            if (out0 != null) {
                try {
                    out0.write("QUIT\n".toByteArray(Charsets.UTF_8))
                    out0.flush()
                    quitSent = true
                } catch (_: Exception) {
                    quitSent = false
                }
            }

            if (quitSent) {
                // bridge خودش پاک‌سازی می‌کند؛ کمی صبر تا سوکت بسته شود
                try { Thread.sleep(400) } catch (_: InterruptedException) {}
            } else {
                // مسیر پشتیبان: سوکت ورودی در دسترس نبود → مستقیم داخل chroot پاک‌سازی کن
                try {
                    val cmd = "chroot " + shQuote(rootDir) + " /usr/local/bin/seamless-stop " + displayNum
                    ProcessBuilder("su", "-c", cmd).start().waitFor()
                } catch (_: Exception) {}
            }
            mainHandler.post { stopStreams() }
        }
    }

    private fun shQuote(v: String): String = "'" + v.replace("'", "'\\''") + "'"

    fun stopStreams() {
        isRunning = false
        generation++
        try { frameSocket?.close() } catch (_: Exception) {}
        try { inputSocket?.close() } catch (_: Exception) {}
        frameSocket = null
        inputSocket = null
        inputOut = null
        renderThread?.interrupt()
        inputThread?.interrupt()
        renderThread = null
        inputThread = null
    }

    // تمام رسم‌ها فقط از نخ رندر و فقط با lockCanvas نرم‌افزاری انجام می‌شود
    private fun safeDraw(gen: Int, block: (Canvas) -> Unit) {
        if (!isRunning || gen != generation) return
        val surface = holder.surface
        if (surface == null || !surface.isValid) return
        synchronized(canvasLock) {
            if (!isRunning || gen != generation) return
            if (!holder.surface.isValid) return
            var canvas: Canvas? = null
            try {
                canvas = holder.lockCanvas()
                if (canvas != null) block(canvas)
            } catch (_: Throwable) {
                // سطح تخریب شده یا در حال تغییر است؛ نادیده بگیر
            } finally {
                if (canvas != null) {
                    try { holder.unlockCanvasAndPost(canvas) } catch (_: Throwable) {}
                }
            }
        }
    }

    private fun drawWaitingScreen(gen: Int, msg: String) {
        safeDraw(gen) { canvas ->
            val w = canvas.width.toFloat()
            val h = canvas.height.toFloat()
            canvas.drawRect(0f, 0f, w, h, bgPaint)
            canvas.drawText("🐧 $appTitle", w / 2f, h / 2f - 40f, titlePaint)
            canvas.drawText(msg, w / 2f, h / 2f + 30f, statusPaint)
        }
    }

    private fun drawFrame(gen: Int, bmp: Bitmap) {
        safeDraw(gen) { canvas ->
            val cw = canvas.width
            val ch = canvas.height
            val bw = bmp.width
            val bh = bmp.height
            if (cw <= 0 || ch <= 0 || bw <= 0 || bh <= 0) return@safeDraw

            // نگه‌داشتن نسبت تصویر (letterbox) تا لمس دقیق نگاشت شود
            val scale = minOf(cw.toFloat() / bw, ch.toFloat() / bh)
            val dw = (bw * scale).toInt().coerceAtLeast(1)
            val dh = (bh * scale).toInt().coerceAtLeast(1)
            val left = (cw - dw) / 2
            val top = (ch - dh) / 2
            val dst = Rect(left, top, left + dw, top + dh)
            lastDst = dst

            canvas.drawRect(0f, 0f, cw.toFloat(), ch.toFloat(), bgPaint)
            canvas.drawBitmap(bmp, null, dst, bitmapPaint)
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        synchronized(canvasLock) {
            isRunning = true
            generation++
            val gen = generation
            lastDst = null

            renderThread = thread(name = "LinuxFrameThread") { renderLoop(gen) }
            inputThread = thread(name = "LinuxInputThread") { inputLoop(gen) }
        }
    }

    private fun inputLoop(gen: Int) {
        while (isRunning && gen == generation) {
            try {
                val sock = Socket()
                sock.connect(InetSocketAddress("127.0.0.1", inputPort), 1500)
                sock.tcpNoDelay = true
                inputSocket = sock
                inputOut = sock.getOutputStream()
                while (isRunning && gen == generation && !sock.isClosed && sock.isConnected) {
                    Thread.sleep(500)
                }
                try { sock.close() } catch (_: Exception) {}
            } catch (_: InterruptedException) {
                return
            } catch (_: Exception) {
                inputOut = null
                try { Thread.sleep(1000) } catch (_: InterruptedException) { return }
            }
        }
        inputOut = null
    }

    private fun renderLoop(gen: Int) {
        drawWaitingScreen(gen, "Connecting to Linux GUI (127.0.0.1:$framePort)...")

        var reusable: Bitmap? = null
        val opts = BitmapFactory.Options().apply {
            inMutable = true
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }

        while (isRunning && gen == generation) {
            var sock: Socket? = null
            try {
                sock = Socket()
                sock.connect(InetSocketAddress("127.0.0.1", framePort), 1500)
                sock.tcpNoDelay = true
                frameSocket = sock
                val din = DataInputStream(sock.getInputStream())

                while (isRunning && gen == generation) {
                    val len = din.readInt()
                    if (len !in 1..15_000_000) break
                    val jpeg = ByteArray(len)
                    din.readFully(jpeg)

                    opts.inBitmap = reusable
                    var bmp: Bitmap? = try {
                        BitmapFactory.decodeByteArray(jpeg, 0, len, opts)
                    } catch (_: Throwable) {
                        null
                    }
                    if (bmp == null) {
                        // ابعاد/کانفیگ عوض شده؛ یک‌بار بدون inBitmap
                        opts.inBitmap = null
                        bmp = try {
                            BitmapFactory.decodeByteArray(jpeg, 0, len, opts)
                        } catch (_: Throwable) {
                            null
                        }
                    }
                    if (bmp != null) {
                        reusable = bmp
                        drawFrame(gen, bmp)
                    }
                }
            } catch (_: InterruptedException) {
                break
            } catch (_: Exception) {
                // اتصال قطع شد
            } finally {
                try { sock?.close() } catch (_: Exception) {}
                frameSocket = null
            }

            if (isRunning && gen == generation) {
                drawWaitingScreen(gen, "Waiting for Linux App on port $framePort...")
                try { Thread.sleep(800) } catch (_: InterruptedException) { break }
            }
        }
    }

    private fun sendInputEvent(rawLine: String) {
        if (rawLine.startsWith("KEY ")) flushText()
        ioExecutor.execute {
            try {
                inputOut?.write((rawLine + "\n").toByteArray(Charsets.UTF_8))
                inputOut?.flush()
            } catch (_: Exception) {}
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val dst = lastDst
        val nx: Float
        val ny: Float
        if (dst != null && dst.width() > 0 && dst.height() > 0) {
            nx = ((event.x - dst.left) / dst.width()).coerceIn(0f, 1f)
            ny = ((event.y - dst.top) / dst.height()).coerceIn(0f, 1f)
        } else {
            nx = (event.x / width.coerceAtLeast(1)).coerceIn(0f, 1f)
            ny = (event.y / height.coerceAtLeast(1)).coerceIn(0f, 1f)
        }
        val btn = if (rightClick) "3" else "1"

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // با هر لمس فوکوس را نگه دار تا کیبورد فیزیکی قطع نشود
                if (!hasFocus()) requestFocus()
                sendInputEvent("DOWN $nx $ny $btn")
            }
            MotionEvent.ACTION_MOVE -> sendInputEvent("MOVE $nx $ny")
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> sendInputEvent("UP $nx $ny $btn")
        }
        return true
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        stopStreams()
    }
}
