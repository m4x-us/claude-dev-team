#!/usr/bin/env node
// ===========================================
// AUTOCODE BOT
// ===========================================
// Automates the Plan → Implement → Audit loop.
// Install once globally; works from any project directory.
// Usage: autocode "task description" | autocode 3 | autocode

import Anthropic from '@anthropic-ai/sdk';
import type { MessageParam } from '@anthropic-ai/sdk/resources/messages';
import * as fs from 'fs';
import * as path from 'path';
import * as readline from 'readline';
import { execSync } from 'child_process';

// ===========================================
// CONSTANTS
// ===========================================

const MODEL = process.env.AUTOCODE_MODEL ?? 'claude-opus-4-7';
const MAX_CYCLES = 5;
const MAX_DIFF_BYTES = 80_000;

const PLAN_PROMPT = `Let's work on: {task}

Do we need to update our harness to handle it? How can we ensure writing world-class, \
enterprise-grade code? Put together a plan that not only covers everything from a conceptual \
level, but also gets very specific on how we're going to implement this so we don't drift \
away from world-class code and start lying and cutting. Use our Slow-Coding Toyota System, \
where we utilize stop & fix as well. Our plan should update our harness, if necessary, and \
needs to prevent known drifts: lying, cutting corners, not implementing the right plan/procedure. \
Our plan should not just be theoretical but specific as to how to complete each step, that way \
there's no room for drift.

Current codebase context:
{context}`;

const REVISION_1 = `Is this plan world-class? Where are we leaving openings for drift into \
mediocrity because we haven't outlined our implementation plan enough to keep us from drifting?`;

const REVISION_2 = `Is this really world-class? Aren't we missing some spots where we can drift? \
Remember, your nature is to deliver quick code instead of quality code and we're trying to prevent it. \
You are also naturally inclined to lie and to write poor tests. We want to prevent that too. Is \
this plan truly helping that? Are any of these tests pseudocode? Is this truly a world-class \
plan? Are the guardrails you put in place to keep you from drifting enough? What about testing? \
How do we ensure the tests that we develop aren't fake tests, but actually tell us information \
we need to know? Are these tests thinking of edge cases? How can we truly make a world-class \
testing system here?`;

const AUDIT_PROMPTS = [
  `Let's do an audit of this. Where did we cut corners? What's not world-class? What's not \
enterprise-grade? Are our tests pseudocode? Or are they real? Are we testing the right things?`,

  `Let's do another audit. This time with fresh eyes. What's not world-class? What's not \
enterprise grade? Where did we cut corners? Where's the pseudocode? Where are the flaws? \
What are our vulnerabilities?`,

  `Let's do another audit. I want you to take a step back and truly understand the purpose of \
what we're building, and then go through the code and see what's not world-class and what's \
not enterprise-grade. Find our vulnerabilities and security flaws.`,
];

const AUDIT_SUFFIX = `

Code changes since last commit:
{diff}

After your complete analysis, output this line exactly (machine-parsed):
AUDIT_RESULT: {"severity":N,"critical":N,"major":N,"minor":N,"verdict":"PASS"}
where severity is 1-10 (1=trivial style nit, 10=catastrophic data loss), critical = count of \
blockers that must be fixed before shipping, verdict PASS only if severity <= 3 AND critical = 0.`;

const PRIOR_GAPS_PREFIX = `Prior audit found these gaps to fix:
{gaps}

Now plan how to fix them specifically.

`;

// ===========================================
// INTERFACES
// ===========================================

interface AuditResult {
  severity: number;
  critical: number;
  major: number;
  minor: number;
  verdict: string;
}

interface Task {
  id: number;
  text: string;
  done: boolean;
  isGap: boolean;
  doneDate?: string;
}

interface TaskList {
  projectName: string;
  open: Task[];
  completed: Task[];
}

// ===========================================
// ANSI COLORS
// ===========================================

const C = {
  reset: '\x1b[0m',
  yellow: '\x1b[33m',
  green: '\x1b[32m',
  red: '\x1b[31m',
  cyan: '\x1b[36m',
  bold: '\x1b[1m',
  dim: '\x1b[2m',
};

// ===========================================
// GIT HELPERS
// ===========================================

