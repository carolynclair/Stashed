--[[
  Stashed - "Where's the rest of this item?"
  Account-wide item locations in your tooltips and a searchable window.

  Design notes (Retail and Forever):
  * Only touches item/container data, never combat data, so Secret Values
    are not a concern outside of a defensive guard on tooltip data.
  * Every scan of a bank-type container is validated against the free-slot
    count so a closed/unloaded bank can never wipe stored data.
  * Bag groups are discovered from Enum.BagIndex by name instead of
    hard-coded IDs, so renumbering between patches doesn't break scanning.
]]

local ADDON_NAME, ns = ...

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local db, opts
local bankOpen = false
local dirty = true
local index = {}          -- index[itemID][charKey] = { bags=, bank=, equipped=, mail= }
local groups              -- { bags = {ids}, bank = {ids}, warband = {ids} }

local LOCS = { "bags", "bank", "equipped", "mail" }
local LOC_LABEL = { bags = "Bags", bank = "Bank", equipped = "Worn", mail = "Mail" }

local DEFAULTS = {
    alwaysBreakdown = false, -- per-character lines without holding Shift
    alwaysShow      = false, -- show even when every copy is in this character's bags
    includeMail     = true,
    includeWarband  = true,
}

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------
local function Print(msg)
    print("|cff5ec8ffStashed|r: " .. tostring(msg))
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
    return nil
end

local function ItemName(id)
    local name
    if C_Item then
        if C_Item.GetItemNameByID then name = C_Item.GetItemNameByID(id) end
        if not name and C_Item.GetItemInfo then name = (C_Item.GetItemInfo(id)) end
    end
    if not name and _G.GetItemInfo then name = (_G.GetItemInfo(id)) end
    return name
end

local function ItemIcon(id)
    if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(id) end
    return 134400 -- question mark
end

local function ItemQuality(id)
    if C_Item and C_Item.GetItemQualityByID then return C_Item.GetItemQualityByID(id) end
    return 1
end

local function ItemLink(id)
    if C_Item and C_Item.GetItemInfo then
        local _, link = C_Item.GetItemInfo(id)
        return link
    end
end

local function RealmName()
    return (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName():gsub("%s", ""))
end

local function CharKey()
    return (UnitName("player") or "?") .. "-" .. RealmName()
end

local function ColoredName(key)
    local c = db.chars[key]
    local name = (c and c.name) or key
    if c and c.realm and c.realm ~= GetRealmName() then
        name = name .. "-" .. c.realm
    end
    local col = c and c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
    if col and col.WrapTextInColorCode then
        return col:WrapTextInColorCode(name)
    end
    return name
end

