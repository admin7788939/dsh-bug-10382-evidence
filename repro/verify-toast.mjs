// Verify the toast captured from the live isolated instance against the two
// message templates in the shipped code (no shell escaping involved).
import { readFileSync, writeFileSync } from 'node:fs'

const captured = readFileSync('./evidence/ui-drive-incident-toast.txt', 'utf8').trim()

// Exactly the fragments produced by the shipped code:
//   @deepseek-ai/dsh-system-prompt/lib/index.js:203   (persona prefix, scope === undefined)
//   @deepseek-ai/dsh-tool-subagent/lib/index.js:563   (standing modelSelectionSettings)
const fragments = [
  'agent-preset/invalid:',
  'persona (@deepseek-ai/dsh-persona): prompt section "deployment:persona-prefix" is already registered (for a per-agent override, register through that agent\'s `agent.ctx` instead)',
  'tool-subagent (@deepseek-ai/dsh-tool-subagent): tool-subagent: standing `modelSelectionSettings` requires a scoped preset Context',
]

const result = {
  toastPrefix: captured.startsWith('新建会话失败：'),
  capturedLength: captured.length,
  fragments: fragments.map((f) => ({ fragment: f.slice(0, 48) + '…', present: captured.includes(f) })),
}
result.identicalToConcatenatedCodeMessages = captured ===
  '新建会话失败：' + fragments[0] + ' ' + fragments[1] + ' ' + fragments[2]
result.ok = result.toastPrefix && result.fragments.every((f) => f.present) && result.identicalToConcatenatedCodeMessages

writeFileSync('./evidence/ui-drive-incident-compare.json', JSON.stringify(result, null, 2), 'utf8')
console.log(JSON.stringify(result, null, 2))
process.exit(result.ok ? 0 : 2)