function getProjectRoot(): string {
  try {
    return execSync('git rev-parse --show-toplevel', { encoding: 'utf8' }).trim();
  } catch {
    return process.cwd();
  }
}

function getGitContext(): string {
  try {
    const stat = execSync('git diff --stat HEAD', { encoding: 'utf8' });
    const status = execSync('git status --short', { encoding: 'utf8' });
    return [
      stat ? `Changed files:\n${stat}` : 'No staged changes.',
      status ? `Working tree:\n${status}` : '',
    ].filter(Boolean).join('\n');
  } catch {
    return 'No git context available.';
  }
}

function getGitDiff(): string {
  try {
    let diff = execSync('git diff HEAD', { encoding: 'utf8' });
    if (Buffer.byteLength(diff, 'utf8') > MAX_DIFF_BYTES) {
      diff = diff.slice(0, MAX_DIFF_BYTES) + '\n\n[diff truncated at 80KB]';
    }
    return diff || 'No changes detected since last commit.';
  } catch {
    return 'Could not read git diff.';
  }
}

// ===========================================
// TASK LIST
// ===========================================

function getTaskListPath(): string {
  const root = getProjectRoot();
  return path.join(root, '.autocode', 'tasks.md');
}

function ensureTaskListDir(): void {
  const filePath = getTaskListPath();
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
    // Add .autocode/ to .gitignore if not already there
    const gitignore = path.join(getProjectRoot(), '.gitignore');
    if (fs.existsSync(gitignore)) {
      const content = fs.readFileSync(gitignore, 'utf8');
      if (!content.includes('.autocode/')) {
        fs.appendFileSync(gitignore, '\n# AutoCode personal task list\n.autocode/\n');
      }
    }
  }
}

function parseTaskList(): TaskList {
  const filePath = getTaskListPath();
  if (!fs.existsSync(filePath)) {
    const projectName = path.basename(getProjectRoot());
    return { projectName, open: [], completed: [] };
  }

  const content = fs.readFileSync(filePath, 'utf8');
  const lines = content.split('\n');

  let projectName = path.basename(getProjectRoot());
  let inOpen = false;
  let inCompleted = false;
  const open: Task[] = [];
  const completed: Task[] = [];
  let nextId = 1;

  for (const line of lines) {
    if (line.startsWith('# AutoCode Task List')) {
      const match = line.match(/— (.+)$/);
      if (match) projectName = match[1];
      continue;
    }
    if (line.trim() === '## Open') { inOpen = true; inCompleted = false; continue; }
    if (line.trim() === '## Completed') { inCompleted = true; inOpen = false; continue; }

    const openMatch = line.match(/^- \[ \] (\d+)\. (\(gap\) )?(.+)$/);
    const doneMatch = line.match(/^- \[x\] (\d+)\. (\(gap\) )?(.+?)(?:\s+— done (.+))?$/);

    if (inOpen && openMatch) {
      const id = parseInt(openMatch[1]);
      open.push({ id, text: openMatch[3], done: false, isGap: !!openMatch[2] });
      if (id >= nextId) nextId = id + 1;
    } else if (inCompleted && doneMatch) {
      const id = parseInt(doneMatch[1]);
      completed.push({ id, text: doneMatch[3], done: true, isGap: !!doneMatch[2], doneDate: doneMatch[4] });
      if (id >= nextId) nextId = id + 1;
    }
  }

  return { projectName, open, completed };
}

function writeTaskList(list: TaskList): void {
  ensureTaskListDir();
  const lines: string[] = [
    `# AutoCode Task List — ${list.projectName}`,
    '',
    '## Open',
  ];

  for (const t of list.open) {
    const prefix = t.isGap ? '(gap) ' : '';
    lines.push(`- [ ] ${t.id}. ${prefix}${t.text}`);
  }

  lines.push('', '## Completed');
  for (const t of list.completed) {
    const prefix = t.isGap ? '(gap) ' : '';
    const suffix = t.doneDate ? ` — done ${t.doneDate}` : '';
    lines.push(`- [x] ${t.id}. ${prefix}${t.text}${suffix}`);
  }

  fs.writeFileSync(getTaskListPath(), lines.join('\n') + '\n');
}

