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
    lockMode      = "unlocked",          -- "unlocked" | "locked"
    lockedOpen    = false,               -- open/closed state captured when locked
    skinStyle     = "auto",              -- "auto" | "default" | "elvui" | "masque"
    order         = {},                  -- saved icon order (list of button names)
    collectLandingPage = false,          -- opt-in: also grab Blizzard's expansion
                                         -- landing-page button (the Omnium Folio /
                                         -- renown button), normally left in place
}

local SKIN_ORDER = { "auto", "default", "elvui", "masque" }
local SKIN_TEXT  = {
    auto    = "Automatic (Masque/ElvUI if present)",
    default = "Default WoW action bar",
    elvui   = "ElvUI",
    masque  = "Masque",
}

local LOCK_ORDER = { "unlocked", "locked" }
local LOCK_TEXT  = {
    unlocked = "Unlocked (drag freely)",
    locked   = "Locked (position and open state)",
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
    if t.lockMode == "editmode" then t.lockMode = "unlocked" end   -- removed "Only in Edit Mode" mode
    t.locked = nil
    t.lockOpen = nil   -- removed "Lock open" option
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
-- Textures for the landing-page (Omnium Folio) button. Blizzard's own art is a
-- dynamic multi-layer atlas no skin can crop, so we hide it and draw our own two
-- layers instead: a silver FRAME (the managed icon - each skin frames/scales it)
-- with a transparent centre, and a grayscale ORB tinted to the player's class
-- colour, anchored behind the frame so it tracks under any skin. (Both .tga files
-- ship at the addon root.)
local LANDINGPAGE_FRAME = "Interface\\AddOns\\MinimapIconBar\\OmniumFolioFrame.tga"
local LANDINGPAGE_ORB   = "Interface\\AddOns\\MinimapIconBar\\OmniumFolioOrb.tga"

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
local pendingScan = false   -- a scan was requested during combat; run it after
local optionsCategory   -- Blizzard Settings category for this addon

local internalToggle = false   -- true while WE show/hide buttons (vs the owner)
local layout                   -- forward declaration (used by the hide/show hooks)
local applyOrder, captureOrder, reorderEnabled, onBtnDragStart, onBtnDragStop
local relayoutPending = false
local function runRelayout() relayoutPending = false; if layout then layout() end end
local function requestRelayout()
    if relayoutPending then return end
    relayoutPending = true
    C_Timer.After(0, runRelayout)   -- reuse one callback instead of a fresh closure
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

-- May the bar be dragged right now? (Only when fully unlocked.)
local function canMove()
    return ((db and db.lockMode) or "unlocked") == "unlocked"
end

-- ===========================================================================
-- Helpers
-- ===========================================================================
local function noop() end   -- shared no-op used to neutralize locked APIs
local function setSize(frame, s)  (frame.__mbcOrigSetSize  or frame.SetSize )(frame, s, s) end
local function setPoint(frame, ...) (frame.__mbcOrigSetPoint or frame.SetPoint)(frame, ...) end
-- Show/Hide through the originals when we've locked a frame's own Show/Hide (the
-- landing-page button, whose Blizzard updates would otherwise pulse its
-- visibility and churn a relayout every frame).
local function setShown(frame, shown)
    if shown then (frame.__mbcOrigShow or frame.Show)(frame)
    else (frame.__mbcOrigHide or frame.Hide)(frame) end
end

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

-- Once the expansion landing-page button has been reparented and re-skinned,
-- handing it back to Blizzard's minimap layout cleanly is impractical at
-- runtime, so turning the option off takes effect on a UI reload (it simply
-- isn't grabbed next login). Turning it on applies instantly.
StaticPopupDialogs["MINIMAPICONBAR_RELOAD_LANDINGPAGE"] = {
    text = "Minimap Icon Bar: releasing the expansion landing-page button needs a UI reload to restore it to the minimap. Reload now?",
    button1 = "Reload now",
    button2 = "Later",
    OnAccept = function() ReloadUI() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- ===========================================================================
-- Lock owning addon out of moving / reparenting / resizing
-- ===========================================================================
-- Handlers shared by every locked button, so locking allocates no per-button
-- closures. The hooks key off the passed frame (self), not a captured upvalue,
-- so one function serves all buttons. (noop is defined up in Helpers.)
local function btnOnHide(self)
    if internalToggle or dragBtn == self then return end
    if not self.__mbcOwnerHidden then self.__mbcOwnerHidden = true; requestRelayout() end
end
local function btnOnShow(self)
    if internalToggle or dragBtn == self then return end
    if self.__mbcOwnerHidden then self.__mbcOwnerHidden = false; requestRelayout() end
end
local function btnOnDragStart(self) if onBtnDragStart then onBtnDragStart(self) end end
local function btnOnDragStop(self)  if onBtnDragStop  then onBtnDragStop(self)  end end

local function lockButton(btn)
    if btn.__mbcLocked then return end
    btn.__mbcLocked = true
    btn.__mbcOrigSetPoint  = btn.SetPoint
    btn.__mbcOrigSetParent = btn.SetParent
    btn.__mbcOrigSetSize   = btn.SetSize
    btn.SetPoint, btn.SetParent, btn.SetSize = noop, noop, noop
    -- The landing-page button re-runs its own ClearAllPoints+SetPoint on events;
    -- with SetPoint noop'd, an open ClearAllPoints would strip our anchor and
    -- leave it point-less (invisible). Block it too - only that button needs it.
    if btn.__mbcLandingPage and btn.ClearAllPoints then btn.ClearAllPoints = noop end
    -- Blizzard re-applies its own scale / ignore-parent-scale to the landing-page
    -- button on events; lock both so it keeps the row scale we set.
    if btn.__mbcLandingPage and btn.SetScale then btn.SetScale = noop end
    if btn.__mbcLandingPage and btn.SetIgnoreParentScale then btn.SetIgnoreParentScale = noop end
    -- Block the standard move API so an owning addon's own drag can never shift
    -- the button (our reorder moves it via the saved original SetPoint instead).
    if btn.StartMoving then btn.StartMoving = noop end
    if btn.StopMovingOrSizing then btn.StopMovingOrSizing = noop end

    if btn.__mbcLandingPage then
        -- Blizzard pulses this button's own Show/Hide on its updates; left hooked,
        -- each toggle would fire a relayout every frame and burn idle CPU. Take its
        -- visibility over entirely - block Blizzard's Show/Hide and drive it through
        -- setShown (in layout) - so it never churns and can't linger on a closed bar.
        btn.__mbcOrigShow, btn.__mbcOrigHide = btn.Show, btn.Hide
        btn.Show, btn.Hide = noop, noop
    else
        -- Track when the owning addon hides/shows its own button (e.g. you toggle it
        -- off in that addon's settings) so we can drop it from the row. Our own
        -- open/close toggling is wrapped in internalToggle and ignored here.
        hooksecurefunc(btn, "Hide", btnOnHide)
        hooksecurefunc(btn, "Show", btnOnShow)
        btn.__mbcOwnerHidden = (not btn:IsShown()) and true or nil
    end

    -- Drag-to-reorder (active only when the bar is unlocked). A click still
    -- works normally; only a press-and-drag triggers a reorder. We take over the
    -- drag scripts entirely (SetScript, not hook) so the owning addon's own
    -- drag/reposition routine can't run and fight us.
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", btnOnDragStart)
    btn:SetScript("OnDragStop",  btnOnDragStop)
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

-- A button is a visible row member unless its owning addon hid it. The
-- landing-page button is Blizzard-managed and briefly hides itself during its
-- own updates, so it's always treated as a member (otherwise layout would skip
-- placing it and strand it on top of the row).
local function lpShown(b) return b.__mbcLandingPage or not b.__mbcOwnerHidden end

-- Reused on every layout() so re-flowing the bar allocates no garbage.
local layoutItems = {}

function layout()
    if not bar then return end

    local items = layoutItems
    wipe(items)
    items[1] = toggle
    if db.isOpen then
        for _, b in ipairs(collected) do
            if lpShown(b) then items[#items + 1] = b end
        end
    end
    internalToggle = true
    for _, b in ipairs(collected) do
        setShown(b, db.isOpen and lpShown(b))
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
-- Blizzard's expansion landing-page button (the Omnium Folio / renown button in
-- 12.0.7) doesn't fit the de-circle-and-reskin pipeline: its art is a dynamic,
-- multi-layer, state-dependent atlas no skin can crop. So we hide the native art
-- and draw our own icon - a silver frame (LANDINGPAGE_FRAME, the managed icon, so
-- every skin frames/scales it) plus a grayscale orb (LANDINGPAGE_ORB) tinted to
-- the player's class colour. The rest are Blizzard-specific fixups, each a
-- distinct symptom:
--   * reparent onto the bar - it sits at LOW strata under MinimapCluster, which
--     a child can't escape, so it always drew behind the MEDIUM bar icons;
--   * SetIgnoreParentScale(false) + match a sibling's scale - Blizzard has it
--     ignore parent scale, so it rendered huge and mis-placed (anchor offsets
--     are in the frame's own scaled units);
--   * lockButton - drag-to-reorder + lock SetPoint/SetParent/SetSize/SetScale/
--     ClearAllPoints/SetIgnoreParentScale, plus Show/Hide (Blizzard pulses its
--     visibility, which would otherwise churn a relayout every frame), so
--     Blizzard can't undo any of it.
-- __mbcLandingPage marks it for the prune/owner-hidden paths.
local function collectLandingPageButton()
    if not db.collectLandingPage then return false end
    local btn = _G.ExpansionLandingPageMinimapButton
    if not btn or btn == toggle or btn == bar or isCollected[btn] then return false end
    isCollected[btn] = true
    collected[#collected + 1] = btn
    btn.__mbcLandingPage = true
    if btn.ClearAllPoints then btn:ClearAllPoints() end
    if btn.SetParent then btn:SetParent(bar) end
    -- Blizzard sets this button to IGNORE its parent's scale, so on the bar it
    -- renders at full size regardless of the bar's scale ("massive"). Make it
    -- respect the parent, then match a row icon's own scale so it's sized like
    -- the row. lockButton locks both so Blizzard can't reset them.
    if btn.SetIgnoreParentScale then btn:SetIgnoreParentScale(false) end
    local refScale
    for _, sib in ipairs(collected) do
        if sib ~= btn and not sib.__mbcLandingPage and sib.GetScale then
            refScale = sib:GetScale(); break
        end
    end
    if btn.SetScale then btn:SetScale(refScale or 1) end
    if btn.SetFrameStrata then btn:SetFrameStrata(bar:GetFrameStrata()) end
    if btn.SetFrameLevel then btn:SetFrameLevel((bar:GetFrameLevel() or 1) + 10) end
    setSize(btn, db.size or 32)   -- size the frame to the row
    -- Hide Blizzard's native art (a dynamic multi-layer atlas no skin can crop)
    -- and draw our own two layers: a silver frame as the managed icon (so every
    -- skin frames/scales it like a normal addon icon) and a grayscale orb behind
    -- it, tinted to the player's class colour and anchored to the frame so it
    -- tracks under any skin. SetTexCoord is no-op'd on the frame so a skin's
    -- de-border crop can't shift it out of alignment with the orb (the icon is
    -- self-framed; it needs no cropping).
    for i = 1, (btn.GetNumRegions and btn:GetNumRegions() or 0) do
        local r = select(i, btn:GetRegions())
        if r and r.IsObjectType and r:IsObjectType("Texture") and r.SetAlpha
           and (r:GetTexture() or (r.GetAtlas and r:GetAtlas())) then
            r:SetAlpha(0); r.SetAlpha = noop   -- pin only the regions actually drawing art
        end
    end
    if not btn.__mbcLPIcon then
        btn.__mbcLPIcon = btn:CreateTexture(nil, "ARTWORK")
        btn.__mbcLPIcon.SetTexCoord = noop     -- keep it uncropped (aligns with the orb)
    end
    btn.__mbcLPIcon:SetTexture(LANDINGPAGE_FRAME)
    btn.__mbcLPIcon:Show()
    btn.__mbcIcon = btn.__mbcLPIcon            -- the frame is the skinned icon
    if not btn.__mbcLPOrb then
        btn.__mbcLPOrb = btn:CreateTexture(nil, "ARTWORK", nil, -2)
        btn.__mbcLPOrb.Hide = noop             -- a skin must not hide our orb layer
    end
    btn.__mbcLPOrb:SetTexture(LANDINGPAGE_ORB)
    btn.__mbcLPOrb:SetAllPoints(btn.__mbcLPIcon)   -- track the frame under any skin
    local _, class = UnitClass("player")
    local col = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if col then btn.__mbcLPOrb:SetVertexColor(col.r, col.g, col.b) end
    btn.__mbcLPOrb:Show()
    lockButton(btn)   -- drag-to-reorder + lock the move API
    applySkin(btn)
    return true
end

local function scanMinimap()
    -- Reparenting a button during combat can trip the protected-frame guard, so
    -- defer collection until combat ends (PLAYER_REGEN_ENABLED runs it then).
    if InCombatLockdown and InCombatLockdown() then
        pendingScan = true
        return 0
    end
    local containers = { Minimap }
    if MinimapBackdrop then containers[#containers + 1] = MinimapBackdrop end
    local added = 0
    for _, container in ipairs(containers) do
        local children = { container:GetChildren() }
        for _, child in ipairs(children) do
            if child ~= toggle and child ~= bar and not isCollected[child] and shouldCollect(child) then
                isCollected[child] = true
                collected[#collected + 1] = child
                squareButton(child)
                child:SetParent(bar)
                lockButton(child)
                added = added + 1
            end
        end
    end
    if collectLandingPageButton() then added = added + 1 end
    if added > 0 then applyOrder(); layout() end
    return added
end

-- A collected button is still valid if it's a live frame parented to the bar.
-- The landing-page button is reparented onto the bar too (and its SetParent is
-- locked), but flag it explicitly as well so a stray Blizzard reparent can't
-- silently drop it from the row.
local function stillCollectable(b)
    return type(b) == "table" and b.IsObjectType and b:IsObjectType("Frame")
        and (b.__mbcLandingPage or (b.GetParent and b:GetParent() == bar))
end

-- Drop buttons that have gone away (frame destroyed, or an addon reparented it
-- back off our bar) and compact the list so no empty slot is left behind.
-- Returns the number removed.
local function pruneCollected()
    -- Fast path: when every button is still valid (the usual case) we allocate
    -- nothing and return immediately.
    local anyInvalid = false
    for _, b in ipairs(collected) do
        if not stillCollectable(b) then anyInvalid = true; break end
    end
    if not anyInvalid then return 0 end

    local kept, removed = {}, 0
    for _, b in ipairs(collected) do
        if stillCollectable(b) then
            kept[#kept + 1] = b
        else
            removed = removed + 1
            if b then isCollected[b] = nil end
        end
    end
    wipe(collected)
    for i, b in ipairs(kept) do collected[i] = b end
    return removed
end

-- Cheap signal for "did the minimap's button set change?" - the polling ticker
-- compares this and skips the (more expensive) prune+scan when it's unchanged,
-- so idle CPU stays near zero.
local lastChildCount = -1
local function minimapChildCount()
    local n = (Minimap and Minimap.GetNumChildren and Minimap:GetNumChildren()) or 0
    if MinimapBackdrop and MinimapBackdrop.GetNumChildren then
        n = n + MinimapBackdrop:GetNumChildren()
    end
    return n
end

-- Full cleanup: pick up new buttons, drop removed ones, re-flow the bar.
-- Returns added, removed counts.
local function refreshBar()
    local removed = pruneCollected()
    local added   = scanMinimap()   -- lays out if it added anything
    if removed > 0 and added == 0 then layout() end
    lastChildCount = minimapChildCount()   -- keep the ticker's gate in sync
    return added, removed
end

-- Watch for buttons appearing/disappearing while playing and refresh the bar.
-- The poll is self-limiting: an idle tick is just a child-count compare, and
-- after STABLE_LIMIT ticks with no change it cancels itself, so a quiet session
-- costs no CPU at all. Anything that can add a button (zoning, an addon loading,
-- a LibDBIcon appearing, leaving combat) re-arms it via armRefresh().
local refreshTicker
local stableTicks  = 0
local STABLE_LIMIT = 6   -- stop the poll after ~30s with no change

local function armRefresh()
    stableTicks = 0
    if refreshTicker then return end   -- already polling (counter reset above)
    refreshTicker = C_Timer.NewTicker(5, function()
        if InCombatLockdown and InCombatLockdown() then return end
        if minimapChildCount() == lastChildCount then
            stableTicks = stableTicks + 1
            if stableTicks >= STABLE_LIMIT and refreshTicker then
                refreshTicker:Cancel(); refreshTicker = nil   -- idle: stop polling
            end
            return
        end
        stableTicks = 0
        refreshBar()
    end)
end

-- Register the LibDBIcon fast path once: it fires the instant an icon is created
-- (including when you enable a hidden one in its addon's options).
local function hookLDBIcon()
    local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if LDBIcon and LDBIcon.RegisterCallback then
        LDBIcon.RegisterCallback({}, "LibDBIcon_IconCreated", function()
            C_Timer.After(0, function()
                if not (InCombatLockdown and InCombatLockdown()) then
                    refreshBar(); armRefresh()
                end
            end)
        end)
    end
end

-- ===========================================================================
-- Open / close
-- ===========================================================================
local function setOpen(open)
    db.isOpen = open and true or false
    if db.isOpen then scanMinimap() end
    layout()
end
local function toggleOpen()
    -- Locked open: the bar was locked while expanded, so a click can't close it.
    -- Locked closed: a click may still open/close it. Either way it can't be dragged.
    if db.lockMode == "locked" and db.lockedOpen then return end
    setOpen(not db.isOpen)
end

-- Apply a lock mode. Locking captures the current open/closed state (so a bar
-- locked while open stays open and frozen, while one locked closed can still be
-- opened/closed by a click) and pins the position. Shift-click the M, the
-- panel's Movement option, and /mib lock|unlock|move all route through here so
-- they stay in sync.
local function applyLockMode(mode)
    db.lockMode = (mode == "locked") and "locked" or "unlocked"
    if db.lockMode == "locked" then db.lockedOpen = db.isOpen and true or false end
    layout()
    if config and config.Refresh and config:IsShown() then config.Refresh() end
end

-- Shift-click the M: toggle the lock.
local function toggleLock()
    applyLockMode(db.lockMode == "locked" and "unlocked" or "locked")
    msg(db.lockMode == "locked" and "locked." or "unlocked.")
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
        local fallback = next(store.profiles)   -- any remaining profile, else this char's
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
        elseif IsShiftKeyDown and IsShiftKeyDown() then
            toggleLock()
        else
            toggleOpen()
        end
    end)
    toggle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Minimap Icon Bar")
        GameTooltip:AddLine("Left-click: open / close", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Shift-click: lock / unlock", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Right-click: options", 0.8, 0.8, 0.8)
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
    -- Shift right of the row's left margin (x) so the - stepper, anchored to the
    -- slider's left edge, lines up with the margin instead of bleeding off the
    -- panel. Narrower track keeps the + stepper on-panel.
    s:SetPoint("TOPLEFT", x + 26, y)
    s:SetWidth(184)
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

    -- Stepper buttons flanking the slider for fine adjustment: - on the left,
    -- + on the right. SetValue clamps to the min/max and fires OnValueChanged,
    -- so onChange and the value label update just as they do for a drag.
    local function stepper(label, point, relPoint, dx, delta)
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(22, 22)
        b:SetPoint(point, s, relPoint, dx, 0)
        b:SetText(label)
        b:SetScript("OnClick", function() s:SetValue(s:GetValue() + delta) end)
        return b
    end
    stepper("-", "RIGHT", "LEFT",  -4, -step)
    stepper("+", "LEFT",  "RIGHT",  4,  step)
    return s
end

-- Single-select dropdown (replaces the deprecated UIDropDownMenu, which taints
-- Edit Mode). `order` is the value list, `textOf` maps a value to its label,
-- `get` returns the current value, `set` applies a pick. The button text is
-- derived automatically from the selected radio; the menu refreshes itself
-- after a click, and config.Refresh() calls dd:GenerateMenu() to re-sync it
-- when the value changes elsewhere (profile switch, /mib command, ...).
local function makeDropdown(name, parent, x, y, width, order, textOf, get, set)
    local dd = CreateFrame("DropdownButton", name, parent, "WowStyle1DropdownTemplate")
    dd:SetPoint("TOPLEFT", x, y)
    dd:SetWidth(width)
    dd:SetupMenu(function(_, root)
        for _, value in ipairs(order) do
            root:CreateRadio(
                textOf[value],
                function(v) return get() == v end,
                function(v) set(v) end,
                value)
        end
    end)
    return dd
end

-- A labelled checkbox. The label is our own font string anchored to the box
-- rather than the template's, so it survives Blizzard swapping the checkbutton
-- template internals. Exposes :Refresh() to re-sync from the profile.
local function makeCheck(name, parent, x, y, label, get, set)
    local c = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    c:SetPoint("TOPLEFT", x, y)
    c:SetSize(26, 26)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", c, "RIGHT", 2, 1)
    fs:SetText(label)
    c:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    c.Refresh = function() c:SetChecked(get() and true or false) end
    return c
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

    local spacing = makeSlider("MinimapIconBarSpacingSlider", config, 0, 16, 0.5, 24, -160,
        function(v) v = math.floor(v * 2 + 0.5) / 2; db.spacing = v; layout(); return v end,
        function(v) return ("Spacing: %.1f px"):format(v) end)

    local perRow = makeSlider("MinimapIconBarPerRowSlider", config, 1, 12, 1, 24, -208,
        function(v) v = math.floor(v + 0.5); db.buttonsPerRow = v; layout(); return v end,
        function(v) return "Buttons per row (incl. the M icon): " .. v end)

    local growthLabel = config:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    growthLabel:SetPoint("TOPLEFT", 24, -250)
    growthLabel:SetText("Growth direction")

    local growth = makeDropdown("MinimapIconBarGrowthDropDown", config, 24, -265, 200,
        GROWTH_ORDER, GROWTH_TEXT,
        function() return db.growth or "DOWN_RIGHT" end,
        function(v) db.growth = v; layout() end)

    -- Movement -------------------------------------------------------------
    local moveLabel = config:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    moveLabel:SetPoint("TOPLEFT", 24, -308)
    moveLabel:SetText("Movement")

    local move = makeDropdown("MinimapIconBarMoveDropDown", config, 24, -323, 200,
        LOCK_ORDER, LOCK_TEXT,
        function() return db.lockMode or "unlocked" end,
        function(v) applyLockMode(v) end)

    -- Skin profile --------------------------------------------------------
    local skinLabel = config:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    skinLabel:SetPoint("TOPLEFT", 24, -400)
    skinLabel:SetText("Skin profile")

    local skin = makeDropdown("MinimapIconBarSkinDropDown", config, 24, -415, 260,
        SKIN_ORDER, SKIN_TEXT,
        function() return db.skinStyle or "auto" end,
        function(v) applySkinChoice(v) end)

    local skinNote = config:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    skinNote:SetPoint("TOPLEFT", 26, -452)

    local rescan = CreateFrame("Button", nil, config, "UIPanelButtonTemplate")
    rescan:SetSize(110, 22)
    rescan:SetPoint("TOPLEFT", 24, -484)
    rescan:SetText("Clean up")
    rescan:SetScript("OnClick", function()
        local added, removed = refreshBar()
        if added > 0 or removed > 0 then
            msg(("cleaned up (%d added, %d removed)."):format(added, removed))
        else
            msg("nothing to clean up.")
        end
    end)

    local reset = CreateFrame("Button", nil, config, "UIPanelButtonTemplate")
    reset:SetSize(110, 22)
    reset:SetPoint("LEFT", rescan, "RIGHT", 12, 0)
    reset:SetText("Reset")
    reset:SetScript("OnClick", resetSettings)

    -- Blizzard buttons ----------------------------------------------------
    local landingLabel = config:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    landingLabel:SetPoint("TOPLEFT", 24, -522)
    landingLabel:SetText("Blizzard buttons")

    local landing = makeCheck("MinimapIconBarLandingPageCheck", config, 24, -538,
        "Collect the expansion landing-page button (Omnium Folio / renown)",
        function() return db.collectLandingPage end,
        function(on)
            if (db.collectLandingPage and true or false) == on then return end
            db.collectLandingPage = on
            if on then
                scanMinimap()   -- grab it now; turning it off waits for a reload
            else
                StaticPopup_Show("MINIMAPICONBAR_RELOAD_LANDINGPAGE")
            end
        end)

    local landingNote = config:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    landingNote:SetPoint("TOPLEFT", 26, -562)
    landingNote:SetText("Blizzard's own button. Edit Mode may still reposition it; turning this off restores it to the minimap on reload.")

    function config.Refresh()
        scale:SetValue(db.scale or 1.0)
        size:SetValue(db.size or 32)
        spacing:SetValue(db.spacing or 2)
        perRow:SetValue(db.buttonsPerRow or 6)
        growth:GenerateMenu()
        move:GenerateMenu()
        skin:GenerateMenu()
        landing:Refresh()
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

    local dd = CreateFrame("DropdownButton", "MinimapIconBarProfileDropDown", configProfiles, "WowStyle1DropdownTemplate")
    dd:SetPoint("TOPLEFT", 24, -93)
    dd:SetWidth(240)
    dd:SetDefaultText("Default")
    dd:SetupMenu(function(_, root)
        for _, name in ipairs(profileNames()) do
            root:CreateRadio(name,
                function(n) return n == activeProfile end,
                function(n) activateProfile(n) end,
                name)
        end
    end)

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
        dd:GenerateMenu()
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
    elseif cmd == "rescan" or cmd == "cleanup" then
        local added, removed = refreshBar()
        if added > 0 or removed > 0 then
            msg(("cleaned up (%d added, %d removed)."):format(added, removed))
        else
            msg("nothing to clean up.")
        end
    elseif cmd == "reset" then
        resetSettings()
    elseif cmd == "lock" then
        applyLockMode("locked")
        msg("locked (icons shown and frozen in place).")
    elseif cmd == "unlock" then
        applyLockMode("unlocked")
        msg("unlocked.")
    elseif cmd == "move" then
        local v = arg:lower()
        if LOCK_TEXT[v] then applyLockMode(v)
            msg("movement = " .. LOCK_TEXT[v])
        else print("Usage: /mib move unlocked | locked") end
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
        if v then db.size = math.max(16, math.min(48, math.floor(v))); resizeAll(); layout()
            msg("button size = " .. db.size .. " px")
        else print("Usage: /mib size 32") end
    elseif cmd == "spacing" then
        local v = tonumber(arg)
        if v then db.spacing = math.max(0, math.min(16, math.floor(v * 2 + 0.5) / 2)); layout()
            msg("spacing = " .. db.spacing .. " px")
        else print("Usage: /mib spacing 0.5") end
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
        print("  /mib scale N    - whole-bar scale 0.5-2.0")
        print("  /mib size N     - button size in px")
        print("  /mib spacing N  - gap in px (0 = flush)")
        print("  /mib perrow N   - buttons per row 1-12 (incl. the M icon)")
        print("  /mib growth DIR - down_right|down_left|up_right|up_left")
        print("  /mib move unlocked|locked  (shift-click the M also toggles lock)")
        print("  (unlock the bar, then drag icons to reorder them)")
        print("  /mib skin auto|default|elvui|masque")
        print("  /mib profile set|new|copy|delete NAME")
        print("  /mib inspect, dump, restrip, lock, unlock, cleanup, reset")
    end
end

-- ===========================================================================
-- Addon Compartment (the dropdown by the minimap clock)
-- ===========================================================================
function MinimapIconBarCompartmentOnClick(_, arg2, arg3)
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

function MinimapIconBarCompartmentOnEnter(_, menuButton)
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
        armRefresh()   -- buttons may have been created during combat
        return
    end
    if event == "PLAYER_ENTERING_WORLD" or event == "ADDON_LOADED" then
        armRefresh()   -- a zone change or an addon loading can add buttons
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

    -- Pick up buttons deferred because we were in combat at the time, and re-arm
    -- the poll on zone changes / addon loads (these can add minimap buttons).
    boot:RegisterEvent("PLAYER_REGEN_ENABLED")
    boot:RegisterEvent("PLAYER_ENTERING_WORLD")
    boot:RegisterEvent("ADDON_LOADED")

    scanMinimap()
    for _, delay in ipairs({ 1, 3, 6, 10 }) do
        C_Timer.After(delay, function() scanMinimap(); layout() end)
    end
    hookLDBIcon()
    armRefresh()

    local skin = chosenSkin()
    local skinText = (skin == "masque" and " (Masque)")
        or (skin == "elvui" and " (ElvUI)")
        or " (default skin)"
    print(PREFIX .. " loaded" .. skinText .. ". Type |cffffff00/mib|r for options.")
end)