------------------------------------------------------------------------
-- Container groups (discovered from Enum.BagIndex by name)
------------------------------------------------------------------------
local function BuildGroups()
    local g = { bags = {}, bank = {}, warband = {} }
    local claimed = {}

    local function claim(group, id)
        if type(id) == "number" and not claimed[id] then
            claimed[id] = true
            g[group][#g[group] + 1] = id
        end
    end

    local E = Enum and Enum.BagIndex
    if E then
        -- Order matters: bags first so legacy bank IDs can't steal bag IDs.
        for name, id in pairs(E) do
            if name == "Backpack" or name:find("^Bag_%d") or name == "ReagentBag" then
                claim("bags", id)
            end
        end
        for name, id in pairs(E) do
            if name:find("^AccountBankTab") then claim("warband", id) end
        end
        for name, id in pairs(E) do
            if name:find("^CharacterBankTab") or name == "Bank" or name:find("^BankBag")
                or name == "Reagentbank" then
                claim("bank", id)
            end
        end
    end
    if #g.bags == 0 then
        for i = 0, 5 do g.bags[#g.bags + 1] = i end
    end
    for _, list in pairs(g) do table.sort(list) end
    return g
end

------------------------------------------------------------------------
-- Scanning
------------------------------------------------------------------------
-- Returns totals[itemID] = count, or nil if the data can't be trusted.
local function ScanGroup(ids, validate)
    if not ids or #ids == 0 then return nil end
    local totals, slotsTotal = {}, 0
    for _, bag in ipairs(ids) do
        local n = C_Container.GetContainerNumSlots(bag) or 0
        if n > 0 then
            slotsTotal = slotsTotal + n
            local seen = 0
            for slot = 1, n do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.itemID then
                    seen = seen + 1
                    totals[info.itemID] = (totals[info.itemID] or 0) + (info.stackCount or 1)
                end
            end
            if validate then
                local free = C_Container.GetContainerNumFreeSlots(bag)
                if type(free) == "number" and seen ~= (n - free) then
                    return nil -- data not loaded; don't trust it
                end
            end
        end
    end
    if validate and slotsTotal == 0 then return nil end
    return totals
end

local function ScanEquipped()
    local totals = {}
    if not _G.GetInventoryItemID then return totals end
    for slot = (INVSLOT_FIRST_EQUIPPED or 1), (INVSLOT_LAST_EQUIPPED or 19) do
        local id = _G.GetInventoryItemID("player", slot)
        if id then totals[id] = (totals[id] or 0) + 1 end
    end
    return totals
end

local function ScanMail()
    local numFn = (C_Mail and C_Mail.GetInboxNumItems) or _G.GetInboxNumItems
    local itemFn = _G.GetInboxItem
    if not numFn or not itemFn then return nil end
    local num = numFn()
    if type(num) ~= "number" then return nil end
    local totals = {}
    for i = 1, num do
        for j = 1, (ATTACHMENTS_MAX_RECEIVE or 12) do
            local _, itemID, _, count = itemFn(i, j)
            if itemID then totals[itemID] = (totals[itemID] or 0) + (count or 1) end
        end
    end
    return totals
end

local function CharRecord()
    local c = db.chars[ns.key]
    if not c then
        c = {}
        db.chars[ns.key] = c
    end
    c.name  = UnitName("player")
    c.realm = GetRealmName()
    c.class = select(2, UnitClass("player"))
    c.level = UnitLevel("player")
    c.seen  = time()
    return c
end

-- A bank that suddenly reads as completely empty is far more likely to be
-- "data not loaded yet" than a player emptying everything between two scans.
-- Require two consecutive empty reads before replacing non-empty stored data.
local pendingEmpty = {}
local function ShouldCommit(group, newTotals, oldTotals)
    if next(newTotals) ~= nil then
        pendingEmpty[group] = nil
        return true
    end
    if oldTotals == nil or next(oldTotals) == nil then
        return true
    end
    if pendingEmpty[group] then
        pendingEmpty[group] = nil
        return true
    end
    pendingEmpty[group] = true
    C_Timer.After(1.0, function() SafeCall(ns.Scan) end)
    return false
end

function ns.Scan()
    if not db or not ns.key then return end
    local c = CharRecord()

    local bags = ScanGroup(groups.bags, false)
    if bags then c.bags = bags end
    c.equipped = ScanEquipped()

    if bankOpen then
        local bank = ScanGroup(groups.bank, true)
        if bank and ShouldCommit("bank", bank, c.bank) then c.bank = bank end
        local wb = ScanGroup(groups.warband, true)
        if wb and ShouldCommit("warband", wb, db.warband.items) then
            db.warband.items = wb
            db.warband.ts = time()
            db.warband.by = ns.key
        end
    end
    dirty = true
    if ns.OnDataChanged then ns.OnDataChanged() end
end

function ns.ScanMailNow()
    if not db or not ns.key then return end
    local mail = ScanMail()
    if mail then
        local c = CharRecord()
        c.mail = mail
        dirty = true
        if ns.OnDataChanged then ns.OnDataChanged() end
    end
end

local scanQueued = false
local function QueueScan()
    if scanQueued then return end
    scanQueued = true
    C_Timer.After(0.75, function()
        scanQueued = false
        SafeCall(ns.Scan)
    end)
end

------------------------------------------------------------------------
-- Index
------------------------------------------------------------------------
local function GetIndex()
    if dirty then
        wipe(index)
        for key, c in pairs(db.chars) do
            for _, loc in ipairs(LOCS) do
                local t = c[loc]
                if t then
                    for id, count in pairs(t) do
                        local e = index[id]
                        if not e then e = {}; index[id] = e end
                        local ce = e[key]
                        if not ce then ce = {}; e[key] = ce end
                        ce[loc] = count
                    end
                end
            end
        end
        dirty = false
    end
    return index
end

local function SumEntry(ce)
    local total, parts = 0, {}
    for _, loc in ipairs(LOCS) do
        local n = ce[loc]
        if n and n > 0 and (loc ~= "mail" or opts.includeMail) then
            total = total + n
            parts[#parts + 1] = LOC_LABEL[loc] .. " " .. n
        end
    end
    return total, table.concat(parts, " · ")
end

------------------------------------------------------------------------
-- Tooltip
------------------------------------------------------------------------
local GREY = "|cff9d9d9d"

local function Annotate(tooltip, data)
    if not db or not data then return end
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end

    local id = data.id
    if id == nil then return end
    if _G.issecretvalue and _G.issecretvalue(id) then return end
    if type(id) ~= "number" then return end

    local e = GetIndex()[id]
    local wb = (opts.includeWarband and db.warband.items[id]) or 0

    local selfTotal, selfHere, otherTotal, rows = 0, 0, 0, {}
    if e then
        for key, ce in pairs(e) do
            local sum, text = SumEntry(ce)
            if sum > 0 then
                if key == ns.key then
                    selfTotal = sum
                    selfHere = (ce.bags or 0) + (ce.equipped or 0)
                else
                    otherTotal = otherTotal + sum
                end
                rows[#rows + 1] = { key = key, sum = sum, text = text }
            end
        end
    end

    local total = selfTotal + otherTotal + wb
    if total == 0 then return end
    -- Stay quiet when there's nothing to add beyond "it's in my bags".
    if not opts.alwaysShow and total == selfHere then return end

    local pieces = {}
    if selfTotal > 0 then pieces[#pieces + 1] = "you " .. selfTotal end
    if otherTotal > 0 then pieces[#pieces + 1] = "alts " .. otherTotal end
    if wb > 0 then pieces[#pieces + 1] = "Warband " .. wb end

    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("Owned", total .. "  " .. GREY .. "(" .. table.concat(pieces, ", ") .. ")|r",
        1, 0.82, 0, 1, 1, 1)

    local lineCount = #rows + ((wb > 0) and 1 or 0)
    if opts.alwaysBreakdown or IsShiftKeyDown() then
        table.sort(rows, function(a, b)
            if (a.key == ns.key) ~= (b.key == ns.key) then return a.key == ns.key end
            return a.key < b.key
        end)
        for _, r in ipairs(rows) do
            tooltip:AddDoubleLine("  " .. ColoredName(r.key), r.text, 1, 1, 1, 0.85, 0.85, 0.85)
        end
        if wb > 0 then
            tooltip:AddDoubleLine("  Warband bank", tostring(wb), 0.4, 0.8, 1, 0.85, 0.85, 0.85)
        end
    elseif lineCount > 1 then
        tooltip:AddLine("Hold Shift for details", 0.5, 0.5, 0.5)
    end
end

local function HookTooltips()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
            pcall(Annotate, tooltip, data)
        end)
    end
end

------------------------------------------------------------------------
-- Search
------------------------------------------------------------------------
local MAX_RESULTS = 200

local function BuildResults(query)
    query = (query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if #query < 2 then return {}, 0 end

    local idx = GetIndex()
    local seen, results, unknown = {}, {}, 0

    local function consider(id)
        if seen[id] then return end
        seen[id] = true
        local name = ItemName(id)
        if not name then
            unknown = unknown + 1
            if unknown <= 100 and C_Item and C_Item.RequestLoadItemDataByID then
                C_Item.RequestLoadItemDataByID(id)
            end
            return
        end
        if not name:lower():find(query, 1, true) then return end

        local total, parts = 0, {}
        local e = idx[id]
        if e then
            for key, ce in pairs(e) do
                local sum = SumEntry(ce)
                if sum > 0 then
                    total = total + sum
                    parts[#parts + 1] = { label = ColoredName(key), n = sum }
                end
            end
        end
        local wb = (opts.includeWarband and db.warband.items[id]) or 0
        if wb > 0 then
            total = total + wb
            parts[#parts + 1] = { label = "Warband", n = wb }
        end
        if total > 0 then
            table.sort(parts, function(a, b) return a.n > b.n end)
            local texts = {}
            for i, p in ipairs(parts) do
                if i > 6 then texts[#texts + 1] = "…"; break end
                texts[#texts + 1] = p.label .. " " .. p.n
            end
            results[#results + 1] = { id = id, name = name, total = total, detail = table.concat(texts, "  ·  ") }
        end
    end

    for id in pairs(idx) do consider(id) end
    if opts.includeWarband then
        for id in pairs(db.warband.items) do consider(id) end
    end

    table.sort(results, function(a, b) return a.name < b.name end)
    return results, unknown
end

------------------------------------------------------------------------
-- Search window
------------------------------------------------------------------------
local ROW_H, ROW_W = 34, 380
local frame, edit, content, emptyText, footer
local rows = {}

local function GetRow(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, content)
    r:SetSize(ROW_W, ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)

    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(28, 28)
    r.icon:SetPoint("LEFT", 2, 0)

    r.count = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.count:SetPoint("TOPRIGHT", -4, -3)

    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 6, -1)
    r.name:SetPoint("RIGHT", r.count, "LEFT", -6, 0)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)

    r.detail = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.detail:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 6, 1)
    r.detail:SetPoint("RIGHT", r, "RIGHT", -4, 0)
    r.detail:SetJustifyH("LEFT")
    r.detail:SetWordWrap(false)
    r.detail:SetTextColor(0.65, 0.65, 0.65)

    r:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self.itemID)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:SetScript("OnClick", function(self)
        if IsModifiedClick and IsModifiedClick("CHATLINK") and ChatEdit_InsertLink then
            local link = ItemLink(self.itemID)
            if link then ChatEdit_InsertLink(link) end
        end
    end)

    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)

    rows[i] = r
    return r
end

local function UpdateFooter()
    if not footer or not db then return end
    local n = 0
    for _ in pairs(db.chars) do n = n + 1 end
    local wbText
    if db.warband.ts then
        wbText = "Warband bank saved " .. date("%b %d", db.warband.ts)
    else
        wbText = "Visit your bank once to record the Warband bank"
    end
    footer:SetText(n .. (n == 1 and " character" or " characters") .. " tracked  ·  " .. wbText)
end

function ns.RefreshSearch()
    if not frame or not frame:IsShown() then return end
    local query = edit:GetText() or ""
    local results, unknown = BuildResults(query)
    local shown = math.min(#results, MAX_RESULTS)

    for i = 1, shown do
        local r = GetRow(i)
        local x = results[i]
        r.itemID = x.id
        r.icon:SetTexture(ItemIcon(x.id))
        local name = x.name
        local q = ItemQuality(x.id)
        local qc = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
        if qc and qc.color and qc.color.WrapTextInColorCode then
            name = qc.color:WrapTextInColorCode(name)
        end
        r.name:SetText(name)
        r.count:SetText(x.total)
        r.detail:SetText(x.detail)
        r:Show()
    end
    for i = shown + 1, #rows do rows[i]:Hide() end
    content:SetSize(ROW_W, math.max(1, shown * ROW_H))

    if #query:gsub("%s", "") < 2 then
        emptyText:SetText("Type at least 2 letters to search every character, bank, mail and the Warband bank.")
        emptyText:Show()
    elseif shown == 0 then
        emptyText:SetText(unknown > 0 and "Nothing yet. Some item names are still loading, try again in a moment."
            or "No matches.")
        emptyText:Show()
    else
        emptyText:Hide()
    end
    UpdateFooter()
end

local refreshToken = 0
local function QueueRefresh()
    refreshToken = refreshToken + 1
    local mine = refreshToken
    C_Timer.After(0.15, function()
        if mine == refreshToken then SafeCall(ns.RefreshSearch) end
    end)
end

local function CreateWindow()
    if frame then return end
    frame = CreateFrame("Frame", "StashedFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(430, 500)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    if frame.SetTitle then
        frame:SetTitle("Stashed")
    elseif frame.TitleText then
        frame.TitleText:SetText("Stashed")
    end
    table.insert(UISpecialFrames, "StashedFrame")

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", 16, -32)
    label:SetText("Find an item on any character, bank, mail or the Warband bank")

    edit = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    edit:SetSize(380, 22)
    edit:SetPoint("TOPLEFT", 20, -48)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(60)
    edit:SetScript("OnTextChanged", function() QueueRefresh() end)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -78)
    scroll:SetPoint("BOTTOMRIGHT", -32, 34)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(ROW_W, 1)
    scroll:SetScrollChild(content)

    emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("TOP", scroll, "TOP", 0, -40)
    emptyText:SetWidth(320)
    emptyText:SetJustifyH("CENTER")

    footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", 16, 14)

    frame:SetScript("OnShow", function()
        edit:SetFocus()
        ns.RefreshSearch()
    end)
    frame:Hide()
end

function ns.Toggle(query)
    CreateWindow()
    if query and query ~= "" then
        edit:SetText(query)
        frame:Show()
        ns.RefreshSearch()
    elseif frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end

function ns.OnDataChanged()
    if frame and frame:IsShown() then QueueRefresh() end
end

------------------------------------------------------------------------
-- Options panel
------------------------------------------------------------------------
local function CreateOptions()
    local panel = CreateFrame("Frame")
    panel.name = "Stashed"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Stashed")

    local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    sub:SetText("Log in on a character once to start tracking it. Open your bank once to record the Warband bank.")

    local items = {
        { key = "alwaysShow",      text = "Always show the Owned line (even if every copy is in this character's bags)" },
        { key = "alwaysBreakdown", text = "Show the per-character breakdown without holding Shift" },
        { key = "includeMail",     text = "Count items waiting in mail" },
        { key = "includeWarband",  text = "Count items in the Warband bank" },
    }
    local prev
    for _, it in ipairs(items) do
        local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        if prev then
            cb:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -4)
        else
            cb:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", -2, -16)
        end
        local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", cb, "RIGHT", 4, 1)
        fs:SetText(it.text)
        cb:SetChecked(opts[it.key])
        cb:SetScript("OnClick", function(self)
            opts[it.key] = self:GetChecked() and true or false
            dirty = true
        end)
        prev = cb
    end

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local cat = Settings.RegisterCanvasLayoutCategory(panel, "Stashed")
        Settings.RegisterAddOnCategory(cat)
        ns.settingsCategory = cat
    end
end

local function OpenOptions()
    if Settings and Settings.OpenToCategory and ns.settingsCategory then
        Settings.OpenToCategory(ns.settingsCategory:GetID())
    else
        Print("Options panel unavailable; use the slash commands (/stashed help).")
    end
end

------------------------------------------------------------------------
-- Slash commands & Addon Compartment
------------------------------------------------------------------------
local function ListChars()
    local keys = {}
    for k in pairs(db.chars) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys == 0 then Print("No characters tracked yet."); return end
    for _, k in ipairs(keys) do
        local c = db.chars[k]
        Print(ColoredName(k) .. GREY .. "  last seen " .. (c.seen and date("%Y-%m-%d", c.seen) or "?") .. "|r")
    end
end

local function Forget(arg)
    arg = (arg or ""):lower()
    if arg == "" then Print("Usage: /stashed forget Name or Name-Realm"); return end
    for k, c in pairs(db.chars) do
        if k:lower() == arg or (c.name and c.name:lower() == arg) then
            if k == ns.key then Print("You can't forget the character you're logged in on."); return end
            db.chars[k] = nil
            dirty = true
            Print("Forgot " .. k)
            ns.OnDataChanged()
            return
        end
    end
    Print("No tracked character matches '" .. arg .. "'.")
end

SLASH_STASHED1 = "/stashed"
SLASH_STASHED2 = "/stash"
SlashCmdList["STASHED"] = function(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "" then
        ns.Toggle()
    elseif cmd == "config" or cmd == "options" then
        OpenOptions()
    elseif cmd == "list" then
        ListChars()
    elseif cmd == "forget" then
        Forget(rest)
    elseif cmd == "help" or cmd == "?" then
        Print("/stashed - open search   /stashed <text> - search")
        Print("/stashed config   /stashed list   /stashed forget <name>")
    else
        ns.Toggle(msg)
    end
end

function Stashed_OnCompartmentClick()
    ns.Toggle()
end

function Stashed_OnCompartmentEnter(_, anchor)
    if not db then return end
    GameTooltip:SetOwner(anchor, "ANCHOR_LEFT")
    GameTooltip:AddLine("Stashed", 0.37, 0.78, 1)
    local n = 0
    for _ in pairs(db.chars) do n = n + 1 end
    GameTooltip:AddLine(n .. (n == 1 and " character" or " characters") .. " tracked", 1, 1, 1)
    GameTooltip:AddLine("Click to search your items", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

function Stashed_OnCompartmentLeave()
    GameTooltip:Hide()
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local function InitDB()
    StashedDB = StashedDB or {}
    db = StashedDB
    db.version = 1
    db.chars = db.chars or {}
    db.warband = db.warband or {}
    db.warband.items = db.warband.items or {}
    db.opts = db.opts or {}
    for k, v in pairs(DEFAULTS) do
        if db.opts[k] == nil then db.opts[k] = v end
    end
    opts = db.opts
end

local ev = CreateFrame("Frame")
local function Register(event)
    pcall(ev.RegisterEvent, ev, event) -- unknown events must never break the addon
end

ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        InitDB()
        groups = BuildGroups()
        ev:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGIN" then
        ns.key = CharKey()
        HookTooltips()
        SafeCall(CreateOptions)
        QueueScan()

    elseif event == "PLAYER_ENTERING_WORLD" then
        QueueScan()

    elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_EQUIPMENT_CHANGED" then
        QueueScan()

    elseif event == "BANKFRAME_OPENED" then
        bankOpen = true
        QueueScan()

    elseif event == "BANKFRAME_CLOSED" then
        bankOpen = false

    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW"
        or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        local P = Enum and Enum.PlayerInteractionType
        if P and arg1 and (arg1 == P.Banker or arg1 == P.CharacterBanker or arg1 == P.AccountBanker) then
            if event:find("SHOW") then
                bankOpen = true
                QueueScan()
            else
                bankOpen = false
            end
        end

    elseif event == "MAIL_INBOX_UPDATE" or event == "MAIL_CLOSED" then
        SafeCall(ns.ScanMailNow)

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if frame and frame:IsShown() then QueueRefresh() end
    end
end)

Register("ADDON_LOADED")
Register("PLAYER_LOGIN")
Register("PLAYER_ENTERING_WORLD")
Register("BAG_UPDATE_DELAYED")
Register("PLAYER_EQUIPMENT_CHANGED")
Register("BANKFRAME_OPENED")
Register("BANKFRAME_CLOSED")
Register("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
Register("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
Register("MAIL_INBOX_UPDATE")
Register("MAIL_CLOSED")
Register("GET_ITEM_INFO_RECEIVED")