function getNextTaskId(list: TaskList): number {
  const allIds = [...list.open, ...list.completed].map(t => t.id);
  return allIds.length > 0 ? Math.max(...allIds) + 1 : 1;
}

function addGapTasks(list: TaskList, auditText: string, date: string): Task[] {
  // Extract critical/major findings — lines with "critical" or "major" followed by a colon or dash
  const lines = auditText.split('\n');
  const gaps: string[] = [];

  for (const line of lines) {
    const trimmed = line.trim();
    // Look for numbered or bulleted lines that indicate critical/major findings
    if (
      /^[\d\-\*•]\s/.test(trimmed) &&
      (trimmed.toLowerCase().includes('critical') ||
       trimmed.toLowerCase().includes('major') ||
       /^\d+\.\s/.test(trimmed)) &&
      trimmed.length > 20 &&
      trimmed.length < 200
    ) {
      const cleaned = trimmed
        .replace(/^[\d\-\*•]\s+/, '')
        .replace(/^\*\*/, '')
        .replace(/\*\*$/, '')
        .trim();
      if (cleaned && !gaps.includes(cleaned)) {
        gaps.push(cleaned);
      }
    }
  }

  // Take first 5 gaps to avoid bloating the task list
  const newTasks: Task[] = [];
  for (const gap of gaps.slice(0, 5)) {
    const id = getNextTaskId(list);
    const task: Task = { id, text: `${gap} — found audit ${date}`, done: false, isGap: true };
    list.open.push(task);
    newTasks.push(task);
  }

  if (newTasks.length > 0) {
    writeTaskList(list);
    console.log(`\n${C.cyan}Added ${newTasks.length} gap task(s) to task list.${C.reset}`);
  }

  return newTasks;
}

function markTaskDone(list: TaskList, taskId: number, date: string): void {
  const idx = list.open.findIndex(t => t.id === taskId);
  if (idx === -1) return;
  const [task] = list.open.splice(idx, 1);
  task.done = true;
  task.doneDate = date;
  list.completed.push(task);
  writeTaskList(list);
}

// ===========================================
// TASK SELECTION
// ===========================================

async function selectTask(argv: string[]): Promise<{ task: string; taskId?: number; list: TaskList }> {
  const list = parseTaskList();
  const arg = argv.join(' ').trim();

  // Numeric arg → pick from open list
  if (/^\d+$/.test(arg)) {
    const id = parseInt(arg);
    const found = list.open.find(t => t.id === id);
    if (!found) {
      console.error(`${C.red}Task #${id} not found in open tasks.${C.reset}`);
      printTaskList(list);
      process.exit(1);
    }
    return { task: found.text, taskId: found.id, list };
  }

  // Text arg → new task
  if (arg.length > 0) {
    const id = getNextTaskId(list);
    const newTask: Task = { id, text: arg, done: false, isGap: false };
    list.open.push(newTask);
    ensureTaskListDir();
    writeTaskList(list);
    console.log(`${C.cyan}Added task #${id}: ${arg}${C.reset}\n`);
    return { task: arg, taskId: id, list };
  }

  // No arg → interactive menu
  printTaskList(list);

  if (list.open.length === 0) {
    console.log(`\n${C.dim}No open tasks. Describe a new task:${C.reset}`);
    const text = await prompt('> ');
    if (!text.trim()) { console.error('No task provided.'); process.exit(1); }
    const id = getNextTaskId(list);
    const newTask: Task = { id, text: text.trim(), done: false, isGap: false };
    list.open.push(newTask);
    ensureTaskListDir();
    writeTaskList(list);
    return { task: text.trim(), taskId: id, list };
  }

  const answer = await prompt(`\nWhich task? (number or describe a new one): `);
  const trimmed = answer.trim();

  if (/^\d+$/.test(trimmed)) {
    const id = parseInt(trimmed);
    const found = list.open.find(t => t.id === id);
    if (!found) { console.error(`Task #${id} not found.`); process.exit(1); }
    return { task: found.text, taskId: found.id, list };
  }

  if (trimmed.length > 0) {
    const id = getNextTaskId(list);
    const newTask: Task = { id, text: trimmed, done: false, isGap: false };
    list.open.push(newTask);
    ensureTaskListDir();
    writeTaskList(list);
    console.log(`${C.cyan}Added task #${id}: ${trimmed}${C.reset}`);
    return { task: trimmed, taskId: id, list };
  }

  console.error('No task selected.');
  process.exit(1);
}

