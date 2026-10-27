-- luacheck: globals FORMAT PANDOC_STATE pandoc

-- For PDF output (LaTeX or Typst), use `x.pdf` instead of the image `x.svg` when it is next to it.
-- drawio.mak exports both: the SVG for GitHub and HTML, the PDF for PDF documents.
-- The labels of draw.io diagrams are HTML (SVG foreignObject): Inkscape and Typst only show a bitmap of them, and
-- Typst renders the colors of draw.io (CSS `light-dark()`) in black. The PDF exported by draw.io has the exact
-- rendering, with the text.
if not (FORMAT:match("latex") or FORMAT:match("typst")) then return {} end

-- @return true if the file exists
local function exists(path)
    local file = io.open(path, "r")
    if file == nil then return false end
    file:close()
    return true
end

function Image(img)
    if not img.src:match("%.svg$") then return nil end
    local pdf = img.src:gsub("%.svg$", ".pdf")
    -- Folder of the SVG: same lookup as pandoc
    for _, dir in ipairs(PANDOC_STATE.resource_path) do
        if exists(pandoc.path.join({ dir, img.src })) then
            if not exists(pandoc.path.join({ dir, pdf })) then return nil end
            img.src = pdf
            return img
        end
    end
end
