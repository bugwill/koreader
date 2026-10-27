local CacheItem = require("cacheitem")
local CanvasContext = require("document/canvascontext")
local DocCache = require("document/doccache")
local DocSettings = require("docsettings")
local Document = require("document/document")
local DrawContext = require("ffi/drawcontext")
local Blitbuffer = require("ffi/blitbuffer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local ffi = require("ffi")
local C = ffi.C
local pdf = nil

local PdfDocument = Document:extend{
    _document = false,
    is_pdf = true,
    dc_null = DrawContext.new(),
    koptinterface = nil,
    -- Annotations deleted since the file was last rewritten as a whole.
    deleted_annotations = 0,
    provider = "mupdf",
    provider_name = "MuPDF",
}

function PdfDocument:init()
    if not pdf then pdf = require("ffi/mupdf") end
    self.koptinterface = require("document/koptinterface")
    self.koptinterface:setDefaultConfigurable(self.configurable)
    local ok
    ok, self._document = pcall(pdf.openDocument, self.file)
    if not ok then
        error(self._document)  -- will contain error message
    end
    self:updateColorRendering()
    self.is_reflowable = self._document:isDocumentReflowable()
    self.reflowable_font_size = self:convertKoptToReflowableFontSize()
    -- no-op on PDF
    self:layoutDocument()
    self.is_open = true
    self.info.has_pages = true
    self.info.configurable = true
    self.render_mode = 0
    if self._document:needsPassword() then
        self.is_locked = true
    else
        self:_readMetadata()
    end
end

function PdfDocument:updateColorRendering()
    Document.updateColorRendering(self) -- will set self.render_color
    if self._document then
        self._document:setColorRendering(self.render_color)
    end
end

function PdfDocument:layoutDocument(font_size)
    if font_size then
        self.reflowable_font_size = font_size
    end
    self._document:layoutDocument(
        CanvasContext:getWidth(),
        CanvasContext:getHeight(),
        CanvasContext:scaleBySize(self.reflowable_font_size))
end

local default_font_size = 22
-- the koptreader config goes from 0.1 to 3.0, but we want a regular font size
function PdfDocument:convertKoptToReflowableFontSize(font_size)
    if font_size then
        return font_size * default_font_size
    end

    local size
    if DocSettings:hasSidecarFile(self.file) then
        local doc_settings = DocSettings:open(self.file)
        size = doc_settings:readSetting("kopt_font_size")
    end
    if size then
        return size * default_font_size
    elseif G_reader_settings:readSetting("kopt_font_size") then
        return G_reader_settings:readSetting("kopt_font_size") * default_font_size
    elseif G_defaults:readSetting("DKOPTREADER_CONFIG_FONT_SIZE") then
        return G_defaults:readSetting("DKOPTREADER_CONFIG_FONT_SIZE") * default_font_size
    else
        return default_font_size
    end
end

function PdfDocument:unlock(password)
    if not self._document:authenticatePassword(password) then
        return false
    end
    self.is_locked = false
    self:_readMetadata()
    return true
end

function PdfDocument:comparePositions(pos1, pos2)
    return self.koptinterface:comparePositions(self, pos1, pos2)
end

function PdfDocument:getPageTextBoxes(pageno)
    local hash = "textbox|"..self.file.."|"..pageno
    local cached = DocCache:check(hash)
    if not cached then
        local page = self._document:openPage(pageno)
        local text = page:getPageText()
        page:close()
        DocCache:insert(hash, CacheItem:new{text=text, size=text.size})
        return text
    else
        return cached.text
    end
end

function PdfDocument:getPanelFromPage(pageno, pos)
    return self.koptinterface:getPanelFromPage(self, pageno, pos)
end

function PdfDocument:getWordFromPosition(spos)
    return self.koptinterface:getWordFromPosition(self, spos)
end

function PdfDocument:getTextFromPositions(spos0, spos1)
    return self.koptinterface:getTextFromPositions(self, spos0, spos1)
end

function PdfDocument:getTextBoxes(pageno)
    return self.koptinterface:getTextBoxes(self, pageno)
end

function PdfDocument:getPageBoxesFromPositions(pageno, ppos0, ppos1)
    return self.koptinterface:getPageBoxesFromPositions(self, pageno, ppos0, ppos1)
end

function PdfDocument:nativeToPageRectTransform(pageno, rect)
    return self.koptinterface:nativeToPageRectTransform(self, pageno, rect)
end

function PdfDocument:getSelectedWordContext(word, nb_words, pos)
    return self.koptinterface:getSelectedWordContext(word, nb_words, pos)
end

function PdfDocument:getOCRWord(pageno, wbox)
    return self.koptinterface:getOCRWord(self, pageno, wbox)
end

function PdfDocument:getOCRText(pageno, tboxes)
    return self.koptinterface:getOCRText(self, pageno, tboxes)
end

function PdfDocument:getPageBlock(pageno, x, y)
    return self.koptinterface:getPageBlock(self, pageno, x, y)
end

function PdfDocument:getUsedBBox(pageno)
    local hash = "pgubbox|"..self.file.."|"..self.reflowable_font_size.."|"..pageno
    local cached = DocCache:check(hash)
    if cached then
        return cached.ubbox
    end
    local page = self._document:openPage(pageno)
    local used = {}
    used.x0, used.y0, used.x1, used.y1 = page:getUsedBBox()
    local pwidth, pheight = page:getSize(self.dc_null)
    -- clamp to page BBox
    if used.x0 < 0 then used.x0 = 0 end
    if used.x1 > pwidth then used.x1 = pwidth end
    if used.y0 < 0 then used.y0 = 0 end
    if used.y1 > pheight then used.y1 = pheight end
    DocCache:insert(hash, CacheItem:new{
        ubbox = used,
        size = 256, -- might be closer to 160
    })
    page:close()
    return used
end

function PdfDocument:getPageLinks(pageno)
    local hash = "pglinks|"..self.file.."|"..self.reflowable_font_size.."|"..pageno
    local cached = DocCache:check(hash)
    if cached then
        return cached.links
    end
    local page = self._document:openPage(pageno)
    local links = page:getPageLinks()
    DocCache:insert(hash, CacheItem:new{
        links = links,
        size = 64 + (8 * 32 * #links),
    })
    page:close()
    return links
end

-- returns nil if file is not a pdf, true if document is a writable pdf, false else
function PdfDocument:_checkIfWritable()
    local suffix = util.getFileNameSuffix(self.file)
    if string.lower(suffix) ~= "pdf" then return nil end
    if self.is_writable == nil then
        local handle = io.open(self.file, 'r+b')
        self.is_writable = handle ~= nil
        if handle then handle:close() end
    end
    return self.is_writable
end

local function _quadpointsFromPboxes(pboxes)
    -- will also need mupdf_h.lua to be evaluated once
    -- but this is guaranteed at this point
    local n = #pboxes
    local quadpoints = ffi.new("fz_quad[?]", n)
    for i=1, n do
        -- The order must be left bottom, right bottom, left top, right top.
        -- https://bugs.ghostscript.com/show_bug.cgi?id=695130
        quadpoints[i-1].ll.x = pboxes[i].x
        quadpoints[i-1].ll.y = pboxes[i].y + pboxes[i].h - 1
        quadpoints[i-1].lr.x = pboxes[i].x + pboxes[i].w - 1
        quadpoints[i-1].lr.y = pboxes[i].y + pboxes[i].h - 1
        quadpoints[i-1].ul.x = pboxes[i].x
        quadpoints[i-1].ul.y = pboxes[i].y
        quadpoints[i-1].ur.x = pboxes[i].x + pboxes[i].w - 1
        quadpoints[i-1].ur.y = pboxes[i].y
    end
    return quadpoints, n
end

local function _quadpointsToPboxes(quadpoints, n)
    -- reverse of previous function
    local pboxes = {}
    for i=1, n do
        table.insert(pboxes, {
            x = quadpoints[i-1].ul.x,
            y = quadpoints[i-1].ul.y,
            w = quadpoints[i-1].lr.x - quadpoints[i-1].ul.x + 1,
            h = quadpoints[i-1].lr.y - quadpoints[i-1].ul.y + 1,
        })
    end
    return pboxes
end

function PdfDocument:saveHighlight(pageno, item, annot_color)
    local can_write = self:_checkIfWritable()
    if can_write ~= true then return can_write end

    self.is_edited = true
    local quadpoints, n = _quadpointsFromPboxes(item.pboxes)
    local page = self._document:openPage(pageno)
    local annot_type = C.PDF_ANNOT_HIGHLIGHT
    if item.drawer == "lighten" then
        annot_type = C.PDF_ANNOT_HIGHLIGHT
    elseif item.drawer == "underscore" then
        annot_type = C.PDF_ANNOT_UNDERLINE
    elseif item.drawer == "strikeout" then
        annot_type = C.PDF_ANNOT_STRIKE_OUT
    end
    -- NOTE: For highlights, display style may differ compared to ReaderView:drawHighlightRect...
    --       (e.g., we do a MUL blend, MuPDF currently appears to do an OVER blend).
    page:addMarkupAnnotation(quadpoints, n, annot_type, annot_color) -- may update/adjust quadpoints
    -- Update pboxes with the possibly adjusted coordinates (this will have it updated
    -- in self.view.highlight.saved[page])
    item.pboxes = _quadpointsToPboxes(quadpoints, n)
    page:close()
    self:resetTileCacheValidity()
end

function PdfDocument:deleteHighlight(pageno, item)
    local can_write = self:_checkIfWritable()
    if can_write ~= true then return can_write end

    self.is_edited = true
    local quadpoints, n = _quadpointsFromPboxes(item.pboxes)
    local page = self._document:openPage(pageno)
    local annot = page:getMarkupAnnotation(quadpoints, n)
    if annot ~= nil then
        page:deleteAnnotation(annot)
        self.deleted_annotations = self.deleted_annotations + 1
        self:resetTileCacheValidity()
    end
    page:close()
end

function PdfDocument:updateHighlightContents(pageno, item, contents, annot_color)
    local can_write = self:_checkIfWritable()
    if can_write ~= true then return can_write end

    local quadpoints, n = _quadpointsFromPboxes(item.pboxes)
    local page = self._document:openPage(pageno)
    local annot = page:getMarkupAnnotation(quadpoints, n)
    if annot == nil then
        -- The highlight may be missing (or its coordinates may have been rounded
        -- by another PDF implementation). Preserve the note by creating the
        -- corresponding markup annotation before setting its contents.
        logger.warn("PDF highlight not found while saving its note; creating annotation")
        local annot_type = C.PDF_ANNOT_HIGHLIGHT
        if item.drawer == "underscore" then
            annot_type = C.PDF_ANNOT_UNDERLINE
        elseif item.drawer == "strikeout" then
            annot_type = C.PDF_ANNOT_STRIKE_OUT
        end
        page:addMarkupAnnotation(quadpoints, n, annot_type, annot_color)
        item.pboxes = _quadpointsToPboxes(quadpoints, n)
        annot = page:getMarkupAnnotation(quadpoints, n)
    end
    if annot ~= nil then
        page:updateMarkupAnnotation(annot, contents)
        self.is_edited = true
        self:resetTileCacheValidity()
    else
        logger.err("Could not find or create PDF highlight annotation for note")
    end
    page:close()
    return annot ~= nil
end

local STYLUS_ANNOTATION_PREFIX = "KOReaderStylus:"

local function isFiniteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function getStylusColor(stroke, highlight)
    local color = stroke.color
    if type(color) ~= "string" then return end
    color = color:lower()
    local bb_color
    if color == "black" then
        bb_color = Blitbuffer.colorFromString("#000000")
    elseif color == "white" then
        bb_color = Blitbuffer.colorFromString("#FFFFFF")
    elseif highlight and highlight.getHighlightColor then
        -- Match the plugin's palette, including custom PDF highlight colors.
        -- Like highlights, the PDF gets the day colors whatever the display
        -- mode: night mode inverts the rendered page, annotations included.
        bb_color = highlight:getHighlightColor(color)
    else
        local custom_colors = G_reader_settings:readSetting("highlight_custom_colors", {})
        local custom_color = custom_colors[color]
        local hex = custom_color and custom_color.code or Blitbuffer.HIGHLIGHT_COLORS[color]
        if color == "gray" then
            bb_color = Blitbuffer.gray(G_reader_settings:readSetting("highlight_lighten_factor") or 0.2)
        elseif color:match("^#%x%x%x%x%x%x$") or color:match("^#%x%x%x%x%x%x%x%x$") then
            bb_color = Blitbuffer.colorFromString(color)
        elseif hex then
            bb_color = Blitbuffer.colorFromString(hex)
        end
    end
    if not bb_color then return end
    local rgb = bb_color:getColorRGB32()
    return { r = rgb.r, g = rgb.g, b = rgb.b }
end

-- Stroke annotation names hash the text of the stroke's values with
-- h = (h * 33 + byte) % HASH_MOD, starting from 5381. All the strokes of a book
-- are hashed every time it is opened, so hash the values that both names below
-- share once. The hash is linear: hashing a string s from the state h gives
-- h * 33^#s + (hash of s from 0), modulo HASH_MOD.
local HASH_MOD = 2147483647

local function hashString(h, s)
    local byte = string.byte
    for i = 1, #s do
        h = (h * 33 + byte(s, i)) % HASH_MOD
    end
    return h
end

-- a * b % HASH_MOD, for a and b below HASH_MOD, exact with doubles (< 2^53).
local function mulMod(a, b)
    local hi, lo = math.floor(b / 65536), b % 65536
    return ((a * hi) % HASH_MOD * 65536 + a * lo) % HASH_MOD
end

local function powMod33(n)
    local result, base = 1, 33
    while n > 0 do
        if n % 2 == 1 then result = mulMod(result, base) end
        base = mulMod(base, base)
        n = math.floor(n / 2)
    end
    return result
end

-- Names for a stroke annotation: a compact deterministic name lets repeated
-- writes keep unchanged annotations and remove only the strokes erased in the
-- plugin. It must depend on nothing but the stroke itself: anything else that
-- changes (e.g. its position among the page's strokes, or the display mode)
-- renames, so deletes and re-adds, strokes that did not change.
-- Earlier versions also hashed the stroke's position (index) among the valid
-- strokes of its page, after its page number. Annotations already written with
-- such a legacy name are kept as they are: renaming them all would delete and
-- re-add every stroke of the book at once.
local function hashStylusAnnotation(pageno, stroke, points, color, width, opacity)
    local parts = {
        tostring(width), tostring(opacity), tostring(stroke.color or ""),
        tostring(color.r), tostring(color.g), tostring(color.b),
    }
    for _, point in ipairs(points) do
        parts[#parts + 1] = tostring(point.x)
        parts[#parts + 1] = tostring(point.y)
    end
    local rest = table.concat(parts)
    return {
        page_hash = hashString(5381, tostring(pageno)),
        rest_hash = hashString(0, rest),
        rest_pow = powMod33(#rest),
    }
end

local function finishStylusAnnotationHash(hash, h)
    return math.floor((mulMod(h, hash.rest_pow) + hash.rest_hash) % HASH_MOD)
end

local function makeStylusAnnotationName(pageno, hash)
    return STYLUS_ANNOTATION_PREFIX .. pageno .. ":" .. finishStylusAnnotationHash(hash, hash.page_hash)
end

local function makeLegacyStylusAnnotationName(pageno, index, hash)
    return STYLUS_ANNOTATION_PREFIX .. pageno .. ":" .. index .. ":"
        .. finishStylusAnnotationHash(hash, hashString(hash.page_hash, tostring(index)))
end

-- The colors of a sync are memoized by color name (false without one).
local function getMemoizedStylusColor(colors, stroke, highlight)
    local key = stroke.color or false
    local color = colors[key]
    if color == nil then
        color = getStylusColor(stroke, highlight) or false
        colors[key] = color
    end
    return color
end

-- Validate and convert a stroke into what its annotation needs, or nil.
local function prepareStylusAnnotation(stroke, page_count, highlight, colors)
    local pageno = tonumber(stroke.page)
    local coords = stroke.points
    if not (isFiniteNumber(pageno) and pageno == math.floor(pageno)
        and pageno >= 1 and pageno <= page_count
        and type(coords) == "table" and #coords >= 2 and #coords % 2 == 0) then
        return
    end
    local points = {}
    for i = 1, #coords, 2 do
        local x, y = coords[i], coords[i + 1]
        if not isFiniteNumber(x) or not isFiniteNumber(y) then return end
        -- The plugin persists coordinates at quarter-point precision.
        -- Export the same coordinates so the PDF and plugin sidecar stay aligned.
        points[#points + 1] = {
            x = math.floor(x * 4 + 0.5) / 4,
            y = math.floor(y * 4 + 0.5) / 4,
        }
    end
    local color = getMemoizedStylusColor(colors, stroke, highlight)
    local width = tonumber(stroke.width) or 1
    local opacity = tonumber(stroke.alpha) or 1
    if not (color and isFiniteNumber(width) and width > 0 and isFiniteNumber(opacity)) then
        return
    end
    opacity = math.max(0, math.min(1, opacity))
    local annotation = {
        page = pageno,
        points = points,
        color = color,
        width = width,
        opacity = opacity,
    }
    annotation.hash = hashStylusAnnotation(pageno, stroke, points, color, width, opacity)
    annotation.name = makeStylusAnnotationName(pageno, annotation.hash)
    return annotation
end

-- Formatting and hashing the points of every stroke of a book takes a while,
-- and strokes are synced on every trip to the background: reuse the
-- annotation prepared for a stroke while what it depends on stays the same.
local function isCachedStylusAnnotationValid(cached, stroke, color)
    return cached.stroke_points == stroke.points and cached.point_count == #stroke.points
        and cached.stroke_page == stroke.page and cached.stroke_color == stroke.color
        and cached.stroke_width == stroke.width and cached.stroke_alpha == stroke.alpha
        -- e.g. custom highlight colors may change
        and color and cached.color.r == color.r and cached.color.g == color.g
        and cached.color.b == color.b
end

function PdfDocument:_prepareStylusAnnotations(strokes, highlight)
    local page_count = self.info.number_of_pages
    local cache = self._stylus_annotation_cache
    if not cache then
        cache = setmetatable({}, { __mode = "k" })
        self._stylus_annotation_cache = cache
    end
    local colors = {}
    local desired = {}
    local legacy_names = {} -- per page, legacy name -> name
    local page_indexes = {}
    local count = 0
    for _, stroke in ipairs(strokes or {}) do
        local annotation = cache[stroke]
        if annotation then
            local color = getMemoizedStylusColor(colors, stroke, highlight)
            if not isCachedStylusAnnotationValid(annotation, stroke, color) then
                annotation = nil
            end
        end
        if not annotation then
            annotation = prepareStylusAnnotation(stroke, page_count, highlight, colors)
            if annotation then
                annotation.stroke_points = stroke.points
                annotation.point_count = #stroke.points
                annotation.stroke_page = stroke.page
                annotation.stroke_color = stroke.color
                annotation.stroke_width = stroke.width
                annotation.stroke_alpha = stroke.alpha
                cache[stroke] = annotation
            end
        end
        if annotation then
            local pageno = annotation.page
            local index = (page_indexes[pageno] or 0) + 1
            page_indexes[pageno] = index
            if annotation.legacy_index ~= index then
                annotation.legacy_index = index
                annotation.legacy_name = makeLegacyStylusAnnotationName(pageno, index, annotation.hash)
            end
            desired[pageno] = desired[pageno] or {}
            legacy_names[pageno] = legacy_names[pageno] or {}
            -- Identical strokes on a page (or a hash collision) get a
            -- numbered name, in stroke order.
            local name, n = annotation.name, 1
            while desired[pageno][name] do
                n = n + 1
                name = annotation.name .. ":" .. n
            end
            desired[pageno][name] = annotation
            legacy_names[pageno][annotation.legacy_name] = name
            count = count + 1
        end
    end
    return desired, legacy_names, count
end

-- Which stylus annotations of a page to keep and which to delete, given the
-- names of those it holds: one per wanted stroke, under its name or its legacy
-- name. Returns the set of wanted names present, the list of the indexes of
-- the annotations to delete, and whether some wanted names are missing.
local function diffStylusAnnotations(names, page_desired, page_legacy_names)
    local present, delete = {}, {}
    for i, name in ipairs(names) do
        if not page_desired[name] then
            name = page_legacy_names[name]
        end
        if name and not present[name] then
            present[name] = true
        else
            delete[#delete + 1] = i
        end
    end
    local missing = false
    for name in pairs(page_desired) do
        if not present[name] then
            missing = true
            break
        end
    end
    return present, delete, missing
end

function PdfDocument:syncStylusAnnotations(strokes, highlight)
    local can_write = self:_checkIfWritable()
    if can_write ~= true then return can_write end

    local desired, legacy_names, count = self:_prepareStylusAnnotations(strokes, highlight)
    -- Names of the stylus annotations of each page, as left by the previous
    -- sync: only this sync changes them, so pages whose names already match
    -- the strokes need not be opened.
    local page_names = self._stylus_annotation_names
    if not page_names then
        page_names = {}
        self._stylus_annotation_names = page_names
    end
    local changed = false
    for pageno = 1, self.info.number_of_pages do
        local page_desired = desired[pageno] or {}
        local page_legacy_names = legacy_names[pageno] or {}
        local up_to_date = false
        if page_names[pageno] then
            local _, delete, missing = diffStylusAnnotations(page_names[pageno], page_desired, page_legacy_names)
            up_to_date = #delete == 0 and not missing
        end
        if not up_to_date then
            local page = self._document:openPage(pageno)
            local ok, err = pcall(function()
                local existing = page:getInkAnnotationsWithNamePrefix(STYLUS_ANNOTATION_PREFIX)
                local names = {}
                for i, annotation in ipairs(existing) do
                    names[i] = annotation.name
                end
                local present, delete, missing = diffStylusAnnotations(names, page_desired, page_legacy_names)
                local deleted = {}
                for _, i in ipairs(delete) do
                    page:deleteAnnotation(existing[i].annot)
                    deleted[i] = true
                    self.deleted_annotations = self.deleted_annotations + 1
                    changed = true
                end
                local kept = {}
                for i, name in ipairs(names) do
                    if not deleted[i] then kept[#kept + 1] = name end
                end
                if missing then
                    for name, annotation in pairs(page_desired) do
                        if not present[name] then
                            page:addInkAnnotation(
                                { annotation.points }, annotation.color, annotation.width,
                                annotation.opacity, name)
                            kept[#kept + 1] = name
                            changed = true
                        end
                    end
                end
                page_names[pageno] = kept
            end)
            page:close()
            if not ok then
                page_names[pageno] = nil
                error(err)
            end
        end
    end

    if changed then
        self.is_edited = true
        self:resetTileCacheValidity()
    end
    return true, count
end

--[[--
Read the ink annotations of all pages, so a stylus plugin can import them.

Returns a list of `{ page, name, strokes, color, width, opacity, is_stylus }`,
see mupdf page:getInkAnnotations(); `is_stylus` marks the copies written by
syncStylusAnnotations().
--]]
function PdfDocument:getInkAnnotations()
    local result = {}
    for pageno = 1, self.info.number_of_pages do
        local page = self._document:openPage(pageno)
        local ok, err = pcall(function()
            for _, annotation in ipairs(page:getInkAnnotations()) do
                annotation.annot = nil
                annotation.page = pageno
                annotation.is_stylus = annotation.name ~= nil
                    and annotation.name:sub(1, #STYLUS_ANNOTATION_PREFIX) == STYLUS_ANNOTATION_PREFIX
                result[#result + 1] = annotation
            end
        end)
        page:close()
        if not ok then error(err) end
    end
    return result
end

--[[--
Delete ink annotations not written by syncStylusAnnotations(), after a stylus
plugin imported them: the next sync writes them back as its own copies, so
they can then be erased like any other stroke.
--]]
function PdfDocument:deleteForeignInkAnnotations()
    local can_write = self:_checkIfWritable()
    if can_write ~= true then return can_write end
    local deleted = 0
    for pageno = 1, self.info.number_of_pages do
        local page = self._document:openPage(pageno)
        local ok, err = pcall(function()
            for _, annotation in ipairs(page:getInkAnnotations()) do
                local name = annotation.name
                if not (name and name:sub(1, #STYLUS_ANNOTATION_PREFIX) == STYLUS_ANNOTATION_PREFIX) then
                    page:deleteAnnotation(annotation.annot)
                    self.deleted_annotations = self.deleted_annotations + 1
                    deleted = deleted + 1
                end
            end
        end)
        page:close()
        if not ok then error(err) end
    end
    if deleted > 0 then
        self.is_edited = true
        self:resetTileCacheValidity()
    end
    return true, deleted
end

function PdfDocument:getEmbeddedAnnotations()
    local annotations = {}
    for pageno = 1, self.info.number_of_pages do
        local page = self._document:openPage(pageno)
        local page_annots = page:getEmbeddedAnnotations()
        if page_annots then
            annotations[pageno] = page_annots
        end
        page:close()
    end
    return next(annotations) and annotations
end

-- An incremental update is appended to the file and never removed: whatever it
-- replaces or deletes (edited objects, deleted annotations) stays in the file
-- as garbage, and only rewriting the whole file removes it. The file is
-- rewritten once it holds this many versions (the original plus one
-- incremental update per session that saved it): an incremental save first
-- reads the whole file back, which then takes longer than rewriting it
-- (measured on a 163 MB PDF with 124 versions: 7.6 s versus 4.1 s)...
local MAX_PDF_VERSIONS = 8
-- ... or, when closing the document, after deleting this many annotations
-- (e.g. after erasing many strokes). Saves are frequent (e.g. on every trip to
-- the background) and incremental ones stay cheap (0.3 s on a 50 MB PDF).
local MAX_DELETED_ANNOTATIONS = 50

-- Packing objects into object streams halves the size of a heavily annotated
-- PDF, but holds them all in memory while writing, which gets slow with a
-- file bloated by many incremental updates: 3.7 s for a 51 MB PDF, 32 s for
-- a 163 MB one with 124 versions (4.1 s without object streams), on an
-- Android e-reader. Above this size, the copy goes without them; it is small
-- enough to get them the next time it is rewritten.
local MAX_PDF_SIZE_FOR_OBJECT_STREAMS = 64 * 1024 * 1024

local function useObjectStreams(file)
    local size = lfs.attributes(file, "size")
    return size ~= nil and size <= MAX_PDF_SIZE_FOR_OBJECT_STREAMS
end

-- Write a complete copy of the document next to the original, without the
-- objects nothing refers to anymore, then atomically replace the original with
-- it. MuPDF keeps reading the opened document through its existing file handle,
-- which still refers to the replaced file.
function PdfDocument:_writeDocumentFull()
    local tmp_file = self.file .. ".koreader-tmp"
    os.remove(tmp_file)
    -- A different target path makes MuPDF write a full (non-incremental),
    -- garbage-collected PDF.
    local ok, err = pcall(self._document.writeDocument, self._document, tmp_file,
        not useObjectStreams(self.file))
    if not ok then
        os.remove(tmp_file)
        error(err, 0)
    end
    local renamed, rename_err = os.rename(tmp_file, self.file)
    if not renamed then
        os.remove(tmp_file)
        error("could not replace " .. self.file .. ": " .. tostring(rename_err), 0)
    end
end

function PdfDocument:_countVersions()
    local ok, versions = pcall(self._document.countVersions, self._document)
    if not ok then
        logger.warn("could not count PDF versions:", versions)
        return 1
    end
    return versions
end

-- Whether the file holds enough garbage to be rewritten as a whole.
function PdfDocument:_needsCompaction(closing)
    return self:_countVersions() >= MAX_PDF_VERSIONS
        or closing and self.deleted_annotations >= MAX_DELETED_ANNOTATIONS
end

--[[--
Whether closing the document will rewrite the whole file, which can take a
while with big files.
--]]
function PdfDocument:willCompactOnClose()
    if self.has_written_full_document then
        return self.is_edited
    end
    return (self.is_edited or self.has_written_document) and self:_needsCompaction(true)
end

-- Every incremental save of an opened document rewrites the same update,
-- appended to the file as it was when opened, with all the changes made since
-- (see writeDocument in ffi/mupdf): it costs only the size of these changes.
function PdfDocument:writeDocument(closing)
    logger.info("writing document to", self.file)
    -- Once the file has been replaced by a complete copy, an update would be
    -- appended to the file as it was when opened, so MuPDF would first copy
    -- that whole old file, garbage included, back: keep rewriting it as a whole.
    local compact = self:_needsCompaction(closing)
    if compact then
        logger.info("rewriting the PDF without its garbage: versions", self:_countVersions(),
            "deleted annotations", self.deleted_annotations)
    end
    if not self.has_written_full_document and not compact then
        local ok, err = pcall(self._document.writeDocument, self._document, self.file)
        if ok then
            self.has_written_document = true
            self.is_edited = false
            return
        end
        -- e.g. repaired files cannot be written incrementally
        logger.warn("incremental PDF write failed, rewriting the whole document:", err)
    end
    self:_writeDocumentFull()
    self.has_written_document = true
    self.has_written_full_document = true
    self.deleted_annotations = 0
    self.is_edited = false
end

-- Write a copy of the PDF file, as it is on disk, with the colors of all pages inverted.
function PdfDocument:writeInvertedCopy(target_file)
    local doc = pdf.openDocument(self.file)
    local ok, err = pcall(function()
        if doc:needsPassword() then
            error("password protected PDFs are not supported", 0)
        end
        doc:invertColors()
        doc:writeDocument(target_file, not useObjectStreams(self.file))
    end)
    doc:close()
    if not ok then
        error(err, 0)
    end
end

function PdfDocument:close()
    -- NOTE: We can't just rely on Document:close's return code for that, as we need self._document
    --       in :writeDocument, and it would have been destroyed.
    local DocumentRegistry = require("document/documentregistry")
    if DocumentRegistry:getReferenceCount(self.file) == 1 then
        -- We're the final reference to this Document instance.
        -- Also rewrite a file saved earlier in this session if it needs it.
        if self.is_edited or (self.has_written_document
                and not self.has_written_full_document and self:_needsCompaction(true)) then
            self:writeDocument(true)
        end
    end

    Document.close(self)
end

function PdfDocument:getLinkFromPosition(pageno, pos)
    return self.koptinterface:getLinkFromPosition(self, pageno, pos)
end

function PdfDocument:clipPagePNGFile(pos0, pos1, pboxes, drawer, filename)
    return self.koptinterface:clipPagePNGFile(self, pos0, pos1, pboxes, drawer, filename)
end

function PdfDocument:clipPagePNGString(pos0, pos1, pboxes, drawer)
    return self.koptinterface:clipPagePNGString(self, pos0, pos1, pboxes, drawer)
end

function PdfDocument:getPageBBox(pageno)
    return self.koptinterface:getPageBBox(self, pageno)
end

function PdfDocument:getPageDimensions(pageno, zoom, rotation)
    return self.koptinterface:getPageDimensions(self, pageno, zoom, rotation)
end

function PdfDocument:getCoverPageImage()
    return self.koptinterface:getCoverPageImage(self)
end

function PdfDocument:findText(pattern, origin, reverse, case_insensitive, page)
    return self.koptinterface:findText(self, pattern, origin, reverse, case_insensitive, page)
end

function PdfDocument:findAllText(pattern, case_insensitive, nb_context_words, max_hits)
    return self.koptinterface:findAllText(self, pattern, case_insensitive, nb_context_words, max_hits)
end

function PdfDocument:renderPage(pageno, rect, zoom, rotation, gamma, saturation, hinting)
    return self.koptinterface:renderPage(self, pageno, rect, zoom, rotation, gamma, saturation, hinting)
end

function PdfDocument:hintPage(pageno, zoom, rotation, gamma, saturation)
    return self.koptinterface:hintPage(self, pageno, zoom, rotation, gamma, saturation)
end

function PdfDocument:drawPage(target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
    return self.koptinterface:drawPage(self, target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
end

function PdfDocument:register(registry)
    --- Document types ---
    registry:addProvider("cbr", "application/vnd.comicbook-rar", self, 100)
    registry:addProvider("cbr", "application/vnd.rar", self, 100)
    registry:addProvider("cbt", "application/vnd.comicbook+tar", self, 100)
    registry:addProvider("cbz", "application/vnd.comicbook+zip", self, 100)
    registry:addProvider("cbz", "application/x-cbz", self, 100) -- Alternative mimetype for OPDS.
    registry:addProvider("cfb", "application/octet-stream", self, 80) -- Compound File Binary, a Microsoft general-purpose file with a file-system-like structure.
    registry:addProvider("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", self, 80)
    registry:addProvider("epub", "application/epub+zip", self, 50)
    registry:addProvider("epub3", "application/epub+zip", self, 50)
    registry:addProvider("fb2", "application/fb2", self, 80)
    registry:addProvider("htm", "text/html", self, 90)
    registry:addProvider("html", "text/html", self, 90)
    registry:addProvider("mobi", "application/x-mobipocket-ebook", self, 80)
    registry:addProvider("pdf", "application/pdf", self, 100)
    registry:addProvider("pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation", self, 80)
    registry:addProvider("tar", "application/x-tar", self, 10)
    registry:addProvider("txt", "text/plain", self, 80)
    registry:addProvider("xhtml", "application/xhtml+xml", self, 90)
    registry:addProvider("xml", "application/xml", self, 10)
    registry:addProvider("xps", "application/oxps", self, 100)
    registry:addProvider("xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", self, 80)
    registry:addProvider("zip", "application/zip", self, 20)

    --- Picture types ---
    registry:addProvider("gif", "image/gif", self, 90)
    -- MS HD Photo == JPEG XR
    registry:addProvider("hdp", "image/vnd.ms-photo", self, 90)
    registry:addProvider("j2k", "image/jp2", self, 90)
    registry:addProvider("jp2", "image/jp2", self, 90)
    registry:addProvider("jpeg", "image/jpeg", self, 90)
    registry:addProvider("jpg", "image/jpeg", self, 90)
    -- JPEG XR
    registry:addProvider("jxr", "image/jxr", self, 90)
    registry:addProvider("pam", "image/x-portable-arbitrarymap", self, 90)
    registry:addProvider("pbm", "image/x‑portable‑bitmap", self, 90)
    registry:addProvider("pgm", "image/x‑portable‑bitmap", self, 90)
    registry:addProvider("png", "image/png", self, 90)
    registry:addProvider("pnm", "image/x‑portable‑bitmap", self, 90)
    registry:addProvider("ppm", "image/x‑portable‑bitmap", self, 90)
    registry:addProvider("svg", "image/svg+xml", self, 80)
    registry:addProvider("tif", "image/tiff", self, 90)
    registry:addProvider("tiff", "image/tiff", self, 90)
    -- Windows Media Photo == JPEG XR
    registry:addProvider("wdp", "image/vnd.ms-photo", self, 90)
end

return PdfDocument
