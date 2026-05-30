--[[--------------------------------------------------------------------------
    Minimap Icon Bar
    --------------------------------------------------------------------------
    Collects the loose minimap "addon" buttons into one movable bar that looks
    and scales like an action bar.

    * The bag/toggle button is the first slot (drag to move, click to open/close,
      right-click for options). The row grows in the direction you choose and the
      toggle stays put.
    * Buttons are de-circled and shown in a stock action-bar slot by default, or
      skinned by Masque or ElvUI if you have them (selectable per profile).
    * Button size, spacing, scale, and buttons-per-row are all configurable.
    * Per-character profiles, with named profiles you can share across alts.

    Slash command:  /mib   (see "/mib" with no argument for the full list)
----------------------------------------------------------------------------]]

-- ===========================================================================
-- Saved-variable defaults
-- ===========================================================================
local DEFAULTS = {
    x             = 0,
    y             = 0,
    scale         = 1.0,
    size          = 32,
    spacing       = 2,
    buttonsPerRow = 6,
    growth        = "DOWN_RIGHT",
    isOpen        = false,
    lockOpen      = false,               -- keep the bar expanded; click won't close it
    lockMode      = "unlocked",          -- "unlocked" | "locked" | "editmode"
    skinStyle     = "auto",              -- "auto" | "default" | "elvui" | "masque"
    order         = {},                  -- saved icon order (list of button names)
}

local SKIN_ORDER = { "auto", "default", "elvui", "masque" }
local SKIN_TEXT  = {
    auto    = "Automatic (Masque/ElvUI if present)",
    default = "Default WoW action bar",
    elvui   = "ElvUI",
    masque  = "Masque",
}

local LOCK_ORDER = { "unlocked", "locked", "editmode" }
local LOCK_TEXT  = {
    unlocked = "Unlocked (drag freely)",
    locked   = "Locked",
    editmode = "Only in Edit Mode",
}

local GROWTH_ORDER = { "DOWN_RIGHT", "DOWN_LEFT", "UP_RIGHT", "UP_LEFT" }
local GROWTH_TEXT  = {
    DOWN_RIGHT = "Right, then Down",
    DOWN_LEFT  = "Left, then Down",
    UP_RIGHT   = "Right, then Up",
    UP_LEFT    = "Left, then Up",
}

-- Fill any missing keys of a profile table with the defaults. A stored value
-- whose type no longer matches the default (a corrupted or hand-edited save) is
-- reset to the default too, so it can't reach arithmetic/`#` and error at login.
local function fillDefaults(t)
    for k, v in pairs(DEFAULTS) do
        if t[k] == nil or type(t[k]) ~= type(v) then
            if type(v) == "table" then
                local c = {}; for i, vv in ipairs(v) do c[i] = vv end; t[k] = c
            else
                t[k] = v
            end
        end
    end
    if t.lockMode == nil then t.lockMode = t.locked and "locked" or "unlocked" end
    t.locked = nil
end

-- ===========================================================================
-- Buttons we must never swallow
-- ===========================================================================
local IGNORE_EXACT = {
    Minimap = true, MinimapCluster = true, MinimapBackdrop = true,
    MinimapZoomIn = true, MinimapZoomOut = true,
    MiniMapTracking = true, MiniMapTrackingButton = true,
    MinimapZoneTextButton = true, MiniMapWorldMapButton = true,
    GameTimeFrame = true, TimeManagerClockButton = true,
    MiniMapMailFrame = true, MiniMapBattlefieldFrame = true,
    QueueStatusMinimapButton = true, MiniMapInstanceDifficulty = true,
    GuildInstanceDifficulty = true, MiniMapChallengeMode = true,
    ExpansionLandingPageMinimapButton = true, HelpOpenWebTicketButton = true,
    GarrisonLandingPageMinimapButton = true, MiniMapVoiceChatFrame = true,
    MinimapIconBarButton = true, MinimapIconBarFrame = true,
}

local IGNORE_PATTERN = {
    "GatherMate", "HandyNotes", "TomTom", "Archy", "WorldMapPin",
    "Pin$", "Ping", "Cluster",
}

local STRIP_FIELDS = {
    "Background", "background", "Border", "border", "Overlay", "overlay",
    "Shine", "shine", "Ring", "ring", "Backdrop", "backdrop",
}

local STRIP_KEYWORDS = {
    "border", "background", "alphamask", "tracking", "ring", "shine",
    "guildbanner", "minimap%-trackingborder", "minimapbutton", "%-border",
    "overlay", "minimap%-tracking",
}

-- Textures set by FileDataID (a number) have no path to keyword-match, so list
-- the known minimap border/ring file IDs explicitly.
local BORDER_FILEIDS = {
    [136430] = true,  -- Interface\Minimap\MiniMap-TrackingBorder (the round ring)
}

-- Tunables -------------------------------------------------------------------
local COLLECT_MIN_WIDTH = 15    -- ignore frames narrower than this (px)
local COLLECT_MAX_WIDTH = 45    -- ...or wider; real minimap buttons sit between
local BORDER_OVERSIZE   = 1.12  -- a texture >112% of the button is a ring/border, not the icon
local ICON_CROP         = 0.06  -- fraction trimmed off each icon edge (de-circle the art)
local ATLAS_FRAME_INSET = 0.08  -- HUD icon-frame overhang, as a fraction of button size
local QUICKSLOT_SCALE   = 1.83  -- classic Quickslot border size relative to the button

-- ===========================================================================
-- State
-- ===========================================================================
local db
local store, charKey, activeProfile   -- profile system
local collected   = {}
local isCollected  = {}
local bar, toggle, config, configProfiles
local E, ELVUI
local Masque, MasqueGroup
local inEditMode = false
local pendingScan = false   -- a scan was requested during combat; run it after
local optionsCategory   -- Blizzard Settings category for this addon

local internalToggle = false   -- true while WE show/hide buttons (vs the owner)
local layout                   -- forward declaration (used by the hide/show hooks)
local applyOrder, captureOrder, reorderEnabled, onBtnDragStart, onBtnDragStop
local relayoutPending = false
local function requestRelayout()
    if relayoutPending then return end
    relayoutPending = true
    C_Timer.After(0, function() relayoutPending = false; if layout then layout() end end)
end

-- While reordering, the grabbed icon follows the cursor.
local dragBtn
local dragUpdater = CreateFrame("Frame")
dragUpdater:Hide()
dragUpdater:SetScript("OnUpdate", function()
    if not dragBtn or not dragBtn.__mbcOrigSetPoint then return end
    if not dragBtn:IsShown() then internalToggle = true; dragBtn:Show(); internalToggle = false end
    local uScale = UIParent:GetEffectiveScale()
    local mx, my = GetCursorPosition()
    dragBtn.__mbcOrigSetPoint(dragBtn, "CENTER", UIParent, "BOTTOMLEFT", mx / uScale, my / uScale)
end)

local PREFIX = "|cff66ccffMinimap Icon Bar|r"
local function msg(s) print(PREFIX .. ": " .. s) end

-- ===========================================================================
-- Blizzard Settings panel open / close
-- ===========================================================================
local function optionsShown()
    return _G.SettingsPanel and SettingsPanel:IsShown()
end
local function openOptions()
    -- OpenSettingsPanel() is protected during combat; calling it then trips
    -- ADDON_ACTION_BLOCKED. Bail with a note instead.
    if InCombatLockdown and InCombatLockdown() then
        msg("can't open the settings panel during combat - try again afterwards.")
        return
    end
    if optionsCategory and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(optionsCategory:GetID())
    end
