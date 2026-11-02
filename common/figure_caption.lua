-- luacheck: globals pandoc

-- One caption per figure: the manual caption if any, else the alt text.
-- pandoc makes a figure of an image alone in its paragraph, with the alt text as caption (`implicit_figures`).
-- GitHub does not show the alt text, so a document may add a manual caption just after the image: a paragraph
-- starting with `Figure <number>`, optionally in italic or in a quote, or on the next line of the same paragraph:
--
--     ![<alt text>](images/x.png)
--
--     *Figure 1: <caption>*
--
-- This paragraph becomes the caption of the figure, instead of the alt text, and is removed from the body.
-- Figures are not numbered by the output (latex/pdf_in_header.tex, typst/report.typ): the manual caption has the
-- number, as on GitHub.
-- The numbers of the captions, manual or alt text, must be 1, 2, 3... in the order of the document: a warning tells a
-- gap, a duplicate or a wrong order, e.g. after a figure is added. Only plain numbers: not `Figure 1.2` or `Figure 3a`.

local CAPTION_START = "^Figure%s+%d"

-- @param inlines pandoc.Inlines text after the image
-- @return pandoc.Inlines|nil the manual caption, or nil
local function caption_of(inlines)
    while inlines[1] and (inlines[1].t == "SoftBreak" or inlines[1].t == "LineBreak" or inlines[1].t == "Space") do
        inlines:remove(1)
    end
    if not pandoc.utils.stringify(inlines):match(CAPTION_START) then return nil end
    -- the style of the caption is the one of the output, not the emphasis used for GitHub
    if #inlines == 1 and (inlines[1].t == "Emph" or inlines[1].t == "Strong") then return inlines[1].content end
    return inlines
end

-- @param block pandoc.Block|nil block after the image
-- @return pandoc.Inlines|nil the manual caption, or nil
local function block_caption(block)
    if block == nil then return nil end
    if block.t == "Para" then return caption_of(block.content:clone()) end
    if block.t == "BlockQuote" and #block.content == 1 and block.content[1].t == "Para" then
        return caption_of(block.content[1].content:clone())
    end
    return nil
end

-- @param block pandoc.Block
-- @return pandoc.Image|nil the image, when it is alone: figure (alt text), or paragraph (no alt text)
local function lone_image(block)
    local inlines
    if block.t == "Figure" and #block.content == 1 and block.content[1].t == "Plain" then
        inlines = block.content[1].content
    elseif block.t == "Para" then
        inlines = block.content
    else
        return nil
    end
    if #inlines == 1 and inlines[1].t == "Image" then return inlines[1] end
    return nil
end

-- @return pandoc.Figure
local function figure(image, caption, attr)
    return pandoc.Figure(pandoc.Plain({ image }), { pandoc.Plain(caption) }, attr)
end

function Blocks(blocks)
    local result = pandoc.Blocks({})
    local i = 1
    while i <= #blocks do
        local block = blocks[i]
        local image = lone_image(block)
        local caption = image and block_caption(blocks[i + 1])
        if caption then
            result:insert(figure(image, caption, block.t == "Figure" and block.attr or nil))
            -- the manual caption is not kept in the body
            i = i + 1
        elseif block.t == "Para" and #block.content > 1 and block.content[1].t == "Image" then
            -- manual caption on the next line of the same paragraph
            local inline_caption = caption_of(pandoc.Inlines({ table.unpack(block.content, 2) }))
            result:insert(inline_caption and figure(block.content[1], inline_caption) or block)
        else
            result:insert(block)
        end
        i = i + 1
    end
    return result
end

-- @param caption pandoc.Caption caption of a figure
-- @return integer|nil the number, when the caption starts with `Figure <plain number>`
local function caption_number(caption)
    local number, after = pandoc.utils.stringify(caption.long):match("^Figure%s+(%d+)(.?.?)")
    -- not plain: `Figure 1.2`, `Figure 3a`
    if number == nil or after:match("^%w") or after:match("^%.%w") then return nil end
    return tonumber(number)
end

-- Runs after Blocks: checks the final captions, in the order of the document
function Pandoc(doc)
    local previous = 0
    doc:walk({
        Figure = function(fig)
            local number = caption_number(fig.caption)
            if number == nil then return nil end
            if number ~= previous + 1 then
                local place = previous == 0 and "first numbered figure" or ("after Figure " .. previous)
                pandoc.log.warn(("Figure %d (%s): expected Figure %d"):format(number, place, previous + 1))
            end
            -- continue from the number found: one mistake, one warning
            previous = number
        end,
    })
    return nil
end