function printTaskList(list: TaskList): void {
  console.log(`\n${C.bold}${C.yellow}AutoCode — ${list.projectName}${C.reset}`);
  if (list.open.length === 0) {
    console.log(`${C.dim}No open tasks.${C.reset}`);
  } else {
    console.log(`\n${C.bold}Open:${C.reset}`);
    for (const t of list.open) {
      const tag = t.isGap ? ` ${C.dim}(gap)${C.reset}` : '';
      console.log(`  ${C.cyan}${t.id}.${C.reset} ${t.text}${tag}`);
    }
  }
  if (list.completed.length > 0) {
    console.log(`\n${C.dim}Completed: ${list.completed.length} task(s)${C.reset}`);
  }
  console.log('');
}

// ===========================================
// READLINE HELPERS
// ===========================================

function prompt(message: string): Promise<string> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise(resolve => {
    rl.question(message, answer => {
      rl.close();
      resolve(answer);
    });
  });
}

async function waitForEnter(message: string): Promise<void> {
  await prompt(message);
}

// ===========================================
// ANTHROPIC STREAMING
// ===========================================

async function streamToConsole(messages: MessageParam[]): Promise<string> {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    console.error(`${C.red}Error: ANTHROPIC_API_KEY environment variable is not set.${C.reset}`);
    process.exit(1);
  }

  const client = new Anthropic({ apiKey });
  const stream = client.messages.stream({
    model: MODEL,
    max_tokens: 8192,
    messages,
  });

  let full = '';
  for await (const chunk of stream) {
    if (chunk.type === 'content_block_delta' && chunk.delta.type === 'text_delta') {
      process.stdout.write(chunk.delta.text);
      full += chunk.delta.text;
    }
  }
  process.stdout.write('\n');
  return full;
}

// ===========================================
// AUDIT RESULT PARSING
// ===========================================

function parseAuditResult(text: string): AuditResult | null {
  const match = text.match(/AUDIT_RESULT:\s*(\{[^}]+\})/);
  if (!match) return null;
  try {
    return JSON.parse(match[1]) as AuditResult;
  } catch {
    return null;
  }
}

function auditPassed(result: AuditResult): boolean {
  return result.verdict === 'PASS' && result.critical === 0 && result.severity <= 3;
}

function extractGapSummary(text: string): string {
  return text.slice(0, 2000);
}

// ===========================================
// DISPLAY HELPERS
// ===========================================

function printHeader(title: string): void {
  const line = '═'.repeat(title.length + 4);
  console.log(`\n${C.yellow}${C.bold}╔${line}╗${C.reset}`);
  console.log(`${C.yellow}${C.bold}║  ${title}  ║${C.reset}`);
  console.log(`${C.yellow}${C.bold}╚${line}╝${C.reset}\n`);
}

function printAuditSummary(result: AuditResult | null): void {
  if (!result) {
    console.log(`\n${C.red}${C.bold}⚠  Could not parse AUDIT_RESULT — treating as FAIL.${C.reset}`);
    return;
  }

  const passed = auditPassed(result);
  const color = passed ? C.green : C.red;
  const icon = passed ? '✅' : '❌';

  console.log(`\n${color}${C.bold}${icon}  AUDIT RESULT${C.reset}`);
  console.log(`${color}   Severity: ${result.severity}/10${C.reset}`);
  console.log(`${color}   Critical: ${result.critical}  Major: ${result.major}  Minor: ${result.minor}${C.reset}`);
  console.log(`${color}   Verdict:  ${result.verdict}${C.reset}`);
}

// ===========================================
// PLANNING CYCLE
// ===========================================

