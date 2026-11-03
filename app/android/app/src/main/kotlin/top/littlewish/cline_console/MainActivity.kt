package top.littlewish.cline_console

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * 会话 / 命令完成时的系统通知。
 *
 * 走原生 MethodChannel，不引 flutter_local_notifications：
 * 客户端刻意只保留 http / shared_preferences 两个依赖（ADR-31），
 * 这里需要的只是「建通道 + 发通知 + 要权限」三件事，系统 API 就够（ADR-35）。
 *
 * Dart 侧见 `lib/src/data/notifier.dart`：
 *   - `ensurePermission()` → Android 13+ 弹 POST_NOTIFICATIONS 授权，返回最终状态；
 *   - `show(id, title, body)` → 发一条可点开 App 的通知（同一个 id 覆盖旧通知）；
 *   - `startKeepAlive(text)` / `stopKeepAlive()` → 拉起 / 停掉 KeepAliveService（P34）。
 */
class MainActivity : FlutterActivity() {
    private var pendingPermission: MethodChannel.Result? = null

    /** 系统文件选择器回来之前，把 Flutter 侧的结果暂存这里。 */
    private var pendingPick: MethodChannel.Result? = null
    private var pendingPickMaxBytes: Int = DEFAULT_MAX_ATTACHMENT_BYTES

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ensureChannel()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LINK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openUrl" -> result.success(openUrl(call.argument<String>("url")))
                    else -> result.notImplemented()
                }
            }
        // 发送文件 / 图片（P38）：Dart 侧见 lib/src/data/file_picker.dart。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILES_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pick" -> pickFile(
                        call.argument<String>("mime"),
                        call.argument<Int>("maxBytes") ?: DEFAULT_MAX_ATTACHMENT_BYTES,
                        result
                    )
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 打开系统文件选择器（`ACTION_OPEN_DOCUMENT`，不需要存储权限）。
     *
     * [mime] 以 `image/` 开头时只列图片（「发送图片」），`*` 或空表示任意文件。
     * 结果在 [onActivityResult] 里读成字节数组回给 Dart：content:// URI 在 Dart
     * 侧没有直接读的办法，而 App 刻意不引 file_picker（ADR-31）。
     */
    private fun pickFile(mime: String?, maxBytes: Int, result: MethodChannel.Result) {
        // 连点两次：前一个直接按「取消」收尾，避免 result 永远悬着。
        pendingPick?.success(null)
        pendingPick = result
        pendingPickMaxBytes = if (maxBytes > 0) maxBytes else DEFAULT_MAX_ATTACHMENT_BYTES
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (mime.isNullOrBlank()) "*/*" else mime
        }
        try {
            startActivityForResult(intent, PICK_REQUEST)
        } catch (_: ActivityNotFoundException) {
            pendingPick = null
            result.error("no_picker", "系统里没有可用的文件选择器", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingPick
        pendingPick = null
        if (result == null) return

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null) // 用户取消
            return
        }
        try {
            val bytes = readBytes(uri, pendingPickMaxBytes)
            result.success(
                mapOf(
                    "name" to displayName(uri),
                    "mimeType" to (contentResolver.getType(uri) ?: "application/octet-stream"),
                    "bytes" to bytes
                )
            )
        } catch (_: TooLargeException) {
            result.error("too_large", "文件超过上限", null)
        } catch (error: Exception) {
            result.error("read_failed", error.message ?: "读取失败", null)
        }
    }

    private class TooLargeException : Exception("too_large")

    /** 边读边计数：超限就立刻放弃，不把 500 MB 的视频读进内存。 */
    private fun readBytes(uri: Uri, maxBytes: Int): ByteArray {
        val input = contentResolver.openInputStream(uri) ?: throw IllegalStateException("打不开这个文件")
        input.use { stream ->
            val buffer = ByteArrayOutputStream()
            val chunk = ByteArray(64 * 1024)
            var total = 0
            while (true) {
                val read = stream.read(chunk)
                if (read <= 0) break
                total += read
                if (total > maxBytes) throw TooLargeException()
                buffer.write(chunk, 0, read)
            }
            return buffer.toByteArray()
        }
    }

    /** 从 content:// 里取显示名；取不到就退回 URI 末段。 */
    private fun displayName(uri: Uri): String {
        var name: String? = null
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) name = cursor.getString(index)
                }
            }
        val value = name?.trim().orEmpty()
        if (value.isNotEmpty()) return value
        return uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
            ?: "attachment"
    }

    /**
     * 用系统浏览器打开 http(s) 链接（APK 下载地址）。
     *
     * 不引 url_launcher（ADR-31），也不需要 <queries>：这里只是 launch 一个隐式
     * intent，不做 resolveActivity 查询。没有浏览器时 startActivity 会抛
     * ActivityNotFoundException，返回 false，Dart 侧退回「复制链接」。
     */
    private fun openUrl(url: String?): Boolean {
        val uri = Uri.parse(url?.trim().orEmpty())
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return false
        return try {
            startActivity(Intent(Intent.ACTION_VIEW, uri))
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ensurePermission" -> ensurePermission(result)
            "show" -> {
                val id = call.argument<Int>("id") ?: 0
                val title = call.argument<String>("title") ?: "Cline Console"
                val body = call.argument<String>("body") ?: ""
                showNotification(id, title, body)
                result.success(null)
            }
            "cancelAll" -> {
                notificationManager().cancelAll()
                result.success(null)
            }
            // P34：命令运行期间的 dataSync 前台服务（见 KeepAliveService）。
            "startKeepAlive" -> {
                result.success(startKeepAlive(call.argument<String>("text")))
            }
            "stopKeepAlive" -> {
                stopKeepAlive()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * 拉起保活服务。
     *
     * 失败一律返回 false、不抛给 Dart：Android 11+ 的后台启动限制会抛
     * `ForegroundServiceStartNotAllowedException`（它是 IllegalStateException 的子类），
     * 国产 ROM 也可能抛 SecurityException。保活失败只影响「锁屏即时提醒」，
     * 不影响命令下发与回前台补发，所以按降级处理（与 show() 的容错风格一致）。
     */
    private fun startKeepAlive(text: String?): Boolean {
        val intent = Intent(this, KeepAliveService::class.java).apply {
            putExtra(KeepAliveService.EXTRA_TEXT, text?.trim().orEmpty())
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            true
        } catch (_: IllegalStateException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    private fun stopKeepAlive() {
        try {
            stopService(Intent(this, KeepAliveService::class.java))
        } catch (_: SecurityException) {
            // 服务没起来 / 已被系统回收：什么都不用做。
        }
    }

    private fun ensurePermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            ensureChannel()
            result.success(true)
            return
        }
        // 连点两次时，前一个调用直接回 false，避免 result 永远悬着。
        pendingPermission?.success(false)
        pendingPermission = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST) return
        val granted =
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(granted)
        pendingPermission = null
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = notificationManager()
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "会话与命令",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Cline 会话结束、远程命令完成或失败时提醒"
            enableVibration(true)
        }
        manager.createNotificationChannel(channel)
    }

    private fun showNotification(id: Int, title: String, body: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            // 没授权就静默放弃：Dart 侧仍会正常跑，设置页里可以再请求一次。
            return
        }
        ensureChannel()

        val contentIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            id,
            contentIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_HIGH)
        }

        val notification = builder
            .setSmallIcon(R.drawable.ic_stat_hub)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        try {
            notificationManager().notify(id, notification)
        } catch (_: SecurityException) {
            // 权限在发出瞬间被撤销：同样按「静默失败」处理。
        }
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    companion object {
        private const val CHANNEL = "top.littlewish.cline_console/notify"
        private const val LINK_CHANNEL = "top.littlewish.cline_console/links"
        private const val FILES_CHANNEL = "top.littlewish.cline_console/files"
        private const val CHANNEL_ID = "cline_hub_events"
        private const val PERMISSION_REQUEST = 4101
        private const val PICK_REQUEST = 4102

        /** 与 Dart 侧 `kMaxAttachmentBytes` / Hub 默认值保持一致的兜底上限（8 MB）。 */
        private const val DEFAULT_MAX_ATTACHMENT_BYTES = 8 * 1024 * 1024
    }
}
