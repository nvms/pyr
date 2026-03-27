import { createHighlighter } from 'shiki'
import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync, cpSync } from 'fs'
import { join, dirname, basename } from 'path'
import { fileURLToPath } from 'url'
import { execSync } from 'child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
const CONTENT_DIR = join(__dirname, 'content')
const OUT_DIR = join(__dirname, 'dist')
const GRAMMAR_PATH = join(__dirname, '..', 'editors', 'vscode', 'syntaxes', 'pyr.tmLanguage.json')
const TEMPLATE_PATH = join(__dirname, 'template.html')
const PYR_BIN = join(__dirname, '..', 'zig-out', 'bin', 'pyr')

function parseExample(raw) {
  const lines = raw.split('\n')
  const segments = []
  let docs = []
  let code = []

  for (const line of lines) {
    const commentMatch = line.match(/^\/\/\s?(.*)$/)
    if (commentMatch) {
      if (code.length > 0) {
        segments.push({ docs: docs.join('\n'), code: code.join('\n') })
        docs = []
        code = []
      }
      docs.push(commentMatch[1])
    } else {
      code.push(line)
    }
  }

  if (docs.length > 0 || code.length > 0) {
    segments.push({ docs: docs.join('\n'), code: code.join('\n') })
  }

  return segments
}

function parseFrontmatter(raw) {
  if (!raw.startsWith('---\n')) return { meta: {}, body: raw }
  const end = raw.indexOf('\n---\n', 4)
  if (end === -1) return { meta: {}, body: raw }
  const front = raw.slice(4, end)
  const body = raw.slice(end + 5)
  const meta = {}
  for (const line of front.split('\n')) {
    const [key, ...rest] = line.split(':')
    if (key && rest.length) meta[key.trim()] = rest.join(':').trim()
  }
  return { meta, body }
}

function renderDocs(text) {
  const escaped = text.replace(/`([^`]+)`/g, '<code>$1</code>')
  const paragraphs = escaped.split('\n\n')
  return paragraphs
    .map(p => `<p>${p.replace(/\n/g, ' ')}</p>`)
    .join('\n')
}

async function main() {
  const grammar = JSON.parse(readFileSync(GRAMMAR_PATH, 'utf8'))
  const highlighter = await createHighlighter({
    themes: ['vitesse-black'],
    langs: [grammar],
  })

  const template = readFileSync(TEMPLATE_PATH, 'utf8')

  const files = readdirSync(CONTENT_DIR)
    .filter(f => f.endsWith('.pyr'))
    .sort()

  const examples = []
  for (const file of files) {
    const raw = readFileSync(join(CONTENT_DIR, file), 'utf8')
    const { meta, body } = parseFrontmatter(raw)
    const slug = basename(file, '.pyr').replace(/^\d+-/, '')
    const runnable = meta.run !== 'false'
    let output = null
    if (runnable) {
      try {
        const stripped = body.replace(/^\/\/.*$/gm, '').trim()
        const tmpFile = join(OUT_DIR, '_tmp.pyr')
        mkdirSync(OUT_DIR, { recursive: true })
        writeFileSync(tmpFile, stripped)
        const result = execSync(`sh -c '"${PYR_BIN}" run "${tmpFile}" 2>&1'`, {
          timeout: 5000,
          encoding: 'utf8',
        })
        output = result.trimEnd()
      } catch {
        output = null
      }
      try { writeFileSync(tmpFile, ''); } catch {}
    }

    examples.push({
      slug,
      title: meta.title || slug.replace(/-/g, ' '),
      description: meta.description || '',
      order: meta.order || '99',
      file,
      output,
      segments: parseExample(body.trim()),
    })
  }

  examples.sort((a, b) => Number(a.order) - Number(b.order))

  const nav = examples
    .map(e => `<a href="${e.slug}.html">{title}</a>`.replace('{title}', e.title))
    .join('\n        ')

  mkdirSync(OUT_DIR, { recursive: true })

  for (const example of examples) {
    const rows = example.segments.map((seg, i) => {
      const isLast = i === example.segments.length - 1
      const codeClass = isLast ? 'code' : 'code leading'
      const highlighted = seg.code.trim()
        ? highlighter.codeToHtml(seg.code.replace(/^\n+|\n+$/g, ''), {
            lang: 'pyr',
            theme: 'vitesse-black',
          })
        : ''

      return `          <tr>
            <td class="docs">${renderDocs(seg.docs)}</td>
            <td class="${codeClass}">${highlighted}</td>
          </tr>`
    }).join('\n')

    let outputBlock = ''
    if (example.output) {
      const escaped = example.output
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
      outputBlock = `      <div class="output">
        <table>
          <tr>
            <td class="docs"></td>
            <td class="code">
              <pre><span class="shell-prompt">$ </span><span class="shell-cmd">pyr run ${example.file.replace(/^\d+-/, '')}</span>\n${escaped}</pre>
            </td>
          </tr>
        </table>
      </div>`
    }

    const descBlock = example.description
      ? `<p class="description">${example.description}</p>`
      : ''

    const html = template
      .replaceAll('{{title}}', example.title)
      .replace('{{description}}', descBlock)
      .replace('{{nav}}', nav)
      .replace('{{rows}}', rows)
      .replace('{{output}}', outputBlock)
      .replace('{{prev}}', getPrev(examples, example))
      .replace('{{next}}', getNext(examples, example))

    writeFileSync(join(OUT_DIR, `${example.slug}.html`), html)
  }

  const indexNav = examples
    .map(e => `<li><a href="${e.slug}.html">${e.title}</a></li>`)
    .join('\n          ')

  const indexHtml = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>pyr by example</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <div id="intro">
    <h1>Pyr by Example</h1>
    <p>
      Pyr is a systems programming language with scripting ergonomics, built in Zig.
      No GC, no runtime overhead, arena-scoped memory.
      High-level code reads like Python, low-level code reads like Zig - same language, different depths.
    </p>
    <ul>
      ${indexNav}
    </ul>
    <p class="footer">
      <a href="https://github.com/nvms/pyr">github</a>
    </p>
  </div>
</body>
</html>`

  writeFileSync(join(OUT_DIR, 'index.html'), indexHtml)

  const cssSource = join(__dirname, 'style.css')
  if (existsSync(cssSource)) {
    cpSync(cssSource, join(OUT_DIR, 'style.css'))
  }

  console.log(`built ${examples.length} examples -> ${OUT_DIR}`)
}

function getPrev(examples, current) {
  const idx = examples.indexOf(current)
  if (idx <= 0) return ''
  const prev = examples[idx - 1]
  return `<a href="${prev.slug}.html">&laquo; ${prev.title}</a>`
}

function getNext(examples, current) {
  const idx = examples.indexOf(current)
  if (idx >= examples.length - 1) return ''
  const next = examples[idx + 1]
  return `<a href="${next.slug}.html">${next.title} &raquo;</a>`
}

main().catch(err => {
  console.error(err)
  process.exit(1)
})
