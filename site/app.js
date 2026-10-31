/**
 * Cline Console 落地页脚本（无依赖，约 90 行）
 * 1) 代码块一键复制   2) 导航高亮当前区块   3) 未填写的仓库链接给出提示
 */
(function () {
  'use strict'

  /* ── 1. 代码块复制按钮 ───────────────────────────────── */
  document.querySelectorAll('pre').forEach(function (pre) {
    var btn = document.createElement('button')
    btn.type = 'button'
    btn.className = 'copy'
    btn.textContent = '复制'
    btn.setAttribute('aria-label', '复制这段命令')

    btn.addEventListener('click', function () {
      var code = pre.querySelector('code')
      var text = code ? code.textContent : pre.textContent
      var done = function () {
        btn.textContent = '已复制'
        btn.classList.add('is-ok')
        setTimeout(function () {
          btn.textContent = '复制'
          btn.classList.remove('is-ok')
        }, 1400)
      }

      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(done, fallback)
      } else {
        fallback()
      }

      function fallback() {
        var ta = document.createElement('textarea')
        ta.value = text
        ta.setAttribute('readonly', '')
        ta.style.position = 'fixed'
        ta.style.opacity = '0'
        document.body.appendChild(ta)
        ta.select()
        try { document.execCommand('copy'); done() } catch (e) { btn.textContent = '复制失败' }
        document.body.removeChild(ta)
      }
    })

    pre.appendChild(btn)
  })

  /* ── 2. 导航高亮 ─────────────────────────────────────── */
  var links = Array.prototype.slice.call(document.querySelectorAll('.nav-links a[href^="#"]'))
  var targets = links
    .map(function (a) { return document.querySelector(a.getAttribute('href')) })
    .filter(Boolean)

  if ('IntersectionObserver' in window && targets.length) {
    var visible = new Set()
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) visible.add(entry.target.id)
        else visible.delete(entry.target.id)
      })
      var current = targets.filter(function (t) { return visible.has(t.id) }).pop()
      links.forEach(function (a) {
        var on = current && a.getAttribute('href') === '#' + current.id
        a.classList.toggle('is-current', !!on)
      })
    }, { rootMargin: '-40% 0px -50% 0px' })

    targets.forEach(function (t) { io.observe(t) })
  }

  /* ── 3. 仓库链接占位提示 ─────────────────────────────── */
  var todoLinks = document.querySelectorAll('[data-todo="repo"]')
  todoLinks.forEach(function (a) {
    a.title = '仓库地址待填写：把 data-todo 链接换成真实地址即可'
    a.addEventListener('click', function (e) {
      e.preventDefault()
      toast('仓库地址还没填 —— 改 site/index.html 里的 data-todo="repo" 链接')
    })
  })

  function toast(message) {
    var el = document.createElement('div')
    el.className = 'toast'
    el.textContent = message
    document.body.appendChild(el)
    requestAnimationFrame(function () { el.classList.add('is-on') })
    setTimeout(function () {
      el.classList.remove('is-on')
      setTimeout(function () { el.remove() }, 260)
    }, 3200)
  }
})()
