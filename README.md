# Evidence bundle — DSH 0.2.1-rc.2 `agent-preset/invalid` (persona prompt section already registered)

This repository exists only to host the evidence and the reproduction harness for
**[deepseek-ai/deepseek-harness · Discussions #10382](https://github.com/deepseek-ai/deepseek-harness/discussions/10382)**.
It contains no product code and is safe to archive or delete once the report is resolved
(deleting it breaks the inline images in that discussion).

## What happened

On Windows desktop **0.2.1-rc.2**, after installing plugin bundles into the profile and running
`pnpm add file:./plugins/*`, the profile's `node_modules/@deepseek-ai` gained a **second copy** of core
packages (`dsh-scope`, `dsh-system-prompt`, `dsh-tools`, `cordis`, …). Every new and resumed session then
failed with:

```
新建会话失败：agent-preset/invalid: persona (@deepseek-ai/dsh-persona): prompt section
"deployment:persona-prefix" is already registered (for a per-agent override, register through that
agent's `agent.ctx` instead) tool-subagent (@deepseek-ai/dsh-tool-subagent): tool-subagent:
standing `modelSelectionSettings` requires a scoped preset Context
```

## File map

| path | what it is |
|---|---|
| `screenshots/ui-drive-incident.png` | the toast, captured on an isolated instance of the *preserved bad profile* |
| `screenshots/ui-drive-incident-900ms.png` | the same moment, earlier frame |
| `captured/ui-drive-incident-toast.txt` | the toast text as rendered by the page (337 chars) |
| `captured/ui-drive-incident-compare.json` | proof that the captured text is **character-identical** to the two message templates in the shipped code |
| `captured/ui-drive-incident.json` | full drive capture: click steps, page text, console `SessionCreateError` stack |
| `captured/scope-split-incident.json` | in-process proof: two `dsh-scope` copies → `scopeOf` returns `"preset-standard/session-1"` for one, `null` for the other |
| `captured/scope-split-good.json` | same test on a healthy profile (one module instance) |
| `captured/scope-split-incident-no-scope.json` | reverse A/B: remove the extra `dsh-scope` copy → split disappears |
| `captured/scope-split-minimal-set.json` | split reproduced with the smallest loadable set (`dsh-scope` + `cordis` + `cosmokit`) |
| `captured/scenario-results.json` | the 6-scenario A/B matrix (all `--dump-config` runs: 215 rows, exit 0 — config looks identical) |
| `profile/package.json.at-incident` | the profile's bundle list at the moment of failure (25 bundles, incl. nine `@local/dsh-plugin-*`) |
| `profile/pnpm-lock.yaml` | the lockfile that records the peer resolutions materializing the copies |
| `profile/pnpm-workspace.yaml` | `nodeLinker: hoisted` + `autoInstallPeers: false` (written by DSH's own profile template) |
| `profile/node_modules-@deepseek-ai.md` | the 20 profile-local core packages vs the copies inside `app.asar` (17 byte-identical, 0 different) |
| `repro/scope-split-proof.mjs` | the 30-second, GUI-free mechanism proof |
| `repro/ui-drive.mjs` | CDP driver that presses "New session" on the isolated UI |
| `repro/verify-toast.mjs` | asserts the captured toast equals the code-built messages |
| `repro/repro-preset-conflict.ps1` | idempotent isolation harness (copy of `$DSH_HOME`, isolated profile name, random port) |

## Reproducing the mechanism proof (30 s, no GUI)

```powershell
$env:ELECTRON_RUN_AS_NODE = '1'
& "…\DeepSeek Harness.exe" --expose-internals .\repro\scope-split-proof.mjs `
    "…\resources\app.asar\dsh\node_modules" `
    "<profile>\node_modules" `
    out.json
```

Expected for a profile carrying a second `dsh-scope` copy:

```json
{ "profileHasSecondScopeCopy": true, "scopeCopiesSameModule": false,
  "scopeOf_sameCopy": "preset-standard/session-1", "scopeOf_otherCopy": null }
```

A profile copy of `dsh-scope` also needs `@deepseek-ai/cordis` beside it, otherwise it fails to import —
the minimum runnable set is `{dsh-scope, cordis, cosmokit}`.

## Code anchors (all in the shipped asar)

- `@deepseek-ai/dsh-scope/lib/index.js:229` — `const kScope = Symbol("dsh.scope")` (module-private);
  `:296` `createScope()` writes it, `:312` `scopeOf(ctx)` reads it, `:195` the `scope === undefined → global` fallback.
- `@deepseek-ai/dsh-system-prompt/lib/index.js:203` — the exact "is already registered (for a per-agent override …)" text.
- `@deepseek-ai/dsh-persona/lib/index.js:4-16` — "mounted globally it collides with the registry's own registration and fails loud".
- `@deepseek-ai/dsh-tool-subagent/lib/index.js:563` — the "requires a scoped preset Context" check.
- `@deepseek-ai/dsh-agent-preset-registry` — `mountPreset`/`auditRows`; the single producer of `RemoteError("agent-preset/invalid")`.
- `@deepseek-ai/dsh-app-boot/lib/index.js` — `:4525` baseUrl is the profile directory; `:1628-1663` a profile-local
  candidate wins over the installation table; `:2305`/`:2311-2388` preflight checks version compatibility only;
  `:598-603` the profile template itself writes `nodeLinker: hoisted`.

---

[![](https://img.shields.io/badge/powered_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://github.com/deepseek-ai/deepseek-harness)
