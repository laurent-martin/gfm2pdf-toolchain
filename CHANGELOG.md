# Changelog

## 1.0.0.pre

Released: [Place date of release here]

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
