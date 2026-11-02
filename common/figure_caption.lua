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
-- `lib/pandoc.rb renumber-figures` fixes the numbers in the Markdown file, with the same rules: keep them aligned.
-- A numbered figure gets the identifier `fig-<number>` (unless it has one; `fig-<number>-1` if taken), and a mention
-- `Figure <number>` in the text links to it, e.g. `see Figure 3.`, with a warning if no figure has this number.
-- Not linked: headings, captions, text of links and images, `Figure 2 of RFC 1234` (figure of another document).

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

-- @param text string text starting with a number, e.g. `3: caption`, `3,` or `1.2`
-- @return integer|nil the number, when plain: not `1.2`, `3a`
-- @return string the text after the number
local function plain_number(text)
    local number, after = text:match("^(%d+)(.*)$")
    if number == nil or after:match("^%w") or after:match("^%.%w") then return nil, after end
    return tonumber(number), after
end

-- @param caption pandoc.Caption caption of a figure
-- @return integer|nil the number, when the caption starts with `Figure <plain number>`
local function caption_number(caption)
    local text = pandoc.utils.stringify(caption.long):match("^Figure%s+(.*)$")
    if text == nil then return nil end
    return (plain_number(text))
end

local SEPARATORS = { Space = true, SoftBreak = true }

-- @param ids table identifier of the figure of each number
-- @return function Inlines filter: a mention `Figure <number>` becomes a link to the figure
local function link_mentions(ids)
    local warned = {}
    return function(inlines)
        local result = pandoc.Inlines({})
        local i = 1
        while i <= #inlines do
            local word, separator, digits = inlines[i], inlines[i + 1], inlines[i + 2]
            -- `Figure`, after a punctuation if any: `(Figure`, not `Subfigure`
            local before, figure_word, number, after
            if word.t == "Str" then before, figure_word = word.text:match("^(.-)([Ff]igure)$") end
            if figure_word and not before:match("%w$") and separator and SEPARATORS[separator.t]
                and digits and digits.t == "Str" then
                number, after = plain_number(digits.text)
            end
            -- `Figure 2 of RFC 1234`: figure of another document
            local next_word = inlines[i + 4]
            if number and after == "" and inlines[i + 3] and inlines[i + 3].t == "Space"
                and next_word and next_word.t == "Str" and next_word.text == "of" then
                number = nil
            end
            if number and ids[number] == nil and not warned[number] then
                warned[number] = true
                pandoc.log.warn(("Figure %d mentioned in the text: no figure has this number"):format(number))
            end
            if number and ids[number] then
                if before ~= "" then result:insert(pandoc.Str(before)) end
                local text = digits.text:sub(1, #digits.text - #after)
                result:insert(pandoc.Link({ pandoc.Str(figure_word), pandoc.Space(), pandoc.Str(text) }, "#" .. ids[number]))
                if after ~= "" then result:insert(pandoc.Str(after)) end
                i = i + 3
            else
                result:insert(word)
                i = i + 1
            end
        end
        return result
    end
end

-- Stops the traversal in an element: its text is not linked
local function skip(element) return element, false end

-- Runs after Blocks: checks the final captions, in the order of the document, and links the mentions of figures
function Pandoc(doc)
    -- identifiers of headings (e.g. heading `Fig 1` is `fig-1`), divs and spans: not given to a figure
    local used = {}
    local function use(element) used[element.identifier] = true end
    doc:walk({ Header = use, Div = use, Span = use })
    local previous = 0
    local ids = {}
    doc = doc:walk({
        Figure = function(fig)
            local number = caption_number(fig.caption)
            if number == nil then return nil end
            if number ~= previous + 1 then
                local place = previous == 0 and "first numbered figure" or ("after Figure " .. previous)
                pandoc.log.warn(("Figure %d (%s): expected Figure %d, fix: lib/pandoc.rb renumber-figures")
                    :format(number, place, previous + 1))
            end
            -- continue from the number found: one mistake, one warning
            previous = number
            -- a duplicate number: mentions link to the first figure
            if ids[number] then return nil end
            if fig.identifier == "" then
                -- taken, e.g. by heading `Fig 1`: `fig-1-1`, as pandoc does for headings
                local id, suffix = "fig-" .. number, 0
                while used[id] do
                    suffix = suffix + 1
                    id = ("fig-%d-%d"):format(number, suffix)
                end
                fig.identifier = id
            end
            used[fig.identifier] = true
            ids[number] = fig.identifier
            return fig
        end,
    })
    return doc:walk({
        traverse = "topdown",
        Figure = skip,
        Header = skip,
        Link = skip,
        Image = skip,
        Inlines = link_mentions(ids),
    })
end
