// Report template for pandoc Typst output: same layout as the LaTeX output (latex/).
// pandoc calls `conf(title: ..., subtitle: ..., authors: ..., date: ..., paper: ..., font: ..., doc)`,
// with the variables set in defaults.yaml (papersize, margin, mainfont, codefont, fontsize).
// Inputs (typst compile --input):
// - `emoji-font`: font for characters missing in the main fonts, e.g. 🔑
// - `cover`: absolute path of the cover.typ of a theme, see README.md

#let emoji-font = sys.inputs.at("emoji-font", default: "Noto Color Emoji")

// Background of the cover and last pages: from the theme, its images are relative to its folder
#let cover-background = if "cover" in sys.inputs {
  import sys.inputs.cover: cover-background
  cover-background
}

// Plain text of content, for PDF metadata
#let to-string(it) = {
  if type(it) == str { it }
  else if it.has("text") { it.text }
  else if it.has("children") { it.children.map(to-string).join("") }
  else if it.has("body") { to-string(it.body) }
  else { " " }
}

// Line of a code block: when it wraps, continuation lines are indented and marked with ↪ (as in the LaTeX output)
#let code-line(body) = layout(size => {
  let lead = par.leading.to-absolute()
  let line = par(justify: false, first-line-indent: 0pt, hanging-indent: 2em, body)
  // number of lines: from the height of the wrapped line and the height of one line
  let one = measure([x]).height
  let total = measure(block(width: size.width, line)).height
  let lines = calc.max(1, int(calc.round((total + lead) / (one + lead))))
  block(width: size.width, height: calc.max(total, one), {
    line
    for i in range(1, lines) { place(top + left, dy: i * (one + lead), pdf.artifact(text(fill: gray)[↪])) }
  })
})

#let conf(..args) = {
  let a = args.named()
  let doc = args.pos().first()
  let title = a.at("title", default: none)
  let subtitle = a.at("subtitle", default: none)
  let authors = a.at("authors", default: ())
  let date = a.at("date", default: none)
  let font = a.at("font", default: ("New Computer Modern",))
  let codefont = a.at("codefont", default: ("DejaVu Sans Mono",))

  set document(title: title)
  set document(author: authors.map(author => to-string(author.name))) if authors.len() > 0
  set page(paper: a.at("paper", default: "us-letter"), margin: a.at("margin", default: 12mm), numbering: "1")
  set text(font: font + (emoji-font,), size: a.at("fontsize", default: 10pt), lang: a.at("lang", default: "en"))
  set par(justify: true, first-line-indent: (amount: 2em, all: true))

  // Headings: level 1 is a chapter
  set heading(numbering: "1.1")
  show heading: set block(above: 1.6em, below: 1em)
  show heading.where(level: 2): set text(size: 1.4em)
  show heading.where(level: 3): set text(size: 1.2em)
  show heading.where(level: 4): set text(size: 1.05em)
  show heading.where(level: 1): it => {
    pagebreak(weak: true)
    set par(first-line-indent: 0pt)
    v(2em)
    if it.numbering != none {
      text(size: 1.4em, weight: "bold")[Chapter #counter(heading).display("1")]
      v(0.6em)
    }
    text(size: 2em, weight: "bold", it.body)
    v(1.2em)
  }
  show outline.entry.where(level: 1): it => {
    v(0.8em, weak: true)
    text(weight: "bold", it)
  }

  // Links: external blue, internal dark red
  show link: it => text(fill: if type(it.dest) == str { blue } else { rgb("#800000") }, it)

  // Code
  show raw: set text(font: codefont + (emoji-font,), size: 1.12em)
  show raw.where(block: false): it => highlight(fill: luma(222), top-edge: "ascender", bottom-edge: "descender", it)
  // Inline code breaks only after separators (as latex/code_break.lua), not after hyphens:
  // each segment is an unbreakable box, so no invisible character is added to the text
  show raw.where(block: false): it => { show regex("[^\s/=,.:_;&?|]+[/=,.:_;&?|]*|[/=,.:_;&?|]+"): box; it }
  show raw.where(block: true): it => block(width: 100%, fill: luma(235), inset: 6pt, radius: 2pt, breakable: true, context {
    // each line is a paragraph: same space between them as between the lines of a paragraph
    set par(spacing: par.leading)
    for line in it.lines { code-line(line.body) }
  })

  // Bold is rendered underlined (as in the LaTeX output)
  show strong: it => underline(it.body)

  // Quotes: left bar, italic
  show quote.where(block: true): it => block(stroke: (left: 3pt), inset: (left: 10pt, y: 2pt), emph(it.body))

  // Tables: may break across pages, alternate row colors, left aligned cells, no justification
  show figure.where(kind: table): set block(breakable: true)
  set table(inset: 4pt, fill: (_, y) => if y > 0 and calc.even(y) { luma(245) })
  show table: set par(justify: false, first-line-indent: 0pt)
  show table: set align(left)
  show table: set text(size: 0.95em)

  // Lists and terms: no paragraph indentation
  show list: set par(first-line-indent: 0pt)
  show enum: set par(first-line-indent: 0pt)
  show terms: set par(first-line-indent: 0pt)

  // Cover page
  page(numbering: none, background: cover-background, {
    set par(first-line-indent: 0pt)
    align(center + horizon, {
      if title != none { text(size: 1.7em, title) }
      if subtitle != none { parbreak(); text(size: 1.1em, subtitle) }
      v(2em)
      for author in authors { author.name; linebreak() }
      v(1em)
      if date != none { date }
    })
  })

  doc

  // Last page
  page(numbering: none, background: cover-background, align(center + horizon, text(size: 2.5em)[End of document]))
}
