-- QuickRSS: Article Cache
-- Persists the last-fetched article list to disk so the plugin opens
-- instantly without a network round-trip.
--
-- Public API:
--   Cache.loadArticles(max_age_days)    → light articles table (no content/full_text)
--   Cache.loadArticleBody(link)         → { content, full_text } for one article, or nil
--   Cache.saveArticles(articles)        persists articles + last_fetched_at timestamp
--   Cache.saveArticleStates(articles)   persists only read/saved flags (cheap, no content)
--   Cache.clearCache()                  wipes articles, timestamp, and all images/bodies
--   Cache.cleanOrphanedImages(articles) deletes cached images not in article list
--   Cache.cleanOrphanedBodies(articles) deletes body files not in article list
--
-- The article list handed around the UI (feed list, pagination, filters) is
-- kept "light": Cache.saveArticles() strips each article's `content` and
-- `full_text` HTML before saving and writes them instead to their own small
-- file under quickrss/bodies/ (one file per article, named by a hash of its
-- link). That keeps the in-memory article list -- and everything paginating
-- over it -- free of multi-KB-to-MB HTML strings; only Cache.loadArticleBody()
-- pulls a single article's body back in, on demand, when it's actually opened.
--
-- Read/saved toggles are even more frequent than that, so they go through
-- Cache.saveArticleStates() instead, which writes to a THIRD small file
-- (article_state.lua) containing just a link → {read, saved} table.
-- Cache.loadArticles() merges that back onto the stored light articles.
--
-- Each of these needs to be its own file, not just its own key in one
-- LuaSettings-backed file: LuaSettings:open() loads a whole file into one
-- in-memory table, and :flush() always re-serializes and rewrites that
-- entire table, no matter which key was just set. A second key in the same
-- file would still drag the full article content blob through every flush
-- (or, for bodies, through every single article's flush).

local DataStorage = require("datastorage")
local Images      = require("modules/data/images")
local lfs         = require("libs/libkoreader-lfs")
local LuaSettings = require("luasettings")
local logger      = require("logger")

local CACHE_FILE = DataStorage:getDataDir() .. "/quickrss/cache.lua"
local STATE_FILE = DataStorage:getDataDir() .. "/quickrss/article_state.lua"
local BODY_DIR   = DataStorage:getDataDir() .. "/quickrss/bodies"
local IMAGE_DIR  = Images.IMAGE_DIR

lfs.mkdir(BODY_DIR)  -- no-op if already exists

local _settings
local function settings()
    if not _settings then
        _settings = LuaSettings:open(CACHE_FILE)
    end
    return _settings
end

local _state_settings
local function stateSettings()
    if not _state_settings then
        _state_settings = LuaSettings:open(STATE_FILE)
    end
    return _state_settings
end

-- Non-cryptographic hash → stable 8-char hex filename, mirrors images.lua's
-- urlHash so each article's body file can be found from just its link.
local function bodyHash(link)
    local h = 5381
    for i = 1, #link do
        h = ((h * 33) + link:byte(i)) % 0x100000000
    end
    return string.format("%08x", h)
end

local function bodyFileName(link)
    return bodyHash(link) .. ".lua"
end

local function bodyFilePath(link)
    return BODY_DIR .. "/" .. bodyFileName(link)
end

local Cache = {}

-- Reads one article's { content, full_text } from its own small file.
-- Returns nil if the article has no link or no body was ever saved for it.
-- This is the only entry point that touches an individual article's HTML,
-- and it never loads any other article's body into memory.
function Cache.loadArticleBody(link)
    if not link or link == "" then return nil end
    local path = bodyFilePath(link)
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local s = LuaSettings:open(path)
    return {
        content   = s:readSetting("content"),
        full_text = s:readSetting("full_text"),
    }
end

-- Writes one article's body to its own file. Called only from
-- Cache.saveArticles(), never on the per-toggle hot path.
local function saveArticleBody(link, content, full_text)
    if not link or link == "" then return end
    LuaSettings:open(bodyFilePath(link))
        :saveSetting("content", content)
        :saveSetting("full_text", full_text)
        :flush()
end

-- Returns the HTML to scan for inline <img> references for one article:
-- whatever is already in memory (e.g. right after a fetch, before
-- Cache.saveArticles() strips it), or lazily loaded from its body file
-- otherwise (e.g. when called with the light in-memory article list).
local function articleContentForScan(art)
    if art.content then return art.content end
    if art.link and art.link ~= "" then
        local body = Cache.loadArticleBody(art.link)
        return body and body.content
    end
    return nil
end

-- Removes body files under BODY_DIR whose article is no longer in `articles`.
-- Mirrors Cache.cleanOrphanedImages(); called from Cache.saveArticles() so
-- deleted/dismissed articles don't leave their body files behind forever.
function Cache.cleanOrphanedBodies(articles)
    local keep = {}
    for _, art in ipairs(articles) do
        if art.link and art.link ~= "" then
            keep[bodyFileName(art.link)] = true
        end
    end

    local ok = lfs.attributes(BODY_DIR, "mode") == "directory"
    if not ok then return end
    for fname in lfs.dir(BODY_DIR) do
        if fname ~= "." and fname ~= ".." and not keep[fname] then
            local path = BODY_DIR .. "/" .. fname
            local removed, err = os.remove(path)
            if not removed then
                logger.warn("QuickRSS: could not remove orphan body:", path, err)
            end
        end
    end
end

-- Returns the cached article list, filtering out articles older than
-- max_age_days on a per-article basis.  Pass 0 or nil to skip age filtering.
function Cache.loadArticles(max_age_days)
    local all = settings():readSetting("articles") or {}

    -- Overlay read/saved flags from the lightweight state file: toggles
    -- made since the last full save only land there, not in "articles".
    local state = stateSettings():readSetting("state")
    if state and next(state) then
        for _, art in ipairs(all) do
            local st = art.link and state[art.link]
            if st then
                if st.read  ~= nil then art.read  = st.read  end
                if st.saved ~= nil then art.saved = st.saved end
            end
        end
    end

    if not max_age_days or max_age_days <= 0 then return all end

    local cutoff = os.time() - max_age_days * 86400
    local fresh  = {}
    for _, art in ipairs(all) do
        if art.saved or (art.fetched_at or 0) >= cutoff then
            table.insert(fresh, art)
        end
    end
    return fresh
end

-- Persists articles to disk.  Stamps any article that lacks a fetched_at
-- timestamp with the current time (new articles from this fetch cycle).
--
-- Any article carrying `content`/`full_text` (e.g. straight out of a fetch)
-- gets that body written to its own file under BODY_DIR, then stripped from
-- the record that's saved to cache.lua and kept in memory. Articles that
-- already came from the light in-memory list (no content/full_text set)
-- pass through untouched -- their existing body file, if any, is left alone.
function Cache.saveArticles(articles)
    local now = os.time()
    for _, art in ipairs(articles) do
        if not art.fetched_at then
            art.fetched_at = now
        end
        if art.link and art.link ~= "" and (art.content or art.full_text) then
            saveArticleBody(art.link, art.content, art.full_text)
        end
        art.content   = nil
        art.full_text = nil
    end
    Cache.cleanOrphanedBodies(articles)
    settings()
        :saveSetting("articles", articles)
        :flush()
    -- The read/saved flags on `articles` are authoritative at this point
    -- (callers always pass the current in-memory list), so the lightweight
    -- state file is redundant until the next toggle. Clear it rather than
    -- let it accumulate stale entries for articles that no longer exist.
    -- This is a tiny separate file, so flushing it here is cheap.
    stateSettings():saveSetting("state", nil):flush()
end

-- Persists only the read/saved flags, keyed by article link, to their own
-- small file -- never touching cache.lua (and thus never re-serializing the
-- full article content blob). Safe to call on every single read/save toggle.
function Cache.saveArticleStates(articles)
    local state = {}
    for _, art in ipairs(articles) do
        if art.link and art.link ~= "" then
            state[art.link] = { read = art.read or nil, saved = art.saved or nil }
        end
    end
    stateSettings()
        :saveSetting("state", state)
        :flush()
end

-- Wipes the article cache and all cached images, preserving saved articles.
-- After this call loadArticles() returns only saved articles until the next fetch.
function Cache.clearCache()
    local all = settings():readSetting("articles") or {}
    local saved = {}
    for _, art in ipairs(all) do
        if art.saved then
            table.insert(saved, art)
        end
    end

    settings()
        :saveSetting("articles", #saved > 0 and saved or nil)
        :saveSetting("dismissed", nil)
        :flush()
    stateSettings():saveSetting("state", nil):flush()
    -- Reset the in-memory handles so the next load re-reads from disk cleanly
    _settings = nil
    _state_settings = nil

    -- Bodies aren't kept in memory on the light `saved` records loaded above,
    -- so prune BODY_DIR down to just the saved articles' own files here.
    Cache.cleanOrphanedBodies(saved)

    -- Build set of image files still needed by saved articles
    local keep = {}
    for _, art in ipairs(saved) do
        if art.image_path then
            local fname = art.image_path:match("([^/]+)$")
            if fname then keep[fname] = true end
        end
        local content = articleContentForScan(art)
        if content then
            for fname in content:gmatch('[Ss][Rr][Cc]%s*=%s*"([^"/]+)"') do
                keep[fname] = true
            end
            for fname in content:gmatch("[Ss][Rr][Cc]%s*=%s*'([^'/]+)'") do
                keep[fname] = true
            end
        end
    end

    local ok = lfs.attributes(IMAGE_DIR, "mode") == "directory"
    if not ok then return saved end
    for fname in lfs.dir(IMAGE_DIR) do
        if fname ~= "." and fname ~= ".." and not keep[fname] then
            local path = IMAGE_DIR .. "/" .. fname
            local removed, err = os.remove(path)
            if not removed then
                logger.warn("QuickRSS: could not remove cached image:", path, err)
            end
        end
    end
    return saved
end

-- Returns the set of dismissed article links (articles the user deleted after
-- reading).  These are excluded from future fetches so they don't reappear.
function Cache.loadDismissed()
    return settings():readSetting("dismissed") or {}
end

-- Persists the dismissed link set.
function Cache.saveDismissed(dismissed)
    settings()
        :saveSetting("dismissed", dismissed)
        :flush()
end

-- Deletes image files in IMAGE_DIR that are not referenced by any article.
-- Called after every fetch so the image cache doesn't grow unboundedly.
function Cache.cleanOrphanedImages(articles)
    -- Build a set of filenames still in use (thumbnails + inline images)
    local live = {}
    for _, art in ipairs(articles) do
        if art.image_path then
            local fname = art.image_path:match("([^/]+)$")
            if fname then live[fname] = true end
        end
        -- Inline images already localized into content HTML. `articles` is
        -- often the light in-memory list (no `content` field), so fall back
        -- to that article's own body file.
        local content = articleContentForScan(art)
        if content then
            for fname in content:gmatch('[Ss][Rr][Cc]%s*=%s*"([^"/]+)"') do
                live[fname] = true
            end
            for fname in content:gmatch("[Ss][Rr][Cc]%s*=%s*'([^'/]+)'") do
                live[fname] = true
            end
        end
    end

    -- Walk IMAGE_DIR and remove anything not in the live set
    local ok = lfs.attributes(IMAGE_DIR, "mode") == "directory"
    if not ok then return end

    for fname in lfs.dir(IMAGE_DIR) do
        if fname ~= "." and fname ~= ".." and not live[fname] then
            local path = IMAGE_DIR .. "/" .. fname
            local removed, err = os.remove(path)
            if removed then
                logger.dbg("QuickRSS: removed orphan image:", fname)
            else
                logger.warn("QuickRSS: could not remove orphan image:", path, err)
            end
        end
    end
end

return Cache
