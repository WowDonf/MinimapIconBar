-- Luacheck configuration for Minimap Icon Bar.
-- Run from repo root: luacheck *.lua

std = "lua51"

-- WoW addon UI strings often need to fit a single readable line.
max_line_length = 200

-- Globals the addon defines, owns, or writes to.
globals = {
    -- Saved variables (managed by WoW from the TOC's SavedVariables field)
    "MinimapIconBarDB",
    -- Slash command registration
    "SLASH_MINIMAPICONBAR1",
    "SLASH_MINIMAPICONBAR2",
    -- Addon compartment hooks (must be globals; referenced from the TOC's
    -- AddonCompartmentFunc* fields)
    "MinimapIconBarCompartmentOnClick",
    "MinimapIconBarCompartmentOnEnter",
    "MinimapIconBarCompartmentOnLeave",
    -- Blizzard tables we mutate
    "SlashCmdList",         -- /mib handler registration
    "StaticPopupDialogs",   -- reload / delete-profile popups
    -- Read/written for named slider child regions ($nameLow/$nameHigh/$nameText)
    "_G",
}

-- Blizzard / WoW API globals the addon only reads from.
read_globals = {
    -- Frame + UI infrastructure
    "CreateFrame", "UIParent",
    "Minimap", "MinimapBackdrop",
    "Settings", "SettingsPanel", "HideUIPanel",
    "GameTooltip",
    "AddonCompartmentFrame",
    "StaticPopup_Show",
    -- Dropdown menu helpers (UIDropDownMenuTemplate)
    "UIDropDownMenu_Initialize", "UIDropDownMenu_CreateInfo",
    "UIDropDownMenu_AddButton", "UIDropDownMenu_SetWidth",
    "UIDropDownMenu_SetText", "UIDropDownMenu_SetSelectedValue",
    -- Combat / protected-frame state
    "InCombatLockdown",
    -- Timing
    "C_Timer",
    -- Textures / atlas
    "C_Texture",
    -- Input / cursor
    "GetCursorPosition", "GetMouseFoci", "GetMouseFocus", "IsShiftKeyDown",
    -- Unit / realm identity (profile keys)
    "UnitName", "GetRealmName",
    -- Tables / misc
    "wipe", "hooksecurefunc", "ReloadUI",
    -- Optional dependencies (probed via _G but sometimes referenced bare)
    "LibStub", "ElvUI",
}