end
local function closeOptions()
    if _G.SettingsPanel and HideUIPanel then HideUIPanel(SettingsPanel) end
end
local function toggleOptions()
    if optionsShown() then closeOptions() else openOptions() end
end

-- May the bar be dragged right now?
local function canMove()
    local m = (db and db.lockMode) or "unlocked"
    if m == "unlocked" then return true end
    if m == "editmode" then return inEditMode end
    return false
end

local function updateEditHighlight()
    if bar and bar.editHighlight then
        bar.editHighlight:SetShown(inEditMode and db.lockMode == "editmode")
    end
end

-- ===========================================================================
-- Helpers
-- ===========================================================================
local function setSize(frame, s)  (frame.__mbcOrigSetSize  or frame.SetSize )(frame, s, s) end
local function setPoint(frame, ...) (frame.__mbcOrigSetPoint or frame.SetPoint)(frame, ...) end

local function looksLikeBorder(texStr)
    if not texStr or texStr == "" then return false end
    for _, k in ipairs(STRIP_KEYWORDS) do
        if texStr:find(k) then return true end
    end
    return false
end

local function findIcon(btn)
    local cands = { btn.icon, btn.Icon, btn.iconTexture, btn.IconTexture,
                    btn.texture, btn.Texture }
    for _, c in ipairs(cands) do
        if type(c) == "table" and c.IsObjectType and c:IsObjectType("Texture") then
            return c
        end
    end
    return nil
end

-- When a button has no named icon field, guess it: the icon is the texture that
-- has actual art, isn't a known/oversized border, and isn't a glow/highlight.
local function guessIcon(btn, bw)
    local best, bestArea
    local num = (btn.GetNumRegions and btn:GetNumRegions()) or 0
    for i = 1, num do
        local r = select(i, btn:GetRegions())
        if r and r.IsObjectType and r:IsObjectType("Texture") then
            local tex = r:GetTexture()
            if tex then
                local fid = tonumber(tostring(tex))
                local ts  = tostring(tex):lower()
                local rw  = (r:GetWidth() or 0)
                local oversized = bw > 0 and rw > bw * BORDER_OVERSIZE
                if not (fid and BORDER_FILEIDS[fid]) and not looksLikeBorder(ts) and not oversized then
                    local area = rw
                    if not bestArea or area > bestArea then best, bestArea = r, area end
                end
            end
        end
    end
    return best
end

