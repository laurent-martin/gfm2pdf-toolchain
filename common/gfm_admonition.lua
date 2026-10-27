-- Convert styled admonition Div blocks (e.g. note, warning, tip) into
-- corresponding HTML, LaTeX or Typst representations with icons, colors, and titles.
-- Uses predefined visual styles from `box_styles` for consistent formatting.
-- The body blocks stay in the document, between a raw opening and a raw closing block,
-- so that the next filters (e.g. code_break.lua, table_widths.lua) process them too.
-- luacheck: globals FORMAT pandoc
-- https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#alerts
-- https://tug.ctan.org/info/symbols/comprehensive/symbols-a4.pdf
-- Colors for HTML: gfm_admonition.css, for Typst: admonition.typ
local box_styles = {
  note = {
    -- gfm : blue circled i
    emoji = "ℹ️",
    latex = {
      icon      = "InfoCircle",
      back      = "blue!5",
      title     = "white",
      backtitle = "blue!75!black",
    },
  },
  tip = {
    -- gfm : green lightbulb
    emoji = "💡",
    latex = {
      icon      = "Lightbulb",
      back      = "green!5",
      title     = "white",
      backtitle = "green!60!black",
    },
  },
  important = {
    -- gfm : purple speech bubble exclamation
    emoji = "❕",
    latex = {
      icon      = "Bullhorn",
      back      = "orange!5",
      title     = "white",
      backtitle = "orange!70!black",
    },
  },
  warning = {
    -- gfm : yellow triangle exclamation
    emoji = "⚠️",
    latex = {
      icon      = "ExclamationTriangle",
      back      = "red!5",
      title     = "white",
      backtitle = "red!75!black",
    },
  },
  caution = {
    -- gfm : red circled exclamation mark
    emoji = "❗",
    latex = {
      icon      = "Exclamation",
      back      = "yellow!5",
      title     = "black",
      backtitle = "yellow!70!black",
    },
  },
}

-- Raw blocks opening and closing the box, for the output format
local function box_delimiters(admon_type, style, title)
  if FORMAT:match("latex") then
    local latex = style.latex
    local opts = string.format(
      "enhanced, breakable, colback=%s, colframe=%s, coltitle=%s, colbacktitle=%s, title={\\fa%s\\ %s}",
      latex.back, latex.backtitle, latex.title, latex.backtitle, latex.icon, title
    )
    return pandoc.RawBlock("latex", "\\begin{tcolorbox}[" .. opts .. "]"),
        pandoc.RawBlock("latex", "\\end{tcolorbox}")
  elseif FORMAT:match("typst") then
    return pandoc.RawBlock("typst", string.format('#admonition("%s", "%s", "%s")[', admon_type, style.emoji, title)),
        pandoc.RawBlock("typst", "]")
  elseif FORMAT:match("html") then
    return pandoc.RawBlock("html", string.format(
          '<div class="admonition %s">\n<div class="admonition-title">%s %s</div>\n<div class="admonition-body">',
          admon_type, style.emoji, title)),
        pandoc.RawBlock("html", "</div>\n</div>")
  end
end

function Div(el)
  if #el.classes == 0 then return nil end
  local admon_type = el.classes[1]
  local style = box_styles[admon_type]
  if not style then return nil end
  if not (el.content[1] and el.content[1].t == "Div" and el.content[1].classes:includes("title")) then return el end
  local title_div_content = el.content[1].content
  if #title_div_content ~= 1 or title_div_content[1].t ~= "Para" then return el end
  local title = pandoc.utils.stringify(title_div_content[1])
  local open, close = box_delimiters(admon_type, style, title)
  if not open then return el end
  local blocks = { open }
  for i = 2, #el.content do
    table.insert(blocks, el.content[i])
  end
  table.insert(blocks, close)
  return blocks
end
