// Static mechanism proof: two copies of @deepseek-ai/dsh-scope in one process have
// two different `Symbol("dsh.scope")` tags, so a Context scoped by one copy is
// "unscoped" to the other. That is exactly the failure mode behind
// "prompt section ... is already registered (for a per-agent override ...)".
//
// usage: <electron-as-node> scope-split-proof.mjs <installDshNodeModules> <profileDshNodeModules> <outJson>
//   e.g. .../resources/app.asar/dsh/node_modules  <isolated>/profiles/<p>/node_modules
import { writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { existsSync } from 'node:fs'

const [installRoot, profileRoot, outJson] = process.argv.slice(2)
const urlish = (...p) => pathToFileURL(join(...p)).href
const pick = (pkg, rel) => {
  const inProfile = urlish(profileRoot, '@deepseek-ai', pkg, rel)
  const inInstall = urlish(installRoot, '@deepseek-ai', pkg, rel)
  return existsSync(new URL(inProfile)) ? { path: inProfile, from: 'profile' } : { path: inInstall, from: 'installation' }
}

const result = { installRoot, profileRoot, ok: false }
try {
  const scopePathA = urlish(installRoot, '@deepseek-ai', 'dsh-scope', 'lib', 'index.js')
  const scopePathB = urlish(profileRoot, '@deepseek-ai', 'dsh-scope', 'lib', 'index.js')
  result.scopeFilePathA = scopePathA
  result.scopeFilePathB = scopePathB
  result.profileHasSecondScopeCopy = existsSync(new URL(scopePathB))
  if (!result.profileHasSecondScopeCopy) {
    // No second copy: one module instance, one Symbol, no split is possible.
    result.failureMode = 'healthy: the profile carries no second @deepseek-ai/dsh-scope copy, so every consumer shares one Symbol("dsh.scope")'
    result.ok = false
  } else {
    const scopeA = await import(scopePathA)
    const scopeB = await import(scopePathB)
    // Each copy is driven by its own sibling cordis; fall back to the installation class when
    // the minimal variants do not copy cordis into the profile.
    const cordisA = await import(pick('cordis', 'lib/index.js').path)
    const cordisB = await import(pick('cordis', 'lib/index.js').path)
    result.scopeCopiesSameModule = scopeA === scopeB
    const ContextA = cordisA.Context ?? cordisA.default?.Context
    const ContextB = cordisB.Context ?? cordisB.default?.Context
    result.cordisContextsSameClass = ContextA === ContextB
    const ctxA = new ContextA()
    const minted = scopeA.createScope(ctxA, 'preset-standard/session-1')
    const scoped = minted.ctx
    result.scopeOf_sameCopy = scopeA.scopeOf(scoped) ?? null
    result.scopeOf_otherCopy = scopeB.scopeOf(scoped) ?? null
    result.failureMode =
      result.scopeOf_sameCopy === 'preset-standard/session-1' && result.scopeOf_otherCopy === null
        ? 'confirmed: the second copy cannot see the scope tag, so it treats a scoped Context as global/unscoped'
        : 'not reproduced'
    result.ok = result.scopeOf_otherCopy === null
  }
} catch (error) {
  result.error = String(error && error.stack ? error.stack : error)
}
try { writeFileSync(outJson, JSON.stringify(result, null, 2)) } catch {}
console.log(JSON.stringify(result, null, 2))
process.exit(result.ok ? 0 : 2)

