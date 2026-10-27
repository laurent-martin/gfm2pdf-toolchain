# gfm2pdf-toolchain

Generate a PDF manual, or an HTML page, from a GitHub-flavored Markdown file, using `pandoc`.

The same Markdown file renders on GitHub, and as a PDF report with a cover page, a table of contents, numbered
chapters, admonition boxes, and tables and code that fit the page.

The PDF engine is LuaLaTeX (default) or [Typst](https://typst.app).

## Requirements

| Tool | Needed for | Tested version |
| --- | --- | --- |
| [`pandoc`](https://pandoc.org) | everything | 3.12 |
| `ruby` | everything | 4.0 |
| `lualatex` (TeX Live), `inkscape` (SVG images) | PDF with LaTeX (default) | TeX Live 2026 |
| [`typst`](https://typst.app) | PDF with Typst | 0.15 |
| GNU `make` | `pandoc.mak`, `drawio.mak` | 3.81 |
| [draw.io desktop](https://www.drawio.com) | `drawio.mak` | |
| [GitHub CLI](https://cli.github.com) (`gh`) | publication of a release | |

Fonts: the default ones come with the PDF engine: Latin Modern (TeX Live), New Computer Modern (Typst), and DejaVu
Sans Mono for code, a [theme](#themes) can set others. For emoji: Apple Color Emoji (macOS) or Noto Color Emoji
(Linux).

## Usage

1. In a folder, create a Markdown file, e.g. `README.md`.
1. Create a `Makefile` like this:

    ```makefile
    GFM2PDF_DIR ?= ../gfm2pdf-toolchain
    include $(GFM2PDF_DIR)/pandoc.mak
    all: README.pdf
    clean:
        rm -f README.pdf
    ```

    `GFM2PDF_DIR` is the folder of this repository: for example a `git` submodule of the project, at the version used
    by the project. To use another copy, set the env var `GFM2PDF_DIR`, e.g. for a copy shared by several projects:

    ```shell
    export GFM2PDF_DIR=$HOME/workspace/gfm2pdf-toolchain
    ```

    There is a default target for `%.pdf` from `%.md`.
    If the source and destination have different base names or paths:

    ```makefile
    $(eval $(call markdown_to_pdf,source.md,target.pdf))
    $(eval $(call markdown_to_html,source.md,target.html))
    ```

1. Run `make` to generate the PDF file.

Without `make`, call the script directly:

```shell
ruby lib/pandoc.rb pdf README.md README.pdf
ruby lib/pandoc.rb html README.md README.html
ruby lib/pandoc.rb check-anchors README.md
ruby lib/pandoc.rb deps
ruby lib/pandoc.rb version
```

`check-anchors` checks that internal links (`[text](#anchor)`) match a heading, both on GitHub and in the PDF: GitHub
and `pandoc` generate heading identifiers differently (e.g. `.` is kept by `pandoc`).
`deps` lists the files of the toolchain and of the theme: `pandoc.mak` makes the generated documents depend on them.

Messages go to stderr, set `GFM2PDF_LOG_LEVEL` (`debug`, `info`, `warn`, `error`) to change the level (default:
`info`).

Variables of `pandoc.mak` start with `GFM2PDF_`, so that they do not change the ones of the including Makefile.

## PDF engines

| | LuaLaTeX (default) | Typst |
| --- | --- | --- |
| Speed (200 page manual) | 90 seconds | 3 seconds |
| Table column widths | from content, by `latex/table_widths.lua` | from content, by `typst` |
| Line breaks in inline code | `latex/code_break.lua` | Typst show rule |
| Long lines in code blocks | wrapped, continuation lines indented with `↪` | same |
| SVG images | converted by `inkscape` | native |
| draw.io diagrams (`drawio.mak`) | PDF exported by draw.io | same |
| Tagged PDF (accessibility) | no | yes |
| Same PDF for the same Markdown file | yes | yes |

Select the engine with the env var or `make` variable `GFM2PDF_ENGINE`: `latex` (default) or `typst`.
In a `Makefile`, it can be set per target:

```makefile
manual.pdf: GFM2PDF_ENGINE = typst
```

The date of the document is the date of the last commit of the Markdown file, or its modification time if it has
local changes or is not in `git`.

## Options of a document

The options of a document are `pandoc` [defaults](https://pandoc.org/MANUAL.html#defaults-files), in sections:

| Section | Used for |
| --- | --- |
| `common` | all outputs |
| `pdf` | PDF, both engines |
| `latex` | PDF with LaTeX |
| `typst` | PDF with Typst |
| `html` | HTML |

They are in a comment of the Markdown file, outside code blocks: the comment starts with a line `<!-- gfm2pdf` and
ends with a line `-->`. For example:

```markdown
<!-- gfm2pdf
common:
  metadata:
    subtitle: "User guide"
    author: "Johnny Beegood"
latex:
  include-before-body:
    - README.preface.tex
-->
```

Or they are in a file next to the Markdown file, with the same content: `README.gfm2pdf.yaml` for `README.md`, e.g.
when the Markdown file is generated. Both can be used.

`${.}` is the folder of the Markdown file, and relative paths are relative to it. Content written in the language of
the engine goes in the section of the engine, e.g. a page after the cover with `include-before-body` and a `.tex` or
`.typ` file. An unknown section is an error.

Defaults are applied in this order, the last one wins: `common/defaults.yaml` and `<engine or html>/defaults.yaml` of
the toolchain, the `<engine or html>.yaml` file of the [theme](#themes), the comment, then the file of the document.
In the comment and in the file: section `common`, then `pdf` or `html`, then `latex` or `typst`.

## Themes

The toolchain has no branding: by default, the cover and last pages have no background, and the fonts are the ones
that come with the PDF engine. A theme gives the look of the documents of a project, or of several projects. It is a
folder, e.g. in the repository of a project, with any of these files:

| File | Content |
| --- | --- |
| `latex.yaml`, `typst.yaml`, `html.yaml` | `pandoc` defaults for this output, e.g. fonts, `${.}` is the folder of the theme |
| `cover.tex` | PDF with LaTeX: background of the cover and last pages, redefines `\gfmcoverbackground` |
| `cover.typ` | PDF with Typst: background of the cover and last pages, `cover-background` |

Images in `cover.tex` and `cover.typ` are relative to the folder of the theme.

Select the theme with the env var or `make` variable `GFM2PDF_THEME`. In a `Makefile`, set it before including
`pandoc.mak`, so that the files of the theme are dependencies of the documents, and with `?=`, so that the env var
overrides it:

```makefile
GFM2PDF_THEME ?= ../brand/pdf_theme
include $(GFM2PDF_DIR)/pandoc.mak
```

Example of a theme, with images at the top and bottom of the cover and last pages, and other fonts:

- `cover.tex`:

    ```latex
    \renewcommand{\gfmcoverbackground}{\AddToShipoutPictureBG*{
        \AtPageUpperLeft{\raisebox{-\height}{\includegraphics[width=\paperwidth]{cover_top.png}}}
        \AtPageLowerLeft{\includegraphics[width=\paperwidth]{cover_bottom.png}}
      }}
    ```

- `cover.typ`:

    ```typst
    #let cover-background = {
      place(top, image("cover_top.png", width: 100%))
      place(bottom, image("cover_bottom.png", width: 100%))
    }
    ```

- `latex.yaml`:

    ```yaml
    variables:
      mainfont: "Source Sans 3"
      monofont: "Source Code Pro"
    ```

- `typst.yaml`:

    ```yaml
    variables:
      mainfont: "Source Sans 3"
      codefont: "Source Code Pro"
    ```

## Markdown

- [Alerts](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#alerts)
  (`> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`, `> [!CAUTION]`) become colored boxes.
- The first level 1 heading is the title of the document, level 2 headings are chapters.
- HTML `<img>` tags are converted to Markdown images.
- Inline code breaks at the end of a line only after separators (`/`, `=`, `,`, `.`, `_`, ...), not after hyphens:
  `--transfer=direct` never breaks after `--`.
- Short (MultiMarkdown) subscripts are disabled: `~600 ms` or `~/.ssh` stay as typed, `H~2~O` is still a subscript.

### Tables

- A `<br/>` in a table cell breaks the line (`common/break_replace.lua`).
- Column widths: for a pipe table wider than 72 characters, `pandoc` takes relative widths from the dashes of the
  separator row. With equal dashes (`| --- | --- |`), the widths are computed from the cell contents: each column
  gets at least its longest word, the rest is shared by text length. To set the widths yourself, tune the dashes,
  e.g. `| ---- | ------------------ |`.

## Diagrams (draw.io)

`drawio.mak` exports each tab of a draw.io file to an image named after the tab, next to the file, with draw.io
desktop (`lib/drawio.rb`). An image is exported again only when older than the draw.io file. The
"Text is not SVG - cannot display" link that draw.io appends to SVG files is removed, as renderers without
`foreignObject` support would display it.

For SVG, `drawio.mak` also exports a PDF of each tab, cropped to the diagram, and adds it to `DRAWIO_IMAGES`.
In PDF documents, an image `x.svg` is replaced by `x.pdf` when it is next to it (`common/pdf_instead_of_svg.lua`):
the Markdown file links to the SVG, for GitHub and HTML, and the PDF has the exact rendering of draw.io, with its
text. In draw.io SVG files, labels are HTML (`foreignObject`), that `inkscape` and `typst` only show as bitmaps, and
colors use CSS `light-dark()` (for dark mode), that `typst` renders in black.

```makefile
include $(GFM2PDF_DIR)/pandoc.mak
DRAWIO_FILE = images/diagrams.drawio
include $(GFM2PDF_DIR)/drawio.mak
all: diagrams README.pdf
README.pdf: $(DRAWIO_IMAGES)
```

Optional variables, set before the `include`: `DRAWIO_FORMAT` (default: `svg`), `DRAWIO_OPTIONS` (draw.io CLI
options, default: `--scale 2`).

## Versions

The version is in the file `VERSION`: `X.Y.Z` for a release, tagged `vX.Y.Z`, and `X.Y.Z.pre` between releases, on
the branch `main`. The changes of each version are in [CHANGELOG.md](CHANGELOG.md).

| Change of | When |
| --- | --- |
| `X` (major) | incompatible change for a project: `make` variables, env vars, commands and Ruby API of `lib/pandoc.rb` and `lib/drawio.rb`, files and hooks of a theme, options of a document |
| `Y` (minor) | new features, visible changes of the rendering, e.g. default fonts |
| `Z` (patch) | fixes |

A project uses a version of the toolchain, e.g. a `git` submodule or a CI checkout at a tag, or a copy shared by
several projects. It can check that this version meets its requirement:

```makefile
GFM2PDF_VERSION_REQUIRED ?= ~> 1.0
include $(GFM2PDF_DIR)/pandoc.mak
```

In Ruby: `Gfm2Pdf.check_version('~> 1.0')`, from the shell: `ruby lib/pandoc.rb version '~> 1.0'`.
Requirements use the [RubyGems syntax](https://guides.rubygems.org/patterns/#declaring-dependencies): `~> 1.0` means
`>= 1.0` and `< 2.0`, and `>= 1.1, < 3` is a range. A version `X.Y.Z.pre` is lower than `X.Y.Z`.
`pandoc.mak` defines `GFM2PDF_VERSION`: the version of the toolchain.

## Contents

| Folder | Content |
| --- | --- |
| `common/` | `pandoc` defaults and Lua filters for all outputs: admonitions, line breaks in tables, PDF instead of SVG |
| `typst/` | PDF with Typst: template (`report.typ`), admonition boxes, table widths |
| `latex/` | PDF with LuaLaTeX: LaTeX header and last page, table widths, line breaks in inline code |
| `html/` | HTML: style of admonition boxes |
| `lib/` | `pandoc.rb`: conversions, `drawio.rb`: export of draw.io diagrams |
| `test/` | tests and their fixtures |
| `rakelib/` | `rake` tasks: release |
| `.github/workflows/` | GitHub Actions: release |

## Tests

```shell
rake test
```

Tests needing a tool that is not installed (`typst`, `lualatex`, `make`, Poppler: `pdftotext`, `pdfinfo`, `pdfimages`,
`pdffonts`) are skipped.

Ruby style, same as aspera-cli: `rubocop`, with the gems `rubocop`, `rubocop-performance` and `rubocop-shopify`.

## Release

List the changes in the first section of `CHANGELOG.md`, push them, then on GitHub: Actions, workflow
**Release**, **Run workflow**, with optional versions (`.github/workflows/release.yml`). It installs the tools of the
tests and runs `rake release:run`. Or, locally:

```shell
rake release:run
```

1. Checks: on the branch `main`, all changes committed, the tag does not exist, the tests pass.
1. Release: `VERSION` without `.pre`, version and date in `CHANGELOG.md`, empty subsections removed, commit
   `Release vX.Y.Z` and tag `vX.Y.Z`.
1. If the remote `origin` exists: push, and GitHub release with the changes of the version (`gh`).
1. Next version: `X.Y+1.0.pre` in `VERSION`, new section in `CHANGELOG.md`, commit
   `Prepare for next development cycle (X.Y+1.0.pre)`, push.

The versions can be given: `rake 'release:run[1.0.1,1.0.2]'` releases `1.0.1`, then `1.0.2.pre`.
A release made without remote is published later with `rake 'release:publish[1.0.0]'`.
With `DRY_RUN=1`, the `git` and `gh` commands that change something are displayed, not executed: `VERSION` and
`CHANGELOG.md` are still modified, restore them with `git checkout VERSION CHANGELOG.md`.

## License

[Apache-2.0](LICENSE)
