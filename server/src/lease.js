import { attachMetadata, toCommand } from './routes/commands.js'

/**
 * 命令租约回收（P42）。
 *
 * 背景：命令状态只有 bridge 会写。bridge 被硬杀 / 断网 / 机器休眠时，
 * Hub 上的命令会永远停在 delivered / running，手机看起来「一直在执行」
 * （外部审计点名的那条，见 docs/security-review.md §5 P42）。
 *
 * 现在三层：
 *   1. bridge 的 reconcile（每 60s）：看得到本机进程，能区分「还活着」与「真的没了」；
 *   2. 这里的租约扫描：只看「执行侧还在不在续租」，bridge 整个消失也能收尾；
 *   3. `npm run reconcile` / `npm run ps -- --clean`：人工排障。
 *
 * 只改「租约过期」的那批行，不碰 pending（还没人认领，不存在失联），
 * 也不碰终态（done / failed / cancelled 本来就没有租约）。
 */

/** 回收 running / delivered 时给手机看的原因：说清不是命令本身失败，可以直接重发。 */
export const LEASE_ORPHAN_ERROR =
  '命令已中断：执行它的电脑超过租约时间没有心跳（bridge 崩溃 / 断网 / 关机），Hub 已自动回收。可以重新下发。'

/** cancelling 过期说明「用户已经点了取消，但执行侧失联了」，按取消收尾更符合预期。 */
export const LEASE_CANCEL_ERROR = '已取消：执行它的电脑在取消期间失联，Hub 已自动收尾。'

/** 单次最多收多少条：一次扫完几万条没有意义，下一轮会继续。 */
const SWEEP_BATCH = 50

export function createCommandLease({ db, logger, sse, config }) {
  const sweepMs =
    Number.isInteger(config.commandLeaseSweepMs) && config.commandLeaseSweepMs >= 1000
      ? config.commandLeaseSweepMs
      : 60_000
  let timer = null
  let sweeping = false
  let stopped = false

  /**
   * 扫描一轮过期租约。返回被回收的 id，便于测试与手工调用。
   *
   * 用 `for update skip locked` 选行：以后真起多实例也不会两遍同时改同一条，
   * 单实例下与普通 select 等价。
   */
  async function sweep() {
    if (sweeping) return { ok: true, skipped: 'busy', reclaimed: 0, ids: [] }
    sweeping = true
    try {
      const rows = await db.tx(async (client) => {
        const picked = await client.query(
          `select id from commands
            where status in ('delivered', 'running', 'cancelling')
              and lease_expires_at is not null
              and lease_expires_at < now()
            order by lease_expires_at asc
            limit $1
            for update skip locked`,
          [SWEEP_BATCH]
        )
        if (picked.rows.length === 0) return []
        const ids = picked.rows.map((row) => row.id)
        const updated = await client.query(
          `update commands set
             status = case when status = 'cancelling' then 'cancelled' else 'failed' end,
             error_text = case when status = 'cancelling' then $2 else $3 end,
             finished_at = now(),
             lease_expires_at = null
           where id = any($1::text[])
           returning *`,
          [ids, LEASE_CANCEL_ERROR, LEASE_ORPHAN_ERROR]
        )
        return updated.rows
      })

      if (rows.length === 0) return { ok: true, reclaimed: 0, ids: [] }

      // 广播带附件的完整命令：App 用 command.update 就地替换，附件卡片不能凭空消失。
      const items = await attachMetadata(db, rows)
      for (const item of items) {
        logger.warn('command lease expired', {
          id: item.id,
          deviceId: item.device_id,
          status: item.status,
          leaseExpiredAt: item.lease_expires_at ?? null
        })
        sse.broadcast('command.update', toCommand(item))
      }
      return { ok: true, reclaimed: items.length, ids: items.map((item) => item.id) }
    } finally {
      sweeping = false
    }
  }

  function start() {
    if (timer || stopped) return
    // 启动先扫一次：Hub 重启期间攒下的过期租约不用再等满一个周期。
    void sweep().catch((error) =>
      logger.error('command lease sweep failed', { message: error.message })
    )
    timer = setInterval(() => {
      void sweep().catch((error) =>
        logger.error('command lease sweep failed', { message: error.message })
      )
    }, sweepMs)
    // 不让这个定时器把进程挂住（测试 / 一次性脚本里很重要）。
    timer.unref?.()
    logger.info('command lease sweeper started', { everySec: Math.round(sweepMs / 1000) })
  }

  function stop() {
    stopped = true
    if (timer) clearInterval(timer)
    timer = null
  }

  return { sweep, start, stop, sweepMs }
}
