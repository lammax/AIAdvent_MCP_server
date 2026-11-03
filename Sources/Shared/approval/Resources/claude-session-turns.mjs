import { createRequire } from 'node:module';
const require = createRequire(process.argv[2] + '/package.json');
const { getSessionMessages } = await import(require.resolve('@anthropic-ai/claude-agent-sdk'));
const messages = await getSessionMessages(process.argv[3], {dir: process.argv[4]});
const turns = [];
for (const entry of messages) {
  if (entry.type !== 'assistant' || entry.message?.stop_reason !== 'end_turn') continue;
  const text = (entry.message.content ?? [])
    .filter(block => block?.type === 'text' && typeof block.text === 'string')
    .map(block => block.text)
    .join('\n')
    .trim();
  turns.push({uuid: entry.uuid, text});
}
process.stdout.write(JSON.stringify(turns.slice(-100)));
