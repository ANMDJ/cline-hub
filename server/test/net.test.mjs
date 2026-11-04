import assert from 'node:assert/strict'
import test from 'node:test'

import { clientIp, ipAllowed, normalizeIp } from '../src/net.js'

/** 最小 req 替身：直连地址 + 请求头，够 clientIp() 用。 */
const req = (remote, forwarded) => ({
  socket: { remoteAddress: remote },
  headers: forwarded === undefined ? {} : { 'x-forwarded-for': forwarded }
})

test('XFF 取最后一段：伪造的首段不影响真实 IP（P40）', () => {
  // 攻击者自带 `X-Forwarded-For: 1.2.3.4`，Caddy 追加真实对端 203.0.113.9
  assert.equal(clientIp(req('::ffff:127.0.0.1', '1.2.3.4, 203.0.113.9')), '203.0.113.9')
})

test('多段 XFF：只认紧邻我们的代理追加的那一段', () => {
  assert.equal(
    clientIp(req('127.0.0.1', '9.9.9.9, 1.2.3.4, 203.0.113.9, 198.51.100.7')),
    '198.51.100.7'
  )
})

test('空段 / 多余空格 / 末尾逗号都要能容忍', () => {
  assert.equal(clientIp(req('127.0.0.1', ' 1.2.3.4 , , 203.0.113.9 , ')), '203.0.113.9')
  assert.equal(clientIp(req('127.0.0.1', '203.0.113.9')), '203.0.113.9')
})

test('没有 XFF 就用直连地址', () => {
  assert.equal(clientIp(req('127.0.0.1')), '127.0.0.1')
  assert.equal(clientIp(req('127.0.0.1', '')), '127.0.0.1')
  assert.equal(clientIp(req('127.0.0.1', ' , , ')), '127.0.0.1')
})

test('非回环直连不采信 XFF（防「绕过反代直连 Hub」伪造）', () => {
  assert.equal(clientIp(req('10.1.2.3', '1.2.3.4')), '10.1.2.3')
  assert.equal(clientIp(req('::1', '1.2.3.4')), '1.2.3.4', 'IPv6 回环也算直连代理')
})

test('最后一段仍然可以是 IPv6 / 带 ::ffff: 前缀', () => {
  assert.equal(clientIp(req('127.0.0.1', '1.2.3.4, ::ffff:203.0.113.9')), '203.0.113.9')
  assert.equal(normalizeIp('::ffff:203.0.113.9'), '203.0.113.9')
})

test('白名单按真实 IP 生效：伪造首段不能把自己塞进白名单', () => {
  const rules = ['203.0.113.0/24']
  const spoofed = clientIp(req('127.0.0.1', '203.0.113.9, 198.51.100.7'))
  assert.equal(spoofed, '198.51.100.7')
  assert.equal(ipAllowed(spoofed, rules), false)
  assert.equal(ipAllowed('203.0.113.9', rules), true)
})