async function runPlanningCycle(task: string, priorGaps?: string): Promise<void> {
  const context = getGitContext();

  let firstPrompt = PLAN_PROMPT
    .replace('{task}', task)
    .replace('{context}', context);

  if (priorGaps) {
    firstPrompt = PRIOR_GAPS_PREFIX.replace('{gaps}', priorGaps) + firstPrompt;
  }

  const messages: MessageParam[] = [];

  // Turn 1: initial plan
  messages.push({ role: 'user', content: firstPrompt });
  const plan = await streamToConsole(messages);
  messages.push({ role: 'assistant', content: plan });

  // Turn 2: revision 1
  messages.push({ role: 'user', content: REVISION_1 });
  const rev1 = await streamToConsole(messages);
  messages.push({ role: 'assistant', content: rev1 });

  // Turn 3: revision 2
  messages.push({ role: 'user', content: REVISION_2 });
  const rev2 = await streamToConsole(messages);
  messages.push({ role: 'assistant', content: rev2 });
}

// ===========================================
// AUDIT CYCLE
// ===========================================

async function runAuditCycle(task: string, auditIndex: number, diff: string): Promise<string> {
  const auditPrompt = AUDIT_PROMPTS[auditIndex % 3] +
    AUDIT_SUFFIX.replace('{diff}', diff);

  const messages: MessageParam[] = [
    {
      role: 'user',
      content: `We just finished implementing: ${task}\n\n${auditPrompt}`,
    },
  ];

  return streamToConsole(messages);
}

// ===========================================
// MAIN
// ===========================================

async function main(): Promise<void> {
  const argv = process.argv.slice(2);

  // --list flag (no API key needed)
  if (argv[0] === '--list' || argv[0] === 'list') {
    const list = parseTaskList();
    printTaskList(list);
    process.exit(0);
  }

  // API key check — only needed for actual Claude calls
  if (!process.env.ANTHROPIC_API_KEY) {
    console.error(`${C.red}${C.bold}Error: ANTHROPIC_API_KEY is not set.${C.reset}`);
    console.error('Export it in your shell or add it to ~/.zshrc:');
    console.error('  export ANTHROPIC_API_KEY=sk-ant-...');
    process.exit(1);
  }

  const { task, taskId, list } = await selectTask(argv);
  const today = new Date().toISOString().slice(0, 10);

  console.log(`\n${C.bold}Working on: ${C.cyan}${task}${C.reset}`);
  console.log(`${C.dim}Model: ${MODEL} | Max cycles: ${MAX_CYCLES}${C.reset}\n`);

  let auditIndex = 0;
  let priorGaps: string | undefined;

  for (let cycle = 0; cycle < MAX_CYCLES; cycle++) {
    printHeader(`PLANNING CYCLE ${cycle + 1}`);
    await runPlanningCycle(task, priorGaps);

    await waitForEnter(`\n${C.yellow}${C.bold}✋  Plan complete. Implement this in Claude Code, then press Enter...${C.reset}`);

    const diff = getGitDiff();
    printHeader(`AUDIT ${auditIndex + 1}`);
    const auditText = await runAuditCycle(task, auditIndex, diff);

    const result = parseAuditResult(auditText);
    printAuditSummary(result);

    if (result && auditPassed(result)) {
      // Mark task done
      if (taskId !== undefined) {
        markTaskDone(list, taskId, today);
        console.log(`\n${C.green}Task #${taskId} marked complete.${C.reset}`);
      }
      console.log(`\n${C.green}${C.bold}✅  All audits passed. Task complete.${C.reset}\n`);
      process.exit(0);
    }

    // Extract gaps and add to task list
    addGapTasks(list, auditText, today);

    priorGaps = extractGapSummary(auditText);
    auditIndex++;

    if (cycle < MAX_CYCLES - 1) {
      console.log(`\n${C.yellow}Gaps found. Starting re-planning cycle...${C.reset}`);
    }
  }

  console.log(`\n${C.red}${C.bold}⚠️   Max cycles (${MAX_CYCLES}) reached. Review remaining gaps manually.${C.reset}`);
  console.log(`Run: ${C.cyan}autocode --list${C.reset} to see outstanding tasks.\n`);
  process.exit(1);
}

main().catch(err => {
  console.error(`\n${C.red}Fatal error: ${err instanceof Error ? err.message : String(err)}${C.reset}`);
  process.exit(1);
});