-- Default (no skin library) look: a stock WoW action-bar slot.
-- Modern atlas if available, classic Quickslot border as fallback.
local FRAME_ATLAS = "UI-HUD-ActionBar-IconFrame"
local function hasAtlas(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end
local USE_ATLAS = nil  -- resolved lazily on first use

-- Default (no skin library) look: the standard Midnight HUD action-button.
-- Uses Blizzard's UI-HUD-ActionBar-IconFrame atlas (slot + frame). The frame's
-- opening is offset ~1px from the button centre, so the icon + its black
-- backing are shifted by the same amount to sit centred inside the frame.
local OPEN_OX, OPEN_OY = -1, 1   -- frame-opening offset (left, up)

local function actionBarSkin(btn, icon)
    if USE_ATLAS == nil then USE_ATLAS = hasAtlas(FRAME_ATLAS) end

    -- Solid black fill under the icon, aligned to the frame opening.
    if not btn.__mbcSlot then
        btn.__mbcSlot = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
    end
    local slot = btn.__mbcSlot
    slot:ClearAllPoints()
    slot:SetPoint("TOPLEFT", btn, "TOPLEFT", OPEN_OX, OPEN_OY)
    -- Extend 1px lower than the icon so the bottom edge has no gap.
    slot:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", OPEN_OX, OPEN_OY - 1)
    slot:SetTexture(nil)
    slot:SetColorTexture(0, 0, 0, 1)
    slot:Show()

    if btn.__mbcBorder then btn.__mbcBorder:Hide() end  -- drop old flat border

    -- Icon, shifted by the same opening offset so it sits on its black backing
    -- and centred within the frame (no off-centre drift).
    if icon then
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", btn, "TOPLEFT", OPEN_OX, OPEN_OY)
        icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", OPEN_OX, OPEN_OY)
        if icon.SetTexCoord then icon:SetTexCoord(ICON_CROP, 1 - ICON_CROP, ICON_CROP, 1 - ICON_CROP) end
        if icon.SetDrawLayer then icon:SetDrawLayer("ARTWORK") end
    end

    -- HUD icon frame, drawn slightly larger than the slot (Blizzard ~1.16x),
    -- so the border frames the icon the way the action bar does.
    if not btn.__mbcFrame then
        btn.__mbcFrame = btn:CreateTexture(nil, "OVERLAY")
    end
    local fr = btn.__mbcFrame
    fr:ClearAllPoints()
    if USE_ATLAS then
        local o = (db.size or 32) * ATLAS_FRAME_INSET
        fr:SetAtlas(FRAME_ATLAS, false)
        fr:SetPoint("TOPLEFT", btn, "TOPLEFT", -o, o)
        fr:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", o, -o)
    else
        -- Classic raised border on clients without the HUD atlas.
        fr:SetTexture("Interface\\Buttons\\UI-Quickslot2")
        fr:SetTexCoord(0, 1, 0, 1)
        fr:SetPoint("CENTER", btn, "CENTER")
        local s = (db.size or 32) * QUICKSLOT_SCALE
        fr:SetSize(s, s)
    end
    fr:Show()
end

-- ===========================================================================
-- Collection eligibility
-- ===========================================================================
local function shouldCollect(child)
    local name = child:GetName()
    if not name then return false end
    if IGNORE_EXACT[name] then return false end
    for _, pat in ipairs(IGNORE_PATTERN) do
        if name:find(pat) then return false end
    end
    local otype = child:GetObjectType()
    if otype ~= "Button" and otype ~= "Frame" then return false end
    if name:find("LibDBIcon") then return true end
    local w = child:GetWidth() or 0
    if w < COLLECT_MIN_WIDTH or w > COLLECT_MAX_WIDTH then return false end
    local function hasScript(s) return child:HasScript(s) and child:GetScript(s) ~= nil end
    return hasScript("OnClick") or hasScript("OnMouseUp") or hasScript("OnMouseDown")
end

-- ===========================================================================
-- Strip round border, square the icon (or hand to Masque)
-- ===========================================================================

-- Hide every skin artifact we own (and any ElvUI backdrop), so switching
-- profiles never leaves the previous look stacked underneath.
local function hideAllOwnSkin(btn)
    if btn.__mbcSlot then btn.__mbcSlot:Hide() end
    if btn.__mbcFrame then btn.__mbcFrame:Hide() end
    if btn.__mbcBorder then btn.__mbcBorder:Hide() end
    if btn.backdrop and btn.backdrop.Hide then btn.backdrop:Hide() end
end

-- Masque's RemoveButton doesn't un-skin (it applies a default skin), so to
-- leave Masque we keep the button registered and just hide its skin layers.
local MSQ_LAYERS = { "Backdrop", "Border", "Normal", "Gloss", "Shadow" }
local function hideMasqueLayers(btn)
    if not (MasqueGroup and MasqueGroup.GetLayer) then return end
    for _, layer in ipairs(MSQ_LAYERS) do
        local ok, r = pcall(function() return MasqueGroup:GetLayer(btn, layer) end)
        if ok and type(r) == "table" and r.Hide then r:Hide() end
    end
end

-- Resolve the active profile from the user's choice and what's installed.
-- Returns "masque" | "elvui" | "default".
local function chosenSkin()
    local s = (db and db.skinStyle) or "auto"
    if s == "masque" then return MasqueGroup and "masque" or "default" end
    if s == "elvui"  then return (ELVUI and E) and "elvui" or "default" end
    if s == "default" then return "default" end
    if MasqueGroup then return "masque" end        -- auto
    if ELVUI and E  then return "elvui" end
    return "default"
end

-- Tear down everything, then the chosen profile is the only thing shown.
local function clearSkinState(btn, skin)
    hideAllOwnSkin(btn)
    if skin ~= "masque" and btn.__mbcMasqued then
        hideMasqueLayers(btn)
    end
end

-- Apply the chosen profile to an already-prepared button. Idempotent: safe to
-- re-run when switching profiles - it never re-detects or re-strips.
local function applySkin(btn)
    local icon = btn.__mbcIcon
    if not icon then return end
    local skin = chosenSkin()
    clearSkinState(btn, skin)
    if skin == "masque" then
        if not btn.__mbcMasqued then
            btn.__mbcMasqued = true
            local hl = btn.GetHighlightTexture and btn:GetHighlightTexture() or nil
            pcall(function() MasqueGroup:AddButton(btn, { Icon = icon, Highlight = hl }) end)
        end
    elseif skin == "elvui" then
        -- ElvUI action-bar style: ElvUI backdrop + cropped icon.
        pcall(function()
            if btn.CreateBackdrop and not btn.__mbcElvSkin then
                btn:CreateBackdrop()
                btn.__mbcElvSkin = true
            end
            if btn.backdrop then btn.backdrop:Show() end
            local target = btn.backdrop or btn
            icon:ClearAllPoints()
            icon:SetPoint("TOPLEFT", target, "TOPLEFT", 1, -1)
            icon:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", -1, 1)
            if icon.SetTexCoord and type(E.TexCoords) == "table" then
                icon:SetTexCoord(E.TexCoords[1], E.TexCoords[2], E.TexCoords[3], E.TexCoords[4])
            end
            if icon.SetDrawLayer then icon:SetDrawLayer("ARTWORK") end
        end)
    else
        -- Default: stock WoW action-bar slot look.
        actionBarSkin(btn, icon)
    end
end

local function squareButton(btn)
    if not btn.__mbcPrepared then
        btn.__mbcPrepared = true

        local bw = btn:GetWidth() or db.size or 32
        local icon = findIcon(btn)
        if not icon then icon = guessIcon(btn, bw) end
        if not icon and btn.GetNormalTexture then
            local nt = btn:GetNormalTexture()
            if nt and nt.GetTexture and nt:GetTexture() then icon = nt end
        end
        btn.__mbcIcon = icon

        for _, key in ipairs(STRIP_FIELDS) do
            local r = btn[key]
            if type(r) == "table" and r ~= icon and r.IsObjectType and r:IsObjectType("Texture") then
                r:SetTexture(nil); r:SetAlpha(0); r:Hide()
            end
        end
        if btn.GetNormalTexture then
            local nt = btn:GetNormalTexture()
            if nt and nt ~= icon and looksLikeBorder(tostring(nt:GetTexture() or ""):lower()) then
                nt:SetTexture(nil); nt:SetAlpha(0)
            end
        end
        for _, getter in ipairs({ "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }) do
            if btn[getter] then
                local t = btn[getter](btn)
                if t and t ~= icon then t:SetTexture(nil); if t.SetAlpha then t:SetAlpha(0) end end
            end
        end
        local function stripRegions(parent)
            local num = (parent.GetNumRegions and parent:GetNumRegions()) or 0
            for i = 1, num do
                local region = select(i, parent:GetRegions())
                if region and region ~= icon and region.IsObjectType and region:IsObjectType("Texture") then
                    local tex = region:GetTexture()
                    local ts  = tostring(tex or ""):lower()
                    local fid = tonumber(tostring(tex or ""))
                    local rw  = (region.GetWidth and region:GetWidth()) or 0
                    local isBorderId = fid and BORDER_FILEIDS[fid]
                    -- Minimap ring overlays are usually a texture larger than the
                    -- button; strip those even when their path has no keyword.
                    local oversized = icon and rw > 0 and bw > 0 and rw > bw * BORDER_OVERSIZE
                    if isBorderId or looksLikeBorder(ts) or oversized then
                        region:SetTexture(nil); region:SetAlpha(0); region:Hide()
                    end
                end
            end
        end
        stripRegions(btn)
        -- Some addons draw the ring on a child frame, not the button itself.
        if btn.GetChildren then
            for _, sub in ipairs({ btn:GetChildren() }) do
                stripRegions(sub)
            end
        end
    end

    applySkin(btn)
    setSize(btn, db.size)
end

local function reskinAll()
    for _, btn in ipairs(collected) do applySkin(btn) end
    if toggle then applySkin(toggle) end
    -- Re-show Masque's layers (they're hidden, not removed, when we leave Masque).
    if chosenSkin() == "masque" and MasqueGroup and MasqueGroup.ReSkin then
        pcall(function() MasqueGroup:ReSkin() end)
    end
end

local function resizeAll()
    local skin = chosenSkin()
    local plain = skin == "default"
    for _, btn in ipairs(collected) do
        setSize(btn, db.size)
        if plain then actionBarSkin(btn, btn.__mbcIcon) end
    end
    if toggle then
        setSize(toggle, db.size)
        if plain then actionBarSkin(toggle, toggle.icon) end
    end
    if skin == "masque" and MasqueGroup then pcall(function() MasqueGroup:ReSkin() end) end
end

-- Masque can't be cleanly un-skinned at runtime (its RemoveButton just applies
-- a default skin), so leaving the Masque profile is finished with a UI reload,
-- which guarantees a clean result. Other switches apply instantly.
StaticPopupDialogs["MINIMAPICONBAR_RELOAD"] = {
    text = "Minimap Icon Bar: switching away from Masque needs a UI reload to fully clear Masque's skin. Reload now?",
    button1 = "Reload now",
    button2 = "Later",
    OnAccept = function() ReloadUI() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- ===========================================================================
-- Lock owning addon out of moving / reparenting / resizing
-- ===========================================================================
local function lockButton(btn)
    if btn.__mbcLocked then return end
    btn.__mbcLocked = true
    btn.__mbcOrigSetPoint  = btn.SetPoint
    btn.__mbcOrigSetParent = btn.SetParent
    btn.__mbcOrigSetSize   = btn.SetSize
    local noop = function() end
    btn.SetPoint, btn.SetParent, btn.SetSize = noop, noop, noop
    -- Block the standard move API so an owning addon's own drag can never shift
    -- the button (our reorder moves it via the saved original SetPoint instead).
    if btn.StartMoving then btn.StartMoving = noop end
    if btn.StopMovingOrSizing then btn.__mbcOrigStopMoving = btn.StopMovingOrSizing; btn.StopMovingOrSizing = noop end

    -- Track when the owning addon hides/shows its own button (e.g. you toggle it
    -- off in that addon's settings) so we can drop it from the row. Our own
    -- open/close toggling is wrapped in internalToggle and ignored here.
    hooksecurefunc(btn, "Hide", function()
        if internalToggle or dragBtn == btn then return end
        if not btn.__mbcOwnerHidden then btn.__mbcOwnerHidden = true; requestRelayout() end
    end)
    hooksecurefunc(btn, "Show", function()
        if internalToggle or dragBtn == btn then return end
        if btn.__mbcOwnerHidden then btn.__mbcOwnerHidden = false; requestRelayout() end
    end)
    btn.__mbcOwnerHidden = (not btn:IsShown()) and true or nil

    -- Drag-to-reorder (active only when the bar is unlocked). A click still
    -- works normally; only a press-and-drag triggers a reorder. We take over the
    -- drag scripts entirely (SetScript, not hook) so the owning addon's own
    -- drag/reposition routine can't run and fight us.
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function(self) if onBtnDragStart then onBtnDragStart(self) end end)
    btn:SetScript("OnDragStop",  function(self) if onBtnDragStop  then onBtnDragStop(self)  end end)
end

-- ===========================================================================
-- Layout - toggle is slot #1, collected icons follow when open
-- ===========================================================================
-- The bar is anchored by its GROWTH corner (where the M sits) so the M stays
-- put and the row only grows in the hard-linked direction.
local function growthAnchorCorner()
    local g = db.growth or "DOWN_RIGHT"
    return (g == "DOWN_RIGHT" and "TOPLEFT")
        or (g == "DOWN_LEFT"  and "TOPRIGHT")
        or (g == "UP_RIGHT"   and "BOTTOMLEFT")
        or "BOTTOMRIGHT"
end

local function anchorBar()
    if not bar then return end
    local s = db.scale or 1.0
    if s <= 0 then s = 1.0 end
    bar:ClearAllPoints()
    -- db.x/db.y are stored in UIParent units; dividing by the bar's own scale
    -- keeps the growth corner fixed on screen when the scale changes.
    bar:SetPoint(growthAnchorCorner(), UIParent, "CENTER", (db.x or 0) / s, (db.y or 0) / s)
end

function layout()
    if not bar then return end

    local items = { toggle }
    if db.isOpen then
        for _, b in ipairs(collected) do
            if not b.__mbcOwnerHidden then items[#items + 1] = b end
        end
    end
    internalToggle = true
    for _, b in ipairs(collected) do
        if db.isOpen and not b.__mbcOwnerHidden then b:Show() else b:Hide() end
    end
    internalToggle = false

    local n      = #items
    local size   = db.size or 32
    local sp     = math.max(0, db.spacing or 0)
    local perRow = math.max(1, db.buttonsPerRow or 6)
    local growth = db.growth or "DOWN_RIGHT"
    local horiz  = growth:find("RIGHT") and 1 or -1
    local vert   = growth:find("UP")    and 1 or -1
    -- Same growth-corner mapping anchorBar() uses, so the M stays put as the row grows.
    local anchor = growthAnchorCorner()

    for i, btn in ipairs(items) do
        local idx = i - 1
        local col = idx % perRow
        local row = math.floor(idx / perRow)
        local ox  = size / 2 + col * (size + sp)
        local oy  = size / 2 + row * (size + sp)
        setPoint(btn, "CENTER", bar, anchor, horiz * ox, vert * oy)
    end

    -- Bar exactly bounds the grid - no overhang.
    local cols = math.min(n, perRow)
    local rows = math.ceil(n / perRow)
    local w = cols * size + math.max(0, cols - 1) * sp
    local h = rows * size + math.max(0, rows - 1) * sp
    bar:SetSize(math.max(w, size), math.max(h, size))
    anchorBar()
end

-- ===========================================================================
-- Drag-to-reorder
-- ===========================================================================
local function buttonId(btn)
    return btn and btn.GetName and btn:GetName() or nil
end

-- Reordering is allowed whenever the bar is movable (same rule as dragging it).
function reorderEnabled()
    return canMove()
end

-- Reorder `collected` to match the saved name order; unknown buttons keep their
-- current relative order after the known ones.
function applyOrder()
    if not db.order or #db.order == 0 then return end
    local rank = {}
    for i, name in ipairs(db.order) do rank[name] = i end
    local deco = {}
    for i, b in ipairs(collected) do
        deco[i] = { b = b, i = i, r = rank[buttonId(b) or ""] }
    end
    table.sort(deco, function(a, c)
        if a.r and c.r then return a.r < c.r end
        if a.r then return true end
        if c.r then return false end
        return a.i < c.i
    end)
    wipe(collected)
    for i, t in ipairs(deco) do collected[i] = t.b end
end

-- Save the current order (named buttons) to the profile.
function captureOrder()
    local list = {}
    for _, b in ipairs(collected) do
        local id = buttonId(b)
        if id then list[#list + 1] = id end
    end
    db.order = list
end

function onBtnDragStart(self)
    if not reorderEnabled() then return end
    dragBtn = self
    internalToggle = true; self:Show(); internalToggle = false   -- keep it visible
    self.__mbcStrata = self:GetFrameStrata()
    self.__mbcLevel  = self:GetFrameLevel()
    self:SetFrameStrata("TOOLTIP")
    self:SetToplevel(true)
    self:Raise()
    self:SetAlpha(0.8)
    dragUpdater:Show()
end

function onBtnDragStop(self)
    if dragBtn ~= self then return end
    dragUpdater:Hide()
    dragBtn = nil
    self:SetAlpha(1)
    self:SetToplevel(false)
    if self.__mbcStrata then self:SetFrameStrata(self.__mbcStrata) end
    if self.__mbcLevel then self:SetFrameLevel(self.__mbcLevel) end

    local mx, my = GetCursorPosition()
    local function centerDist(f)
        local s = f:GetEffectiveScale()
        local cx, cy = f:GetCenter()
        if not cx then return math.huge, 0, 0 end
        cx, cy = cx * s, cy * s
        return (cx - mx) ^ 2 + (cy - my) ^ 2, cx, cy
    end

    -- Remove the dragged button, then find where to drop it.
    local from
    for i, b in ipairs(collected) do if b == self then from = i; break end end
    if from then table.remove(collected, from) end

    -- Toggle is the "front" drop target.
    local bestB, bestD = nil, select(1, centerDist(toggle))
    local dropFront = true
    for _, b in ipairs(collected) do
        if not b.__mbcOwnerHidden then
            local d = centerDist(b)
            if d < bestD then bestD, bestB, dropFront = d, b, false end
        end
    end

    local insertAt
    if dropFront or not bestB then
        insertAt = 1
    else
        local idx
        for i, b in ipairs(collected) do if b == bestB then idx = i; break end end
        local _, cx = centerDist(bestB)
        local horiz = (db.growth or ""):find("RIGHT") and 1 or -1
        insertAt = idx + (((mx - cx) * horiz > 0) and 1 or 0)
    end
    insertAt = math.max(1, math.min(insertAt, #collected + 1))
    table.insert(collected, insertAt, self)

    captureOrder()
    layout()
end

-- Change the skin profile (defined after layout so both are available).
local function applySkinChoice(newStyle)
    local prev = chosenSkin()
    db.skinStyle = newStyle
    reskinAll(); layout()
    if config and config.Refresh and config:IsShown() then config.Refresh() end
    if prev == "masque" and chosenSkin() ~= "masque" then
        StaticPopup_Show("MINIMAPICONBAR_RELOAD")
    end
end

-- ===========================================================================
-- Collection
-- ===========================================================================
local function scanMinimap()
    -- Reparenting a button during combat can trip the protected-frame guard, so
    -- defer collection until combat ends (PLAYER_REGEN_ENABLED runs it then).
    if InCombatLockdown and InCombatLockdown() then
        pendingScan = true
        return false
    end
    local containers = { Minimap }
    if MinimapBackdrop then containers[#containers + 1] = MinimapBackdrop end
    local found = false
    for _, container in ipairs(containers) do
        local children = { container:GetChildren() }
        for _, child in ipairs(children) do
            if child ~= toggle and child ~= bar and not isCollected[child] and shouldCollect(child) then
                isCollected[child] = true
                collected[#collected + 1] = child
                squareButton(child)
                child:SetParent(bar)
                lockButton(child)
                found = true
            end
        end
    end
    if found then applyOrder(); layout() end
    return found
end

-- Drop buttons that have gone away (frame destroyed, or an addon reparented it
-- back off our bar) and compact the list so no empty slot is left behind.
-- Returns the number removed.
local function pruneCollected()
    local kept, removed = {}, 0
    for _, b in ipairs(collected) do
        local valid = type(b) == "table" and b.IsObjectType and b:IsObjectType("Frame")
            and b.GetParent and b:GetParent() == bar
        if valid then
            kept[#kept + 1] = b
        else
            removed = removed + 1
            if b then isCollected[b] = nil end
        end
    end
    if removed > 0 then
        wipe(collected)
        for i, b in ipairs(kept) do collected[i] = b end
    end
    return removed
end

-- Full cleanup: pick up new buttons, drop removed ones, re-flow the bar.
-- Returns added, removed counts.
local function refreshBar()
    local removed = pruneCollected()
    local found   = scanMinimap()   -- lays out if it added anything
    if removed > 0 and not found then layout() end
    return found, removed
end

-- Watch for buttons appearing/disappearing while playing (e.g. enabling an
-- addon) and refresh automatically. Cheap: scanMinimap skips already-collected
-- buttons, so a tick only does real work when something actually changed.
local refreshTicker
local function startAutoRefresh()
    if refreshTicker then return end
    -- Polling backstop, 5s: catches buttons from addons that build their frame
    -- on toggle (not just at load). The common case (LibDBIcon) is picked up
    -- instantly by the callback below, so this only covers rare non-LDB addons.
    refreshTicker = C_Timer.NewTicker(5, function()
        if InCombatLockdown and InCombatLockdown() then return end
        refreshBar()
    end)

    -- Fast path: LibDBIcon fires this the instant it creates a button, including
    -- when you enable a previously-hidden icon in its owning addon's options.
    local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if LDBIcon and LDBIcon.RegisterCallback then
        LDBIcon.RegisterCallback({}, "LibDBIcon_IconCreated", function()
            C_Timer.After(0, function()
                if not (InCombatLockdown and InCombatLockdown()) then refreshBar() end
            end)
        end)
    end
end

-- ===========================================================================
-- Open / close
-- ===========================================================================
local function setOpen(open)
    if db.lockOpen then open = true end
    db.isOpen = open and true or false
    if db.isOpen then scanMinimap() end
    layout()
end
local function toggleOpen()
    if db.lockOpen then return end   -- locked open: clicking won't collapse it
    setOpen(not db.isOpen)
end

-- ===========================================================================
-- Position
-- ===========================================================================
-- Record the growth corner's offset from screen centre (after a drag), in
-- UIParent units so it's independent of the bar's own scale.
local function savePosition()
    local gA = growthAnchorCorner()
    local bScale = bar:GetEffectiveScale()
    local uScale = UIParent:GetEffectiveScale()
    local cx = (gA:find("LEFT") and (bar:GetLeft() or 0) or (bar:GetRight() or 0)) * bScale
    local cy = (gA:find("TOP")  and (bar:GetTop()  or 0) or (bar:GetBottom() or 0)) * bScale
    local ucx, ucy = UIParent:GetCenter()
    db.x = (cx - ucx * uScale) / uScale
    db.y = (cy - ucy * uScale) / uScale
    anchorBar()
end
local function restorePosition()
    anchorBar()
end

-- ===========================================================================
-- Apply everything
-- ===========================================================================
local function applyAll()
    if db.lockOpen then db.isOpen = true end
    bar:SetScale(db.scale or 1.0)
    restorePosition()
    reskinAll()
    layout()
    if config and config.Refresh and config:IsShown() then config.Refresh() end
end

local function resetSettings()
    for k, v in pairs(DEFAULTS) do
        if type(v) == "table" then
            local copy = {}; for i, vv in ipairs(v) do copy[i] = vv end; db[k] = copy
        else
            db[k] = v
        end
    end
    applyAll()
    msg("settings reset.")
end

-- ===========================================================================
-- Profiles (per-character by default; named profiles can be shared)
-- ===========================================================================
local function profileNames()
    local t = {}
    if store and store.profiles then
        for name in pairs(store.profiles) do t[#t + 1] = name end
    end
    table.sort(t)
    return t
end

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local r = {}
    for k, vv in pairs(v) do r[k] = deepCopy(vv) end
    return r
end

-- Switch this character to a profile (creating it from defaults if new).
local function activateProfile(name)
    if not name or name == "" then return end
    local prevSkin = chosenSkin()
    store.profiles[name] = store.profiles[name] or {}
    fillDefaults(store.profiles[name])
    store.chars[charKey] = name
    activeProfile = name
    db = store.profiles[name]          -- shared upvalue: all functions follow
    applyAll()
    if configProfiles and configProfiles.Refresh then configProfiles.Refresh() end
    if config and config.Refresh and config:IsShown() then config.Refresh() end
    if prevSkin == "masque" and chosenSkin() ~= "masque" then
        StaticPopup_Show("MINIMAPICONBAR_RELOAD")
    end
end

local function copyCurrentProfile(name)
    if not name or name == "" then return end
    store.profiles[name] = deepCopy(db)
    activateProfile(name)
    msg("copied to profile '" .. name .. "'.")
end

local function deleteProfile(name)
    name = name or activeProfile
    if not name then return end
    store.profiles[name] = nil
    for c, p in pairs(store.chars) do
        if p == name then store.chars[c] = nil end
    end
    if activeProfile == name then
        local fallback
        for n in pairs(store.profiles) do fallback = n; break end
        activateProfile(fallback or charKey)
    elseif configProfiles and configProfiles.Refresh then
        configProfiles.Refresh()
    end
    msg("deleted profile '" .. name .. "'.")
end

StaticPopupDialogs["MINIMAPICONBAR_DELPROFILE"] = {
    text = "Delete the current Minimap Icon Bar profile?", button1 = "Delete", button2 = "Cancel",
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    OnAccept = function() deleteProfile(activeProfile) end,
}

-- ===========================================================================
-- Frames
-- ===========================================================================
local function buildFrames()
    bar = CreateFrame("Frame", "MinimapIconBarFrame", UIParent)
    bar:SetSize(db.size, db.size)
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)

    -- Highlight shown during Edit Mode when the bar is set to "Only in Edit Mode".
    local hl = bar:CreateTexture(nil, "OVERLAY")
    hl:SetAllPoints(bar)
    hl:SetColorTexture(1, 0.82, 0, 0.25)
    hl:Hide()
    bar.editHighlight = hl

    toggle = CreateFrame("Button", "MinimapIconBarButton", bar)
    toggle:SetSize(db.size, db.size)
    toggle:SetMovable(true)
    toggle:RegisterForDrag("LeftButton")
    toggle:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local icon = toggle:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(toggle)
    icon:SetTexture("Interface\\AddOns\\MinimapIconBar\\logo")
    toggle.icon = icon

    toggle:SetScript("OnDragStart", function() if canMove() then bar:StartMoving() end end)
    toggle:SetScript("OnDragStop", function() bar:StopMovingOrSizing(); savePosition() end)
    toggle:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            toggleOptions()
        else
            toggleOpen()
        end
    end)
    toggle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Minimap Icon Bar")
        GameTooltip:AddLine("Left-click: open / close", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Right-click: options", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Drag: move", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    toggle:SetScript("OnLeave", function() GameTooltip:Hide() end)

    squareButton(toggle)
end

-- ===========================================================================
-- Options (registered into the Blizzard Settings panel)
-- ===========================================================================
local function makeSlider(name, parent, lo, hi, step, x, y, onChange, fmt)
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", x, y)
    s:SetWidth(220)
    s:SetMinMaxValues(lo, hi)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)
    -- These named child regions exist on OptionsSliderTemplate, but guard them:
    -- if Blizzard swaps the template (the 12.0 slider revamp), a missing region
    -- must not nil-error and take the whole options panel down with it.
    local lowText  = _G[name .. "Low"]
    local highText = _G[name .. "High"]
    local valText  = _G[name .. "Text"]
    if lowText  then lowText:SetText(tostring(lo)) end
    if highText then highText:SetText(tostring(hi)) end
    s:SetScript("OnValueChanged", function(_, value)
        value = onChange(value)
        if valText then valText:SetText(fmt(value)) end
    end)
    return s
end

local function buildConfig()
    config = CreateFrame("Frame", "MinimapIconBarOptionsPanel")
    config:Hide()

    local title = config:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Minimap Icon Bar")

    local scale = makeSlider("MinimapIconBarScaleSlider", config, 0.5, 2.0, 0.05, 24, -64,
        function(v) v = math.floor(v * 20 + 0.5) / 20; db.scale = v; bar:SetScale(v); anchorBar(); return v end,
        function(v) return ("Scale: %.2f"):format(v) end)

    local size = makeSlider("MinimapIconBarSizeSlider", config, 16, 48, 1, 24, -112,
        function(v) v = math.floor(v + 0.5); db.size = v; resizeAll(); layout(); return v end,
        function(v) return "Button size: " .. v .. " px" end)

    local spacing = makeSlider("MinimapIconBarSpacingSlider", config, 0, 16, 1, 24, -160,
        function(v) v = math.floor(v + 0.5); db.spacing = v; layout(); return v end,
        function(v) return "Spacing: " .. v .. " px" end)

    local perRow = makeSlider("MinimapIconBarPerRowSlider", config, 1, 12, 1, 24, -208,
        function(v) v = math.floor(v + 0.5); db.buttonsPerRow = v; layout(); return v end,
        function(v) return "Buttons per row (incl. the M icon): " .. v end)

    local growthLabel = config:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    growthLabel:SetPoint("TOPLEFT", 24, -250)
    growthLabel:SetText("Growth direction")

    local growth = CreateFrame("Frame", "MinimapIconBarGrowthDropDown", config, "UIDropDownMenuTemplate")
    growth:SetPoint("TOPLEFT", 8, -265)
    local function onPick(self)
        db.growth = self.value
        UIDropDownMenu_SetSelectedValue(growth, self.value)
        UIDropDownMenu_SetText(growth, GROWTH_TEXT[self.value])
        layout()
    end
    UIDropDownMenu_Initialize(growth, function()
        for _, value in ipairs(GROWTH_ORDER) do
            local info = UIDropDownMenu_CreateInfo()
            info.text, info.value, info.func = GROWTH_TEXT[value], value, onPick
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetWidth(growth, 180)

    -- Movement -------------------------------------------------------------
    local moveLabel = config:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    moveLabel:SetPoint("TOPLEFT", 24, -308)
    moveLabel:SetText("Movement")

    local move = CreateFrame("Frame", "MinimapIconBarMoveDropDown", config, "UIDropDownMenuTemplate")
    move:SetPoint("TOPLEFT", 8, -323)
    local function onMovePick(self)
        db.lockMode = self.value
        UIDropDownMenu_SetSelectedValue(move, self.value)
        UIDropDownMenu_SetText(move, LOCK_TEXT[self.value])
        updateEditHighlight()
    end
    UIDropDownMenu_Initialize(move, function()
        for _, value in ipairs(LOCK_ORDER) do
            local info = UIDropDownMenu_CreateInfo()
            info.text, info.value, info.func = LOCK_TEXT[value], value, onMovePick
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetWidth(move, 180)

    -- Lock open ------------------------------------------------------------
    local lockOpen = CreateFrame("CheckButton", "MinimapIconBarLockOpenCheck", config, "InterfaceOptionsCheckButtonTemplate")
    lockOpen:SetPoint("TOPLEFT", 24, -364)
    _G["MinimapIconBarLockOpenCheckText"]:SetText("Lock open (stay expanded; click won't close it)")
    lockOpen:SetScript("OnClick", function(self)
        db.lockOpen = self:GetChecked() and true or false
        if db.lockOpen then setOpen(true) end
        layout()
    end)
    config.lockOpenCheck = lockOpen

    -- Skin profile --------------------------------------------------------
    local skinLabel = config:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    skinLabel:SetPoint("TOPLEFT", 24, -400)
    skinLabel:SetText("Skin profile")

    local skin = CreateFrame("Frame", "MinimapIconBarSkinDropDown", config, "UIDropDownMenuTemplate")
    skin:SetPoint("TOPLEFT", 8, -415)
    local function onSkinPick(self)
        UIDropDownMenu_SetSelectedValue(skin, self.value)
        UIDropDownMenu_SetText(skin, SKIN_TEXT[self.value])
        applySkinChoice(self.value)
    end
    UIDropDownMenu_Initialize(skin, function()
        for _, value in ipairs(SKIN_ORDER) do
            local info = UIDropDownMenu_CreateInfo()
            info.text, info.value, info.func = SKIN_TEXT[value], value, onSkinPick
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetWidth(skin, 260)

    local skinNote = config:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    skinNote:SetPoint("TOPLEFT", 26, -452)

    local rescan = CreateFrame("Button", nil, config, "UIPanelButtonTemplate")
    rescan:SetSize(110, 22)
    rescan:SetPoint("TOPLEFT", 24, -484)
    rescan:SetText("Clean up")
    rescan:SetScript("OnClick", function()
        local found, removed = refreshBar()
        if found or removed > 0 then
            msg(("cleaned up (%s added, %d removed)."):format(found and "new" or "0", removed))
        else
            msg("nothing to clean up.")
        end
    end)

    local reset = CreateFrame("Button", nil, config, "UIPanelButtonTemplate")
    reset:SetSize(110, 22)
    reset:SetPoint("LEFT", rescan, "RIGHT", 12, 0)
    reset:SetText("Reset")
    reset:SetScript("OnClick", resetSettings)

    local reorderNote = config:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    reorderNote:SetPoint("TOPLEFT", 24, -518)
    reorderNote:SetText("|cff999999Tip: when the bar is unlocked, drag the M to move it, and drag icons to reorder them.|r")

    function config.Refresh()
        scale:SetValue(db.scale or 1.0)
        size:SetValue(db.size or 32)
        spacing:SetValue(db.spacing or 2)
        perRow:SetValue(db.buttonsPerRow or 6)
        UIDropDownMenu_SetSelectedValue(growth, db.growth or "DOWN_RIGHT")
        UIDropDownMenu_SetText(growth, GROWTH_TEXT[db.growth or "DOWN_RIGHT"])
        UIDropDownMenu_SetSelectedValue(move, db.lockMode or "unlocked")
        UIDropDownMenu_SetText(move, LOCK_TEXT[db.lockMode or "unlocked"])
        lockOpen:SetChecked(db.lockOpen and true or false)
        UIDropDownMenu_SetSelectedValue(skin, db.skinStyle or "auto")
        UIDropDownMenu_SetText(skin, SKIN_TEXT[db.skinStyle or "auto"])
        local active = chosenSkin()
        local activeText = (active == "masque" and "Masque")
            or (active == "elvui" and "ElvUI")
            or "default WoW action bar"
        local note = "Currently showing: " .. activeText .. "."
        if db.skinStyle == "masque" and not MasqueGroup then
            note = note .. " (Masque not installed)"
        elseif db.skinStyle == "elvui" and not (ELVUI and E) then
            note = note .. " (ElvUI not installed)"
        end
        skinNote:SetText(note)
    end

    config:SetScript("OnShow", function() config.Refresh() end)

    -- Register into the standard Blizzard Settings panel.
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(config, "Minimap Icon Bar")
        Settings.RegisterAddOnCategory(category)
        optionsCategory = category
    end
end

-- A "Profiles" subpage under the main options category.
local function buildProfileConfig()
    configProfiles = CreateFrame("Frame", "MinimapIconBarProfilesPanel")
    configProfiles:Hide()

    local title = configProfiles:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Minimap Icon Bar - Profiles")

    local desc = configProfiles:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 18, -44)
    desc:SetText("Each character uses its own profile by default. Create named profiles to share settings across characters.")

    local curLabel = configProfiles:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    curLabel:SetPoint("TOPLEFT", 24, -78)
    curLabel:SetText("Active profile")

    local dd = CreateFrame("Frame", "MinimapIconBarProfileDropDown", configProfiles, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", 8, -93)
    UIDropDownMenu_Initialize(dd, function()
        for _, name in ipairs(profileNames()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text, info.value = name, name
            info.func = function(self) activateProfile(self.value) end
            info.checked = (name == activeProfile)
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetWidth(dd, 220)

    local nameLabel = configProfiles:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", 24, -136)
    nameLabel:SetText("New profile name")

    local nameBox = CreateFrame("EditBox", "MinimapIconBarProfileNameBox", configProfiles, "InputBoxTemplate")
    nameBox:SetSize(220, 20)
    nameBox:SetPoint("TOPLEFT", 28, -152)
    nameBox:SetAutoFocus(false)
    nameBox:SetMaxLetters(40)
    nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local function takeName()
        local n = nameBox:GetText()
        if n then n = n:gsub("^%s+", ""):gsub("%s+$", "") end
        return n
    end

    local createBtn = CreateFrame("Button", nil, configProfiles, "UIPanelButtonTemplate")
    createBtn:SetSize(120, 22)
    createBtn:SetPoint("TOPLEFT", 24, -182)
    createBtn:SetText("Create new")
    createBtn:SetScript("OnClick", function()
        local n = takeName()
        if n and n ~= "" then
            activateProfile(n)
            nameBox:SetText(""); nameBox:ClearFocus()
        end
    end)

    local copyBtn = CreateFrame("Button", nil, configProfiles, "UIPanelButtonTemplate")
    copyBtn:SetSize(120, 22)
    copyBtn:SetPoint("LEFT", createBtn, "RIGHT", 12, 0)
    copyBtn:SetText("Copy current")
    copyBtn:SetScript("OnClick", function()
        local n = takeName()
        if n and n ~= "" then
            copyCurrentProfile(n)
            nameBox:SetText(""); nameBox:ClearFocus()
        end
    end)
    nameBox:SetScript("OnEnterPressed", function(self)
        local n = takeName()
        if n and n ~= "" then activateProfile(n); self:SetText(""); self:ClearFocus() end
    end)

    local delBtn = CreateFrame("Button", nil, configProfiles, "UIPanelButtonTemplate")
    delBtn:SetSize(120, 22)
    delBtn:SetPoint("TOPLEFT", createBtn, "BOTTOMLEFT", 0, -16)
    delBtn:SetText("Delete current")
    delBtn:SetScript("OnClick", function() StaticPopup_Show("MINIMAPICONBAR_DELPROFILE") end)

    function configProfiles.Refresh()
        UIDropDownMenu_SetSelectedValue(dd, activeProfile)
        UIDropDownMenu_SetText(dd, activeProfile or "Default")
    end
    configProfiles:SetScript("OnShow", function() configProfiles.Refresh() end)

    if optionsCategory and Settings and Settings.RegisterCanvasLayoutSubcategory then
        Settings.RegisterCanvasLayoutSubcategory(optionsCategory, configProfiles, "Profiles")
    end
end

-- ===========================================================================
-- Slash commands
-- ===========================================================================
SLASH_MINIMAPICONBAR1 = "/mib"
SLASH_MINIMAPICONBAR2 = "/minimapiconbar"
SlashCmdList["MINIMAPICONBAR"] = function(input)
    input = (input or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, arg = input:match("^(%S*)%s*(.-)$")

    if cmd == "" or cmd == "config" or cmd == "options" then
        toggleOptions()
    elseif cmd == "toggle" then
        toggleOpen()
    elseif cmd == "lockopen" then
        db.lockOpen = (arg == "on" or arg == "1" or arg == "true")
        if db.lockOpen then setOpen(true) else layout() end
        msg("lock open " .. (db.lockOpen and "on" or "off"))
    elseif cmd == "rescan" or cmd == "cleanup" then
        local found, removed = refreshBar()
        msg(("cleaned up (%s added, %d removed)."):format(found and "new" or "0", removed))
    elseif cmd == "reset" then
        resetSettings()
    elseif cmd == "lock" then
        db.lockMode = "locked"; updateEditHighlight()
        msg("locked.")
    elseif cmd == "unlock" then
        db.lockMode = "unlocked"; updateEditHighlight()
        msg("unlocked.")
    elseif cmd == "move" then
        local v = arg:lower()
        if LOCK_TEXT[v] then db.lockMode = v; updateEditHighlight()
            msg("movement = " .. LOCK_TEXT[v])
        else print("Usage: /mib move unlocked | locked | editmode") end
    elseif cmd == "skin" then
        local v = arg:lower()
        if SKIN_TEXT[v] then
            applySkinChoice(v)
            msg("skin profile = " .. SKIN_TEXT[v])
        else
            print("Usage: /mib skin auto | default | elvui | masque")
        end
    elseif cmd == "profile" then
        local sub, pname = arg:match("^(%S*)%s*(.-)$")
        sub = (sub or ""):lower()
        if sub == "" or sub == "list" then
            print(PREFIX .. " profiles (active: |cffffff00" .. tostring(activeProfile) .. "|r):")
            for _, n in ipairs(profileNames()) do print("  " .. n) end
            print("Usage: /mib profile set|new|copy|delete NAME")
        elseif sub == "set" and pname ~= "" then
            activateProfile(pname)
            msg("active profile = " .. pname)
        elseif sub == "new" and pname ~= "" then
            activateProfile(pname)
            msg("created profile = " .. pname)
        elseif sub == "copy" and pname ~= "" then
            copyCurrentProfile(pname)
        elseif sub == "delete" and pname ~= "" then
            deleteProfile(pname)
        else
            print("Usage: /mib profile set|new|copy|delete NAME  (or 'list')")
        end
    elseif cmd == "dump" then
        print(PREFIX .. " dump (" .. #collected .. " buttons):")
        local function dumpRegions(frame, prefix)
            local num = (frame.GetNumRegions and frame:GetNumRegions()) or 0
            for i = 1, num do
                local r = select(i, frame:GetRegions())
                if r and r.IsObjectType and r:IsObjectType("Texture") then
                    print(("%s[%s] %s (%dpx) a=%.1f shown=%s"):format(prefix,
                        tostring(r:GetDrawLayer()), tostring(r:GetTexture()),
                        math.floor((r:GetWidth() or 0) + 0.5), r:GetAlpha() or 0,
                        tostring(r:IsShown())))
                end
            end
        end
        for _, b in ipairs(collected) do
            print("|cffffff00" .. ((b.GetName and b:GetName()) or "<unnamed>") .. "|r")
            dumpRegions(b, "  ")
            if b.GetChildren then
                for _, sub in ipairs({ b:GetChildren() }) do dumpRegions(sub, "  >child ") end
            end
        end
    elseif cmd == "inspect" then
        local f
        if GetMouseFoci then local t = GetMouseFoci(); f = t and t[1]
        elseif GetMouseFocus then f = GetMouseFocus() end
        if not f then msg("hover the button, then run /mib inspect."); return end
        print(PREFIX .. " inspect: |cffffff00" .. (f.GetName and f:GetName() or "<unnamed>") .. "|r")
        if f.GetNumRegions then
            for i = 1, f:GetNumRegions() do
                local r = select(i, f:GetRegions())
                if r and r.IsObjectType and r:IsObjectType("Texture") then
                    print(("  [%s] %s  (%dpx)"):format(tostring(r:GetDrawLayer()),
                        tostring(r:GetTexture()), math.floor((r:GetWidth() or 0) + 0.5)))
                end
            end
        end
    elseif cmd == "restrip" then
        for _, b in ipairs(collected) do b.__mbcPrepared = nil; squareButton(b) end
        if toggle then toggle.__mbcPrepared = nil; squareButton(toggle) end
        layout()
        msg("re-stripped all buttons.")
    elseif cmd == "scale" then
        local v = tonumber(arg)
        if v then db.scale = math.max(0.5, math.min(2.0, v)); bar:SetScale(db.scale); anchorBar()
            msg("scale = " .. db.scale)
        else print("Usage: /mib scale 1.0") end
    elseif cmd == "size" then
        local v = tonumber(arg)
        if v then db.size = math.max(12, math.min(64, math.floor(v))); resizeAll(); layout()
            msg("button size = " .. db.size .. " px")
        else print("Usage: /mib size 32") end
    elseif cmd == "spacing" then
        local v = tonumber(arg)
        if v then db.spacing = math.max(0, math.min(32, math.floor(v))); layout()
            msg("spacing = " .. db.spacing .. " px")
        else print("Usage: /mib spacing 0") end
    elseif cmd == "perrow" then
        local v = tonumber(arg)
        if v then db.buttonsPerRow = math.max(1, math.min(12, math.floor(v))); layout()
            msg("buttons per row = " .. db.buttonsPerRow)
        else print("Usage: /mib perrow 6") end
    elseif cmd == "growth" then
        local v = arg:upper()
        if GROWTH_TEXT[v] then db.growth = v; layout()
            msg("growth = " .. GROWTH_TEXT[v])
        else print("Usage: /mib growth down_right | down_left | up_right | up_left") end
    else
        print(PREFIX .. " commands:")
        print("  /mib            - open options (Blizzard settings)")
        print("  /mib toggle     - open/close")
        print("  /mib lockopen on|off - keep the bar expanded")
        print("  /mib scale N    - whole-bar scale 0.5-2.0")
        print("  /mib size N     - button size in px")
        print("  /mib spacing N  - gap in px (0 = flush)")
        print("  /mib perrow N   - buttons per row 1-12 (incl. the M icon)")
        print("  /mib growth DIR - down_right|down_left|up_right|up_left")
        print("  /mib move unlocked|locked|editmode")
        print("  (unlock the bar, then drag icons to reorder them)")
        print("  /mib skin auto|default|elvui|masque")
        print("  /mib profile set|new|copy|delete NAME")
        print("  /mib inspect, dump, restrip, lock, unlock, cleanup, reset")
    end
end

-- ===========================================================================
-- Addon Compartment (the dropdown by the minimap clock)
-- ===========================================================================
function MinimapIconBarCompartmentOnClick(addonName, arg2, arg3)
    local mb = arg2
    if mb ~= "LeftButton" and mb ~= "RightButton" then
        mb = (arg3 == "LeftButton" or arg3 == "RightButton") and arg3 or "LeftButton"
    end
    if mb == "RightButton" then
        toggleOptions()
    else
        toggleOpen()
    end
end

function MinimapIconBarCompartmentOnEnter(addonName, menuButton)
    local owner = (type(menuButton) == "table" and menuButton) or _G.AddonCompartmentFrame or UIParent
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:AddLine("Minimap Icon Bar")
    GameTooltip:AddLine("Left-click: open / close", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click: options", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

function MinimapIconBarCompartmentOnLeave()
    GameTooltip:Hide()
end

-- ===========================================================================
-- Bootstrap
-- ===========================================================================
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if pendingScan then
            pendingScan = false
            scanMinimap()
            layout()
        end
        return
    end

    -- event == "PLAYER_LOGIN"
    MinimapIconBarDB = MinimapIconBarDB or { profiles = {}, chars = {} }
    store = MinimapIconBarDB
    store.profiles = store.profiles or {}
    store.chars    = store.chars or {}

    -- Each character uses its own profile by default; named profiles are shared.
    charKey = (UnitName("player") or "Unknown") .. " - " .. (GetRealmName() or "Realm")
    local name = store.chars[charKey] or charKey
    store.chars[charKey] = name
    store.profiles[name] = store.profiles[name] or {}
    activeProfile = name
    db = store.profiles[name]
    fillDefaults(db)

    if _G.ElvUI then
        local ok, engine = pcall(function() return _G.ElvUI[1] end)
        if ok and engine then E, ELVUI = engine, true end
    end

    if _G.LibStub then
        Masque = _G.LibStub("Masque", true)
        if Masque then
            local ok, group = pcall(function() return Masque:Group("Minimap Icon Bar") end)
            if ok and group then MasqueGroup = group end
        end
    end

    buildFrames()
    buildConfig()
    buildProfileConfig()
    applyAll()

    -- Edit Mode: enable dragging only while the HUD Edit Mode is open.
    if _G.EditModeManagerFrame then
        EditModeManagerFrame:HookScript("OnShow", function() inEditMode = true;  updateEditHighlight() end)
        EditModeManagerFrame:HookScript("OnHide", function() inEditMode = false; updateEditHighlight() end)
    end

    -- Pick up buttons deferred because we were in combat at the time.
    boot:RegisterEvent("PLAYER_REGEN_ENABLED")

    scanMinimap()
    for _, delay in ipairs({ 1, 3, 6, 10 }) do
        C_Timer.After(delay, function() scanMinimap(); layout() end)
    end
    startAutoRefresh()

    local skin = chosenSkin()
    local skinText = (skin == "masque" and " (Masque)")
        or (skin == "elvui" and " (ElvUI)")
        or " (default skin)"
    print(PREFIX .. " loaded" .. skinText .. ". Type |cffffff00/mib|r for options.")
end)
