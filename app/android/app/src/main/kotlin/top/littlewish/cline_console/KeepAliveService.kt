package top.littlewish.cline_console

import android.annotation.TargetApi
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 「有命令在跑」期间的保活前台服务（P34 形态 B）。
 *
 * 为什么需要它：App 退到后台会主动断 SSE 省电（ADR-35），锁屏期间命令跑完
 * 就只能等回前台补发。前台服务带一条用户可见的常驻通知，系统不冻结进程，
 * SSE 才能一直挂着，命令结束的本地通知也才发得出去。
 *
 * 什么时候开：由 `HubStore._syncKeepAlive()` 控制 —— 活跃命令数 0→1 时通过
 * `MainActivity` 的 MethodChannel 拉起，1→0 / 鉴权失效 / 用户关开关时停。
 * 只在命令运行期间存在（分钟级），不是长期常驻。
 *
 * 不做什么：
 * - `START_NOT_STICKY`：进程被杀后单独复活这个 Service 没有意义
 *   （Flutter engine 没了，SSE 也回不来）；
 * - 不申请 WAKE_LOCK：前台服务本身已不被冻结，不需要额外的 CPU 锁。
 */
class KeepAliveService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT).orEmpty()
            .ifEmpty { "有命令正在执行" }
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // API 29+ 起类型必须显式声明，否则 Android 14+ 直接抛异常。
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    /**
     * Android 15+ 对 `dataSync` 有 6h/24h 累计上限，到点系统回调这里，只能收工。
     * 命令卡死时 P13 的对账会在 60 秒内把没有进程的 running 回写成 failed，
     * 活跃数归 0 后 Dart 侧也会主动 stop。低版本不会走到这里。
     */
    @TargetApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(text: String): Notification {
        ensureChannel()
        val contentIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            contentIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }

        return builder
            .setSmallIcon(R.drawable.ic_stat_hub)
            .setContentTitle("Cline Console")
            .setContentText(text)
            // 不可划走、不重复提示：这是状态指示，不是一条要处理的消息。
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(pendingIntent)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "命令执行中",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "有远程命令在跑时挂一条常驻通知，锁屏也能收到完成提醒"
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        const val EXTRA_TEXT = "text"

        /** 与 `cline_hub_events` 分开：用户可以在系统设置里单独关掉这一条。 */
        private const val CHANNEL_ID = "cline_hub_keepalive"

        /** 固定 7 位数，避开 `HubNotification.id`（key.hashCode 取正）的常见取值。 */
        private const val NOTIFICATION_ID = 7301
    }
}
