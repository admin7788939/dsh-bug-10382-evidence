// Drive the isolated DSH UI with real mouse events (Input.dispatchMouseEvent), so
// React handlers actually fire: dismiss the preview notice, then press "new session",
// and capture the toast + body text.
// usage: node ui-drive.mjs --cdp-port 9333 --out-json <f> --out-png <f>
const argv = {}
for (let i = 2; i < process.argv.length; i += 2) argv[process.argv[i].replace(/^--/, '')] = process.argv[i + 1]
const port = Number(argv['cdp-port'])
const outJson = argv['out-json']
const outPng = argv['out-png']
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const fs = await import('node:fs')

const NEW_SESSION = ['新建会话', '新会话', 'New session', '新建对话']
const result = { steps: [], consoleLines: [], bodyBefore: '', bodyAfter: '', shots: [] }

const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()
const page = list.filter((t) => t.type === 'page').find((t) => (t.url || '').startsWith('http://127.0.0.1'))
if (!page) throw new Error('no page target')
const ws = new WebSocket(page.webSocketDebuggerUrl)
await new Promise((res, rej) => { ws.addEventListener('open', res, { once: true }); ws.addEventListener('error', rej, { once: true }) })
let seq = 0
const pending = new Map()
ws.addEventListener('message', (ev) => {
  const m = JSON.parse(ev.data)
  if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.rej(new Error(m.error.message)) : p.res(m.result); return }
  if (m.method === 'Runtime.consoleAPICalled') {
    const text = (m.params.args || []).map((a) => a.value ?? a.description ?? '').join(' ')
    if (text.includes('agent-preset') || text.includes('Session')) result.consoleLines.push(text.slice(0, 900))
  }
})
const send = (method, params = {}) => new Promise((res, rej) => { const id = ++seq; pending.set(id, { res, rej }); ws.send(JSON.stringify({ id, method, params })) })
const evaluate = async (expr) => (await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true })).result?.value
const body = async () => (await evaluate('document.body.innerText')) || ''
const shot = async (path) => {
  try { const s = await send('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(path, Buffer.from(s.data, 'base64')); result.shots.push(path); return true } catch (e) { result.steps.push({ step: 'shot-failed', error: String(e) }); return false }
}

/** Find a clickable element by visible text and click it with real mouse events. */
async function clickByLabel (labels, opts = {}) {
  const info = await evaluate(`(() => {
    const labels = ${JSON.stringify(labels)}
    const norm = (s) => (s || '').replace(/\\s+/g, '')
    const all = [...document.querySelectorAll('button,[role=button],a,div,span')]
      .filter((el) => {
        const r = el.getBoundingClientRect()
        if (r.width < 8 || r.height < 8) return false
        const cs = getComputedStyle(el)
        if (cs.visibility === 'hidden' || cs.display === 'none' || cs.pointerEvents === 'none') return false
        return true
      })
    const exact = all.filter((el) => labels.some((l) => norm(el.innerText) === norm(l)))
    const partial = all.filter((el) => labels.some((l) => norm(el.innerText).includes(norm(l))))
    const area = (el) => { const r = el.getBoundingClientRect(); return r.width * r.height }
    // Smallest matching box: a wrapper DIV spanning the whole action row is not the button.
    const pick = (exact.length ? exact : partial).slice().sort((a, b) => area(a) - area(b))[0]
    if (!pick) return null
    let r = pick.getBoundingClientRect()
    // Verify the point actually lands on the intended control; otherwise use what is there.
    const probe = document.elementFromPoint(Math.round(r.x + r.width / 2), Math.round(r.y + r.height / 2))
    let target = pick
    if (probe && probe !== pick && pick.contains(probe)) target = probe
    if (!probe || !(probe === pick || pick.contains(probe))) {
      // Click the probe's own centre when it is a different control
      target = probe || pick
    }
    r = target.getBoundingClientRect()
    if (r.width < 8 || r.height < 8) return null
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), tag: target.tagName, text: (target.innerText || '').trim().slice(0, 30) }
  })()`)
  if (!info) return null
  for (const type of ['mousePressed', 'mouseReleased']) {
    await send('Input.dispatchMouseEvent', { type, x: info.x, y: info.y, button: 'left', clickCount: 1 })
    await sleep(60)
  }
  result.steps.push({ step: opts.step || 'click', matched: `${info.tag}:${info.text}`, at: [info.x, info.y] })
  return info
}

await send('Runtime.enable')
await send('Page.enable')
await sleep(1500)
result.bodyBefore = (await body()).slice(0, 800)

// 1) dismiss the preview notice (button text: 继续)
await clickByLabel(['继续'], { step: 'dismiss-preview' })
await sleep(2000)
result.steps.push({ step: 'after-dismiss', body: (await body()).slice(0, 400) })

// 2) pick a workspace: open the picker menu, then choose the default workspace
if (/选择工作区|选择一个工作区/.test(await body())) {
  await clickByLabel(['选择工作区'], { step: 'open-workspace-picker' })
  await sleep(1200)
  await clickByLabel(['默认工作区'], { step: 'pick-default-workspace' })
  await sleep(2500)
  result.steps.push({ step: 'after-pick', body: (await body()).slice(0, 400) })
}

// 3) press "new session" and grab the toast quickly
const before = await body()
result.bodyBefore = before.slice(0, 1500)
const hit = await clickByLabel(NEW_SESSION, { step: 'new-session' })
await sleep(900)
await shot(outPng
  ? outPng.replace(/\.png$/, '-900ms.png')
  : undefined)
await sleep(1500)
await shot(outPng)
result.bodyAfter = (await body()).slice(0, 2500)
result.clickedNewSession = hit !== null

const hay = [result.bodyAfter, ...result.consoleLines].join('\n')
result.markers = ['agent-preset/invalid', 'deployment:persona-prefix', 'requires a scoped preset Context', '新建会话失败', 'already registered']
  .filter((m) => hay.includes(m))
result.ok = result.markers.length > 0
try { ws.close() } catch {}
fs.writeFileSync(outJson, JSON.stringify(result, null, 2))
process.exit(result.ok ? 0 : 2)
