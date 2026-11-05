// Background of the cover page, other background on the last page, own text on the cover page
#let cover-background = place(top, image("cover.png", width: 100%))
#let last-background = place(bottom, image("last.png", width: 100%))
#let cover-text(title: none, subtitle: none, authors: (), date: none) = place(top + left, dx: 12mm, dy: 12mm, {
  [Theme cover]
  linebreak()
  title
  linebreak()
  subtitle
  linebreak()
  for author in authors { author.name; linebreak() }
  date
})
