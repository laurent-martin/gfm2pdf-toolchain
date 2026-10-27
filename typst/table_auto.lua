-- For Typst output, size the columns of wide tables from their content.
-- pandoc gives a pipe table wider than 72 characters relative column widths taken from the
-- dashes of its separator row. When all columns got the same width (separator not tuned,
-- e.g. `| --- | --- |`), the columns are left to Typst (`auto`), which sizes them from the cells.
-- Tables with a tuned separator row, and narrow tables (natural widths), are left unchanged,
-- as in latex/table_widths.lua.
-- luacheck: globals FORMAT pandoc

if not FORMAT:match("typst") then return {} end

-- True if all columns have the same relative width, i.e. the separator row was not tuned
local function equal_widths(colspecs)
  local first = colspecs[1][2]
  if type(first) ~= "number" then return false end
  for _, colspec in ipairs(colspecs) do
    if type(colspec[2]) ~= "number" or math.abs(colspec[2] - first) > 1e-6 then return false end
  end
  return true
end

function Table(tbl)
  if #tbl.colspecs < 2 or not equal_widths(tbl.colspecs) then return nil end
  for i, colspec in ipairs(tbl.colspecs) do
    tbl.colspecs[i] = { colspec[1], pandoc.ColWidthDefault }
  end
  return tbl
end
