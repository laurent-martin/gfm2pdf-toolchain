# Changelog

## 1.1.0.pre

Released: [Place date of release here]

### New

- Figures: a warning when the numbers of the captions are not 1, 2, 3... in the order of the document (gap,
  duplicate, wrong order), e.g. after a figure is added.
- Figures: a mention `Figure <number>` in the text is a link to the figure, with a warning if no figure has this
  number.
- Command `renumber-figures <input.md>`: renumbers the figure captions 1, 2, 3... in the Markdown file, and the
  mentions `Figure <number>` with them. To add a figure, give it a number not used yet, e.g. `Figure 0`.
- Env var or `make` variable `GFM2PDF_MODE`: `build` (default), `check` (a warning is an error, internal links are
  checked, no output on failure: for CI) or `fix` (renumber the figures of the Markdown files, then build). With
  `make`, `check` and `fix` also generate the documents that are up to date.

### Changed

- Figures: one caption, the manual caption (paragraph `Figure <number> ...` just after the image, as shown by GitHub)
  if any, else the alt text: the manual caption is no longer duplicated. PDF engines no longer add a label
  `Figure 1.1:` to captions.

### Fixed

- PDF: remote images (`![alt](https://...)`) are downloaded, Typst has no network access.
- PDF with LaTeX: characters missing in the main fonts and in the emoji font, e.g. `●`, are shown with DejaVu Sans,
  or DejaVu Sans Mono in code (TeX Live), instead of being dropped.

## 1.0.0

Released: 2026-10-27

Initial version.

### New

- Conversion of a GitHub-flavored Markdown file to a PDF report, with a cover page, a table of contents, numbered
  chapters and a last page, or to HTML: `lib/pandoc.rb`, `make` rules in `pandoc.mak`.
- PDF engines: LuaLaTeX (default) or Typst, selected with `GFM2PDF_ENGINE`.
- GitHub alerts (`> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`, `> [!CAUTION]`) rendered as colored boxes.
- Tables: line breaks with `<br/>` in cells, column widths from the content.
- Code: inline code breaks only after separators, long lines in code blocks are wrapped and marked with `↪`.
- Images: HTML `<img>` tags, SVG, and in PDF documents the PDF next to an SVG image.
- draw.io diagrams: export of each tab to SVG and PDF, `drawio.mak` and `lib/drawio.rb`.
- Options of a document: `pandoc` defaults in a comment `<!-- gfm2pdf` of the Markdown file, or in the file
  `<name>.gfm2pdf.yaml` next to it, in sections: `common`, `pdf`, `html`, `latex`, `typst`.
- Themes: background of the cover and last pages, fonts, any `pandoc` option, selected with `GFM2PDF_THEME`.
- Check of the internal links, on GitHub and in the PDF: `pandoc.rb check-anchors`.
- Versions: file `VERSION`, tags `vX.Y.Z`, release with `rake release:run` or the GitHub Actions workflow
  **Release**. A project checks the version it uses with `GFM2PDF_VERSION_REQUIRED`, `Gfm2Pdf.check_version` or
  `pandoc.rb version <requirement>`.
- Tests: `rake test`.
