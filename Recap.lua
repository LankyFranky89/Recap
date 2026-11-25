local function Secret(v) -- chat hidden by the game (or faked by /cc secret)
  if CopyCatFakeSecret and CopyCatFakeSecret > GetTime() then return true end
  return issecretvalue ~= nil and issecretvalue(v) == true
end
-- Recap: end-of-session summary card for WoW Forever
local ADDON = ...
local GetItemInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)
local Recap = CreateFrame("Frame")
local S -- current session (RecapCharDB.session)

local QUALITY_COLORS = { [0]="9d9d9d", [1]="ffffff", [2]="1eff00", [3]="0070dd", [4]="a335ee", [5]="ff8000" }
local GOLD = "|cffffd100"
local MUTED = "|cffa89a7c"

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage(GOLD .. "Recap:|r " .. msg) end

local function FormatTime(sec)
    sec = math.max(0, math.floor(sec or 0))
    local h, m = math.floor(sec / 3600), math.floor((sec % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm", m)
end

local function FormatMoney(copper)
    local sign = copper < 0 and "-" or "+"
    copper = math.abs(copper)
    local g, s, c = math.floor(copper / 10000), math.floor((copper % 10000) / 100), copper % 100
    if g > 0 then return string.format("%s%dg %ds", sign, g, s) end
    if s > 0 then return string.format("%s%ds %dc", sign, s, c) end
    return string.format("%s%dc", sign, c)
end

local function Commas(n)
    local s = tostring(math.floor(n or 0))
    while true do
        local k
        s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return s
end

---------------------------------------------------------------------------
-- Session handling
---------------------------------------------------------------------------
local function NewSession()
    return {
        start = time(), last = time(),
        startLevel = UnitLevel("player"), level = UnitLevel("player"),
        xp = 0, lastXP = UnitXP("player"), lastXPMax = UnitXPMax("player"),
        money = 0, earned = 0, spent = 0, lastMoney = GetMoney(),
        quests = 0, zones = {}, zoneOrder = {},
        deaths = 0, killers = {}, kills = {},
        bestLoot = nil, bestQuality = -1, bestLevel = -1,
        grouped = {},
    }
end

local function Archive(sess)
    if not sess or (sess.last - sess.start) < 60 then return end
    RecapDB.history = RecapDB.history or {}
    local entry = {}
    for k, v in pairs(sess) do entry[k] = v end
    entry.char = UnitName("player")
    table.insert(RecapDB.history, 1, entry)
    while #RecapDB.history > 50 do table.remove(RecapDB.history) end
end

local function AddZone()
    local z = GetRealZoneText()
    if z and z ~= "" and not S.zones[z] then
        S.zones[z] = true
        table.insert(S.zoneOrder, z)
    end
end

local function Touch() if S then S.last = time() end end

---------------------------------------------------------------------------
-- Stat tracking
---------------------------------------------------------------------------
local function OnXP()
    local cur, max, lvl = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
    if lvl > S.level then
        S.xp = S.xp + (S.lastXPMax - S.lastXP) + cur
        S.level = lvl
    elseif cur >= S.lastXP then
        S.xp = S.xp + (cur - S.lastXP)
    end
    S.lastXP, S.lastXPMax = cur, max
end

local function OnMoney()
    local now = GetMoney()
    local d = now - S.lastMoney
    if d > 0 then S.earned = S.earned + d else S.spent = S.spent - d end
    S.money = S.money + d
    S.lastMoney = now
end

local LOOT_PATTERNS = {}
local function BuildLootPatterns()
    for _, g in ipairs({ "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE" }) do
        local fmt = _G[g]
        if fmt then
            local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
            p = p:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
            table.insert(LOOT_PATTERNS, "^" .. p)
        end
    end
end

local function OnLoot(msg)
    if not msg or Secret(msg) then return end
    for _, p in ipairs(LOOT_PATTERNS) do
        local link = msg:match(p)
        if link then
            local _, _, quality, ilvl = GetItemInfo(link)
            if quality and (quality > S.bestQuality or (quality == S.bestQuality and (ilvl or 0) > S.bestLevel)) then
                S.bestLoot, S.bestQuality, S.bestLevel = link, quality, ilvl or 0
            end
            return
        end
    end
end

local playerGUID
local KILL_PATTERNS = {}
local function BuildKillPatterns()
    for _, g in ipairs({ "COMBATLOG_XPGAIN_FIRSTPERSON", "COMBATLOG_XPGAIN_EXHAUSTION1", "COMBATLOG_XPGAIN_FIRSTPERSON_GROUP" }) do
        local fmt = _G[g]
        if fmt then
            local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
            p = p:gsub("%%%%s", "(.-)"):gsub("%%%%d", "%%d+")
            table.insert(KILL_PATTERNS, "^" .. p)
        end
    end
end

local function OnXPMsg(msg)
    if not msg or Secret(msg) then return end
    for _, p in ipairs(KILL_PATTERNS) do
        local mob = msg:match(p)
        if mob and mob ~= "" then
            S.kills[mob] = (S.kills[mob] or 0) + 1
            return
        end
    end
end

local function OnDeath()
    S.deaths = S.deaths + 1
    local killer
    if UnitExists("target") and UnitCanAttack("player", "target") then killer = UnitName("target") end
    if killer then S.killers[killer] = (S.killers[killer] or 0) + 1 end
end

local function OnRoster()
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    local unitBase = IsInRaid and IsInRaid() and "raid" or "party"
    for i = 1, n do
        local name = UnitName(unitBase .. i)
        if name and name ~= UNKNOWNOBJECT and name ~= UnitName("player") then S.grouped[name] = true end
    end
end

---------------------------------------------------------------------------
-- Summary helpers
---------------------------------------------------------------------------
local function TopOf(t)
    local best, n = nil, 0
    for k, v in pairs(t) do if v > n then best, n = k, v end end
    return best, n
end

local function CountKeys(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

local FUN_LINES = {
    "They will remember you.",
    "Their families have been notified.",
    "A personal grudge, clearly.",
    "Someone has to do it.",
}

local function FunStat(sess)
    local mob, n = TopOf(sess.kills)
    if mob and n >= 3 then
        return string.format("You killed %d %s. %s", n, mob, FUN_LINES[(n % #FUN_LINES) + 1])
    end
    if sess.deaths == 0 and (sess.last - sess.start) > 1800 then return "Not a single death. Flawless." end
    if #sess.zoneOrder >= 4 then return string.format("%d zones in one night. Wanderlust.", #sess.zoneOrder) end
    return "A quiet session. Sometimes that's the best kind."
end

local function OneLiner(sess)
    local parts = { "Recap: " .. FormatTime(sess.last - sess.start) }
    if sess.xp > 0 then table.insert(parts, Commas(sess.xp) .. " XP") end
    if sess.level > sess.startLevel then table.insert(parts, "dinged " .. sess.level) end
    if sess.quests > 0 then table.insert(parts, sess.quests .. " quests") end
    if sess.money ~= 0 then table.insert(parts, FormatMoney(sess.money)) end
    table.insert(parts, sess.deaths .. (sess.deaths == 1 and " death" or " deaths"))
    if sess.bestLoot then table.insert(parts, "best loot " .. sess.bestLoot) end
    return table.concat(parts, " | ")
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------
local UI
local shown -- session currently displayed

local function MakeTile(parent, x, label)
    local t = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate")
    t:SetSize(110, 52)
    t:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -56)
    t:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    t:SetBackdropColor(0.13, 0.11, 0.08, 1)
    t.label = t:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    t.label:SetPoint("TOPLEFT", 8, -6)
    t.label:SetText(label)
    t.value = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    t.value:SetPoint("TOPLEFT", 8, -20)
    t.sub = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    t.sub:SetPoint("TOPLEFT", 8, -38)
    return t
end

local function MakeRow(parent, i, label)
    local y = -120 - (i - 1) * 20
    local l = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    l:SetPoint("TOPLEFT", 14, y)
    l:SetTextColor(0.66, 0.6, 0.49)
    l:SetText(label)
    local v = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    v:SetPoint("TOPRIGHT", -14, y)
    v:SetJustifyH("RIGHT")
    v:SetWidth(220)
    v:SetWordWrap(false)
    return v
end

local function BuildUI()
    UI = CreateFrame("Frame", "RecapFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
    UI:SetSize(380, 300)
    UI:SetPoint("CENTER", 0, 80)
    UI:SetFrameStrata("DIALOG")
    UI:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    UI:SetBackdropColor(0.08, 0.07, 0.05, 0.96)
    UI:SetBackdropBorderColor(0.6, 0.5, 0.3, 1)
    UI:EnableMouse(true)
    UI:SetMovable(true)
    UI:RegisterForDrag("LeftButton")
    UI:SetScript("OnDragStart", UI.StartMoving)
    UI:SetScript("OnDragStop", UI.StopMovingOrSizing)
    UI:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "RecapFrame")

    UI.title = UI:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    UI.title:SetPoint("TOPLEFT", 14, -12)
    UI.title:SetText("Recap")
    UI.when = UI:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    UI.when:SetPoint("LEFT", UI.title, "RIGHT", 10, 0)
    UI.who = UI:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    UI.who:SetPoint("TOPLEFT", 14, -36)

    local close = CreateFrame("Button", nil, UI, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    UI.tPlayed = MakeTile(UI, 12, "Played")
    UI.tXP = MakeTile(UI, 135, "XP")
    UI.tGold = MakeTile(UI, 258, "Gold")

    UI.rQuests = MakeRow(UI, 1, "Quests turned in")
    UI.rZones = MakeRow(UI, 2, "Zones")
    UI.rDeaths = MakeRow(UI, 3, "Deaths")
    UI.rLoot = MakeRow(UI, 4, "Best loot")
    UI.rGroup = MakeRow(UI, 5, "Grouped with")

    local lootHover = CreateFrame("Button", nil, UI)
    lootHover:SetPoint("TOPRIGHT", UI.rLoot, "TOPRIGHT", 0, 2)
    lootHover:SetPoint("BOTTOMLEFT", UI.rLoot, "BOTTOMLEFT", 0, -2)
    lootHover:SetScript("OnEnter", function(self)
        if shown and shown.bestLoot then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(shown.bestLoot)
            GameTooltip:Show()
        end
    end)
    lootHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    lootHover:SetScript("OnClick", function()
        if shown and shown.bestLoot and IsModifiedClick then
            if IsModifiedClick("CHATLINK") and ChatEdit_InsertLink then ChatEdit_InsertLink(shown.bestLoot)
            elseif IsModifiedClick("DRESSUP") and DressUpItemLink then DressUpItemLink(shown.bestLoot) end
        end
    end)

    UI.fun = UI:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    UI.fun:SetPoint("TOPLEFT", 14, -226)
    UI.fun:SetPoint("RIGHT", -14, 0)
    UI.fun:SetJustifyH("LEFT")
    UI.fun:SetTextColor(1, 0.82, 0)

    local copy = CreateFrame("Button", nil, UI, "UIPanelButtonTemplate")
    copy:SetSize(110, 22)
    copy:SetPoint("BOTTOMRIGHT", -12, 12)
    copy:SetText("Copy to chat")
    copy:SetScript("OnClick", function()
        if shown then local open = ChatFrame_OpenChat or (ChatFrameUtil and ChatFrameUtil.OpenChat); if open then open(OneLiner(shown)) end end
    end)

    UI.hint = UI:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    UI.hint:SetPoint("BOTTOMLEFT", 14, 18)
    UI.hint:SetText("/recap last · /recap week")
end

local function ShowSession(sess, heading)
    if not UI then BuildUI() end
    shown = sess
    UI.title:SetText(heading or "Recap")
    UI.when:SetText(date("%a %H:%M", sess.start) .. " – " .. date("%H:%M", sess.last))
    UI.who:SetText((sess.char or UnitName("player")) .. " · Level " .. sess.level .. " " .. (UnitClass("player") or ""))

    UI.tPlayed.value:SetText(FormatTime(sess.last - sess.start))
    UI.tPlayed.sub:SetText("")
    UI.tXP.value:SetText("|cffc78cff+" .. Commas(sess.xp) .. "|r")
    UI.tXP.sub:SetText(sess.level > sess.startLevel and ("Ding! " .. sess.startLevel .. " → " .. sess.level) or "")
    UI.tGold.value:SetText(GOLD .. FormatMoney(sess.money) .. "|r")
    UI.tGold.sub:SetText(MUTED .. "spent " .. FormatMoney(sess.spent):sub(2) .. "|r")

    UI.rQuests:SetText(sess.quests)
    UI.rZones:SetText(#sess.zoneOrder > 0 and table.concat(sess.zoneOrder, ", ") or "—")
    local killer = TopOf(sess.killers)
    UI.rDeaths:SetText(sess.deaths .. (killer and (MUTED .. " (" .. killer .. ")|r") or ""))
    UI.rLoot:SetText(sess.bestLoot or "—")
    local g = CountKeys(sess.grouped)
    UI.rGroup:SetText(g == 0 and "Solo" or (g .. (g == 1 and " player" or " players")))

    UI.fun:SetText("Fun stat: " .. FunStat(sess))
    UI:Show()
end

local function WeekSummary()
    local cutoff = time() - 7 * 86400
    local w = NewSession()
    w.start, w.last, w.char = time(), time(), UnitName("player") .. " (7 days)"
    w.startLevel, w.level = 999, 0
    local played, any = 0, false
    local all = { S }
    for _, h in ipairs(RecapDB.history or {}) do table.insert(all, h) end
    for _, h in ipairs(all) do
        if h.start >= cutoff and (h.char == nil or h.char == UnitName("player")) then
            any = true
            played = played + (h.last - h.start)
            w.start = math.min(w.start, h.start)
            w.startLevel = math.min(w.startLevel, h.startLevel)
            w.level = math.max(w.level, h.level)
            w.xp, w.money, w.spent = w.xp + h.xp, w.money + h.money, w.spent + h.spent
            w.quests, w.deaths = w.quests + h.quests, w.deaths + h.deaths
            for _, z in ipairs(h.zoneOrder) do if not w.zones[z] then w.zones[z] = true table.insert(w.zoneOrder, z) end end
            for k, v in pairs(h.kills) do w.kills[k] = (w.kills[k] or 0) + v end
            for k, v in pairs(h.killers) do w.killers[k] = (w.killers[k] or 0) + v end
            for k in pairs(h.grouped) do w.grouped[k] = true end
            if h.bestLoot and (h.bestQuality or -1) > w.bestQuality then
                w.bestLoot, w.bestQuality = h.bestLoot, h.bestQuality
            end
        end
    end
    if not any then return nil end
    w.last = w.start + played
    return w
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
Recap:RegisterEvent("ADDON_LOADED")
Recap:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        RecapDB = RecapDB or {}
        RecapDB.history = RecapDB.history or {}
        if RecapDB.popupOnLogout == nil then RecapDB.popupOnLogout = true end
        RecapCharDB = RecapCharDB or {}
        BuildLootPatterns()
        BuildKillPatterns()
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:UnregisterEvent("ADDON_LOADED")
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        local isLogin, isReload = ...
        playerGUID = UnitGUID("player")
        local old = RecapCharDB.session
        -- keep the session through /reload and short disconnects (< 15 min)
        if old and (isReload or (not isLogin) or (time() - (old.last or 0) < 900)) then
            S = old
            S.lastXP, S.lastXPMax, S.lastMoney = UnitXP("player"), UnitXPMax("player"), GetMoney()
        else
            if old then Archive(old) end
            S = NewSession()
            RecapCharDB.session = S
        end
        if not self.registered then
            self.registered = true
            for _, e in ipairs({ "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "PLAYER_MONEY", "QUEST_TURNED_IN",
                "CHAT_MSG_LOOT", "CHAT_MSG_COMBAT_XP_GAIN", "PLAYER_DEAD", "ZONE_CHANGED_NEW_AREA",
                "GROUP_ROSTER_UPDATE", "PLAYER_CAMPING", "PLAYER_QUITING", "PLAYER_LOGOUT" }) do
                self:RegisterEvent(e)
            end
            C_Timer.NewTicker(30, Touch)
        end
        AddZone()
        OnRoster()
        return
    end

    if not S then return end
    Touch()
    if event == "PLAYER_XP_UPDATE" or event == "PLAYER_LEVEL_UP" then
        C_Timer.After(0, OnXP)
    elseif event == "PLAYER_MONEY" then OnMoney()
    elseif event == "QUEST_TURNED_IN" then S.quests = S.quests + 1
    elseif event == "CHAT_MSG_LOOT" then OnLoot((...))
    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then OnXPMsg((...))
    elseif event == "PLAYER_DEAD" then OnDeath()
    elseif event == "ZONE_CHANGED_NEW_AREA" then AddZone()
    elseif event == "GROUP_ROSTER_UPDATE" then OnRoster()
    elseif event == "PLAYER_CAMPING" or event == "PLAYER_QUITING" then
        if RecapDB.popupOnLogout then ShowSession(S, "Recap") end
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_RECAP1 = "/recap"
SlashCmdList.RECAP = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "" then
        if S then ShowSession(S, "Recap") end
    elseif msg == "last" then
        local h = RecapDB.history[1]
        if h then ShowSession(h, "Last session") else Print("No earlier session saved yet.") end
    elseif msg == "week" then
        local w = WeekSummary()
        if w then ShowSession(w, "This week") else Print("Nothing recorded this week yet.") end
    elseif msg == "popup" then
        RecapDB.popupOnLogout = not RecapDB.popupOnLogout
        Print("Popup on logout " .. (RecapDB.popupOnLogout and "on." or "off."))
    elseif msg == "reset" then
        if S then Archive(S) end
        S = NewSession()
        RecapCharDB.session = S
        Print("Started a fresh session.")
    else
        Print("/recap · /recap last · /recap week · /recap popup · /recap reset")
    end
end
