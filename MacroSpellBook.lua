-- MacroSpellBook
-- Öffnet ein eigenes Zauberbuch mit Tabs und Schnellsuche.
-- Zauber per Drag&Drop -> auto-erstelltes charakter-spezifisches Macro.
-- Slash: /msb  /macrospellbook

local ADDON_NAME   = "MacroSpellBook"
local MACRO_PREFIX = "MSB_"

-- Grid
local ICON_SIZE     = 40
local ICON_PADDING  = 6
local ICONS_PER_ROW = 6

-- Hauptfenster
local FRAME_WIDTH   = 360
local FRAME_HEIGHT  = 520

MacroSpellBookDB = nil

local DEFAULT_TEMPLATES = {
    ["Start Attack"] = "#showtooltip\n/startattack\n/cast %s",
}

local MSB = {
    selectedTemplate = "Start Attack",
    spellButtons     = {},
    templateDropdown = nil,
    mainFrame        = nil,
    scrollFrame      = nil,
    scrollChild      = nil,
    searchBox        = nil,
    tabButtons       = {},
    activeTab        = 1,   -- 1-basiert in MSB.tabs; 0 = "Alle"
    searchText       = "",
    tabs             = {},  -- { {name, texture, spells=[{name,texture,slot}]} }
}

-- ============================================================
-- SavedVariable-Hilfsfunktionen
-- ============================================================

local function GetTemplates()
    return MacroSpellBookDB.templates
end

local function SetTemplate(name, body)
    MacroSpellBookDB.templates[name] = body
end

local function DeleteTemplate(name)
    if name == "Start Attack" then
        UIErrorsFrame:AddMessage(
            "|cffff0000MacroSpellBook:|r Das Standard-Template kann nicht geloescht werden.", 1, 0, 0)
        return false
    end
    MacroSpellBookDB.templates[name] = nil
    if MacroSpellBookDB.templateMacroNames then
        MacroSpellBookDB.templateMacroNames[name] = nil
    end
    if MacroSpellBookDB.templatePerChar then
        MacroSpellBookDB.templatePerChar[name] = nil
    end
    if MSB.selectedTemplate == name then
        MSB.selectedTemplate          = "Start Attack"
        MacroSpellBookDB.lastTemplate = "Start Attack"
    end
    return true
end

-- ============================================================
-- Macro-Erstellung
-- ============================================================

local function CreateAndPickupMacro(spellName)
    local templateBody = GetTemplates()[MSB.selectedTemplate]
                      or DEFAULT_TEMPLATES["Start Attack"]
    local macroBody  = templateBody:gsub("%%s", spellName)
    local rawName    = (MacroSpellBookDB.templateMacroNames
                       and MacroSpellBookDB.templateMacroNames[MSB.selectedTemplate])
                       or "."
    rawName          = rawName:match("^%s*(.-)%s*$")
    local macroName  = (rawName ~= "" and rawName or "."):sub(1, 16)
    local tPerChar   = MacroSpellBookDB.templatePerChar
    local perChar    = (tPerChar == nil) or (tPerChar[MSB.selectedTemplate] ~= false)
    local macroIndex = GetMacroIndexByName(macroName)

    if macroIndex > 0 then
        EditMacro(macroIndex, macroName, nil, macroBody)
    else
        local numGlobal, numChar = GetNumMacros()
        if perChar and numChar >= 18 then
            UIErrorsFrame:AddMessage(
                "|cffff0000MacroSpellBook:|r Charakter-Macro-Limit (18) erreicht.", 1, 0, 0)
            return
        elseif not perChar and numGlobal >= 120 then
            UIErrorsFrame:AddMessage(
                "|cffff0000MacroSpellBook:|r Globales Macro-Limit (120) erreicht.", 1, 0, 0)
            return
        else
            -- perChar=true  -> charakter-spezifisch (letzter Param = 1)
            -- perChar=false -> global              (letzter Param = nil)
            CreateMacro(macroName, "INV_Misc_QuestionMark", macroBody, perChar or nil)
            macroIndex = GetMacroIndexByName(macroName)
        end
    end

    if macroIndex and macroIndex > 0 then
        PickupMacro(macroIndex)
    end
end

-- ============================================================
-- Zauberdaten (nach Tabs gegliedert)
-- ============================================================

local function GetSpellTabs()
    local tabs    = {}
    local numTabs = GetNumSpellTabs()
    for ti = 1, numTabs do
        local tabName, tabTexture, offset, numSlots = GetSpellTabInfo(ti)
        local spells = {}
        local seen   = {}
        for si = offset + 1, offset + numSlots do
            local spellName = GetSpellBookItemName(si, BOOKTYPE_SPELL)
            local spellType = GetSpellBookItemInfo(si, BOOKTYPE_SPELL)
            local texture   = GetSpellBookItemTexture(si, BOOKTYPE_SPELL)
            if spellName and spellType == "SPELL" then
                if seen[spellName] then
                    -- hoeheren Rang (spaeterer Slot) bevorzugen
                    seen[spellName].slot    = si
                    seen[spellName].texture = texture
                else
                    local e = {name = spellName, texture = texture, slot = si}
                    table.insert(spells, e)
                    seen[spellName] = e
                end
            end
        end
        table.insert(tabs, {name = tabName, texture = tabTexture, spells = spells})
    end
    return tabs
end

-- ============================================================
-- Template-Editor-Dialog
-- ============================================================

local templateEditorFrame

local function CreateTemplateEditorFrame()
    local f = CreateFrame("Frame", "MSBTemplateEditor", UIParent, "BackdropTemplate")
    f:SetSize(330, 338)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:Hide()

    local titleBg = f:CreateTexture(nil, "ARTWORK")
    titleBg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleBg:SetSize(256, 64)
    titleBg:SetPoint("TOP", f, "TOP", 0, 12)

    f.titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.titleText:SetPoint("TOP", f, "TOP", 0, -6)

    local nameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -38)
    nameLabel:SetText("Name:")

    f.nameBox = CreateFrame("EditBox", "MSBTemplateEditorName", f, "InputBoxTemplate")
    f.nameBox:SetSize(216, 20)
    f.nameBox:SetPoint("TOPLEFT", f, "TOPLEFT", 80, -36)
    f.nameBox:SetAutoFocus(false)
    f.nameBox:SetMaxLetters(40)

    local macroNameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    macroNameLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -62)
    macroNameLabel:SetText("Macro-Name:")

    f.macroNameBox = CreateFrame("EditBox", "MSBTemplateEditorMacroName", f, "InputBoxTemplate")
    f.macroNameBox:SetSize(160, 20)
    f.macroNameBox:SetPoint("TOPLEFT", f, "TOPLEFT", 116, -60)
    f.macroNameBox:SetAutoFocus(false)
    f.macroNameBox:SetMaxLetters(16)

    -- Checkbox: Charakter-spezifisch
    f.perCharCheck = CreateFrame("CheckButton", "MSBTemplateEditorPerChar", f, "UICheckButtonTemplate")
    f.perCharCheck:SetSize(24, 24)
    f.perCharCheck:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -84)
    f.perCharCheck:SetChecked(true)
    local perCharLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    perCharLabel:SetPoint("LEFT", f.perCharCheck, "RIGHT", 2, 0)
    perCharLabel:SetText("Charakter-spezifisches Macro")

    local bodyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bodyLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -112)
    bodyLabel:SetText("Body:")

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -130)
    hint:SetText("|cffaaaaaa%s wird durch den Zaubernamen ersetzt|r")

    local bodyScroll = CreateFrame(
        "ScrollFrame", "MSBTemplateEditorScroll", f, "UIPanelScrollFrameTemplate")
    bodyScroll:SetSize(274, 110)
    bodyScroll:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -146)

    f.bodyBox = CreateFrame("EditBox", "MSBTemplateEditorBody", bodyScroll)
    f.bodyBox:SetSize(254, 200)
    f.bodyBox:SetMultiLine(true)
    f.bodyBox:SetAutoFocus(false)
    f.bodyBox:SetFontObject(ChatFontNormal)
    f.bodyBox:SetMaxLetters(255)
    bodyScroll:SetScrollChild(f.bodyBox)

    local saveBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    saveBtn:SetSize(90, 22)
    saveBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 16)
    saveBtn:SetText("Speichern")
    saveBtn:SetScript("OnClick", function()
        local name = f.nameBox:GetText():match("^%s*(.-)%s*$")
        local body = f.bodyBox:GetText()
        if not name or name == "" then
            UIErrorsFrame:AddMessage(
                "|cffff0000MacroSpellBook:|r Kein Name angegeben.", 1, 0, 0)
            return
        end
        if not body or body == "" then
            UIErrorsFrame:AddMessage(
                "|cffff0000MacroSpellBook:|r Kein Body angegeben.", 1, 0, 0)
            return
        end
        local macroNameRaw = f.macroNameBox:GetText():match("^%s*(.-)%s*$")
        if not macroNameRaw or macroNameRaw == "" then macroNameRaw = "." end
        macroNameRaw = macroNameRaw:sub(1, 16)
        if not MacroSpellBookDB.templateMacroNames then
            MacroSpellBookDB.templateMacroNames = {}
        end
        MacroSpellBookDB.templateMacroNames[name] = macroNameRaw
        if not MacroSpellBookDB.templatePerChar then
            MacroSpellBookDB.templatePerChar = {}
        end
        MacroSpellBookDB.templatePerChar[name] = f.perCharCheck:GetChecked() and true or false
        SetTemplate(name, body)
        MSB.selectedTemplate          = name
        MacroSpellBookDB.lastTemplate = name
        if MSB.templateDropdown then
            UIDropDownMenu_SetText(MSB.templateDropdown, name)
        end
        f:Hide()
    end)

    local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancelBtn:SetSize(90, 22)
    cancelBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 16)
    cancelBtn:SetText("Abbrechen")
    cancelBtn:SetScript("OnClick", function() f:Hide() end)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    return f
end

local function OpenTemplateEditor(editName)
    if not templateEditorFrame then
        templateEditorFrame = CreateTemplateEditorFrame()
    end
    local tMacroNames = MacroSpellBookDB and MacroSpellBookDB.templateMacroNames
    if editName then
        templateEditorFrame.titleText:SetText("Template bearbeiten")
        templateEditorFrame.nameBox:SetText(editName)
        templateEditorFrame.macroNameBox:SetText(
            (tMacroNames and tMacroNames[editName]) or ".")
        local tPerChar = MacroSpellBookDB and MacroSpellBookDB.templatePerChar
        local isPerChar = (tPerChar == nil) or (tPerChar[editName] ~= false)
        templateEditorFrame.perCharCheck:SetChecked(isPerChar)
        templateEditorFrame.bodyBox:SetText(GetTemplates()[editName] or "")
    else
        templateEditorFrame.titleText:SetText("Neues Template")
        templateEditorFrame.nameBox:SetText("")
        templateEditorFrame.macroNameBox:SetText(".")
        templateEditorFrame.perCharCheck:SetChecked(true)
        templateEditorFrame.bodyBox:SetText("#showtooltip\n/cast %s")
    end
    templateEditorFrame:Show()
    templateEditorFrame:Raise()
end

-- ============================================================
-- Spell-Buttons (Grid)
-- ============================================================

local function CreateSpellButton(index)
    local btn = CreateFrame("Button", "MSBSpellBtn" .. index, MSB.scrollChild)
    btn:SetSize(ICON_SIZE, ICON_SIZE)
    btn:RegisterForDrag("LeftButton")

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetAllPoints()
    btn.icon = icon

    -- Hover-Highlight
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    hl:SetBlendMode("ADD")

    btn:SetScript("OnDragStart", function(self)
        if self.spellName then
            CreateAndPickupMacro(self.spellName)
        end
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetSpellBookItem(self.spellSlot, BOOKTYPE_SPELL)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return btn
end

-- ============================================================
-- Zauberliste befuellen
-- ============================================================

local function PopulateSpells()
    local search       = MSB.searchText:lower()
    local spellsToShow = {}

    if search ~= "" then
        -- Suche quer ueber alle Tabs
        for _, tab in ipairs(MSB.tabs) do
            for _, spell in ipairs(tab.spells) do
                if spell.name:lower():find(search, 1, true) then
                    table.insert(spellsToShow, spell)
                end
            end
        end
    elseif MSB.activeTab == 0 then
        -- Alle Tabs zusammen
        for _, tab in ipairs(MSB.tabs) do
            for _, spell in ipairs(tab.spells) do
                table.insert(spellsToShow, spell)
            end
        end
    else
        local tab = MSB.tabs[MSB.activeTab]
        if tab then
            spellsToShow = tab.spells
        end
    end

    -- Ueberschuessige Buttons verstecken
    for i = #spellsToShow + 1, #MSB.spellButtons do
        MSB.spellButtons[i]:Hide()
    end

    local numRows  = math.ceil(math.max(#spellsToShow, 1) / ICONS_PER_ROW)
    local contentH = ICON_PADDING + numRows * (ICON_SIZE + ICON_PADDING)
    MSB.scrollChild:SetHeight(math.max(contentH, MSB.scrollFrame:GetHeight()))

    for i, spell in ipairs(spellsToShow) do
        if not MSB.spellButtons[i] then
            MSB.spellButtons[i] = CreateSpellButton(i)
        end
        local btn = MSB.spellButtons[i]
        btn.spellName = spell.name
        btn.spellSlot = spell.slot
        btn.icon:SetTexture(spell.texture)

        local col = (i - 1) % ICONS_PER_ROW
        local row = math.floor((i - 1) / ICONS_PER_ROW)
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", MSB.scrollChild, "TOPLEFT",
            ICON_PADDING + col * (ICON_SIZE + ICON_PADDING),
            -(ICON_PADDING + row * (ICON_SIZE + ICON_PADDING)))
        btn:Show()
    end
end

-- ============================================================
-- Tab-Buttons
-- ============================================================

-- Vorwaerts-Deklaration (wird nach RefreshTabs definiert)
local RefreshTabHighlights

local function RefreshTabs()
    local numClassTabs = #MSB.tabs
    local totalTabs    = numClassTabs + 1  -- +1 fuer "Alle"
    local availW       = FRAME_WIDTH - 28
    local gap          = 2
    local btnW         = math.floor((availW - (totalTabs - 1) * gap) / totalTabs)

    for i = 1, math.max(totalTabs, #MSB.tabButtons) do
        if i > totalTabs then
            if MSB.tabButtons[i] then MSB.tabButtons[i]:Hide() end
        else
            if not MSB.tabButtons[i] then
                MSB.tabButtons[i] = CreateFrame(
                    "Button", "MSBTabBtn" .. i, MSB.mainFrame, "UIPanelButtonTemplate")
                MSB.tabButtons[i]:SetHeight(22)
            end

            local btn      = MSB.tabButtons[i]
            local tabIndex = i - 1  -- 0 = "Alle"
            btn:SetWidth(btnW)
            btn:ClearAllPoints()
            if i == 1 then
                btn:SetPoint("TOPLEFT", MSB.mainFrame, "TOPLEFT", 14, -122)
            else
                btn:SetPoint("LEFT", MSB.tabButtons[i - 1], "RIGHT", gap, 0)
            end

            btn:SetText(tabIndex == 0 and "Alle" or MSB.tabs[tabIndex].name)

            btn:SetScript("OnClick", function()
                MSB.activeTab  = tabIndex
                MSB.searchText = ""
                if MSB.searchBox then
                    MSB.searchBox:SetText("")
                end
                RefreshTabHighlights()
                PopulateSpells()
            end)

            btn:Show()
        end
    end
end

RefreshTabHighlights = function()
    for i, btn in ipairs(MSB.tabButtons) do
        local tabIndex = i - 1
        local isActive = (tabIndex == MSB.activeTab) and (MSB.searchText == "")
        -- GameFontHighlight = gelb/aktiv; GameFontNormal = weiss/inaktiv
        btn:SetNormalFontObject(isActive and GameFontHighlight or GameFontNormal)
    end
end

-- ============================================================
-- Vollstaendige Auffrischung (Tabs + Spells)
-- ============================================================

local function FullRefresh()
    MSB.tabs = GetSpellTabs()
    if MSB.activeTab > #MSB.tabs then
        MSB.activeTab = math.min(1, #MSB.tabs)
    end
    RefreshTabs()
    RefreshTabHighlights()
    PopulateSpells()
end

-- ============================================================
-- Template-Dropdown
-- ============================================================

local function TemplateDropdown_Initialize(self, level)
    for name, _ in pairs(GetTemplates()) do
        local info         = UIDropDownMenu_CreateInfo()
        info.text          = name
        info.value         = name
        info.checked       = (MSB.selectedTemplate == name)
        info.func          = function(btn)
            MSB.selectedTemplate          = btn.value
            MacroSpellBookDB.lastTemplate = btn.value
            UIDropDownMenu_SetText(MSB.templateDropdown, btn.value)
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

-- ============================================================
-- Hauptfenster
-- ============================================================

local function CreateMainFrame()
    local f = CreateFrame("Frame", "MacroSpellBookFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("MEDIUM")
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:Hide()

    -- Titelzeile
    local titleBg = f:CreateTexture(nil, "ARTWORK")
    titleBg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleBg:SetSize(256, 64)
    titleBg:SetPoint("TOP", f, "TOP", 0, 12)

    local titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("TOP", f, "TOP", 0, -6)
    titleText:SetText("MacroSpellBook")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Template-Zeile
    local templateLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    templateLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -36)
    templateLabel:SetText("Template:")

    local templateDropdown = CreateFrame(
        "Frame", "MSBTemplateDropdown", f, "UIDropDownMenuTemplate")
    templateDropdown:SetPoint("TOPLEFT", f, "TOPLEFT", 70, -28)
    UIDropDownMenu_SetWidth(templateDropdown, 130)
    MSB.templateDropdown = templateDropdown
    UIDropDownMenu_Initialize(templateDropdown, TemplateDropdown_Initialize)
    UIDropDownMenu_SetText(templateDropdown, MSB.selectedTemplate)

    -- Template-Buttons
    local delBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    delBtn:SetSize(70, 20)
    delBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -58)
    delBtn:SetText("Loeschen")
    delBtn:SetScript("OnClick", function()
        if DeleteTemplate(MSB.selectedTemplate) then
            UIDropDownMenu_SetText(MSB.templateDropdown, "Start Attack")
        end
    end)

    local editBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    editBtn:SetSize(80, 20)
    editBtn:SetPoint("LEFT", delBtn, "RIGHT", 4, 0)
    editBtn:SetText("Bearbeiten")
    editBtn:SetScript("OnClick", function()
        OpenTemplateEditor(MSB.selectedTemplate)
    end)

    local newBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    newBtn:SetSize(66, 20)
    newBtn:SetPoint("LEFT", editBtn, "RIGHT", 4, 0)
    newBtn:SetText("+ Neu")
    newBtn:SetScript("OnClick", function()
        OpenTemplateEditor(nil)
    end)

    -- Trennlinie
    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetTexture("Interface\\Common\\UI-TooltipDivider-Transparent")
    sep:SetSize(FRAME_WIDTH - 30, 16)
    sep:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -82)

    -- Suchzeile
    local searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    searchLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -102)
    searchLabel:SetText("Suche:")

    local searchBox = CreateFrame("EditBox", "MSBSearchBox", f, "InputBoxTemplate")
    searchBox:SetSize(FRAME_WIDTH - 84, 20)
    searchBox:SetPoint("TOPLEFT", f, "TOPLEFT", 68, -100)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(60)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)
    searchBox:SetScript("OnTextChanged", function(self)
        MSB.searchText = self:GetText()
        RefreshTabHighlights()
        PopulateSpells()
    end)
    MSB.searchBox = searchBox

    -- Tab-Buttons: Pool, wird befuellt durch RefreshTabs() bei y=-122

    -- Scroll-Frame fuer Zauber
    local scrollW = FRAME_WIDTH - 28
    local scrollH = FRAME_HEIGHT - 152 - 14

    local scrollFrame = CreateFrame(
        "ScrollFrame", "MSBScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetSize(scrollW, scrollH)
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -152)

    local scrollChild = CreateFrame("Frame", "MSBScrollChild", scrollFrame)
    scrollChild:SetSize(scrollW, 1)
    scrollFrame:SetScrollChild(scrollChild)

    MSB.mainFrame   = f
    MSB.scrollFrame = scrollFrame
    MSB.scrollChild = scrollChild

    f:SetScript("OnShow", function()
        MSB.searchText = ""
        if MSB.searchBox then MSB.searchBox:SetText("") end
        FullRefresh()
        UIDropDownMenu_SetText(MSB.templateDropdown, MSB.selectedTemplate)
    end)

    return f
end

-- ============================================================
-- Events
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("SPELLS_CHANGED")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then

        if type(MacroSpellBookDB) ~= "table" then
            MacroSpellBookDB = {}
        end
        if type(MacroSpellBookDB.templates) ~= "table" then
            MacroSpellBookDB.templates = {}
            for k, v in pairs(DEFAULT_TEMPLATES) do
                MacroSpellBookDB.templates[k] = v
            end
        end
        if not MacroSpellBookDB.templates["Start Attack"] then
            MacroSpellBookDB.templates["Start Attack"] = DEFAULT_TEMPLATES["Start Attack"]
        end
        if type(MacroSpellBookDB.templateMacroNames) ~= "table" then
            MacroSpellBookDB.templateMacroNames = {}
        end
        if not MacroSpellBookDB.templateMacroNames["Start Attack"] then
            MacroSpellBookDB.templateMacroNames["Start Attack"] = "."
        end
        if type(MacroSpellBookDB.templatePerChar) ~= "table" then
            MacroSpellBookDB.templatePerChar = {}
        end
        if MacroSpellBookDB.templatePerChar["Start Attack"] == nil then
            MacroSpellBookDB.templatePerChar["Start Attack"] = true
        end

        MSB.selectedTemplate = MacroSpellBookDB.lastTemplate or "Start Attack"
        if not MacroSpellBookDB.templates[MSB.selectedTemplate] then
            MSB.selectedTemplate          = "Start Attack"
            MacroSpellBookDB.lastTemplate = "Start Attack"
        end

        print("|cff00ff00MacroSpellBook|r geladen."
            .. " Benutze |cffffcc00/msb|r oder |cffffcc00/macrospellbook|r zum Oeffnen.")

    elseif event == "SPELLS_CHANGED" then
        if MSB.mainFrame and MSB.mainFrame:IsShown() then
            FullRefresh()
        end
    end
end)

-- ============================================================
-- Slash-Befehle
-- ============================================================

SLASH_MACROSPELLBOOK1 = "/msb"
SLASH_MACROSPELLBOOK2 = "/macrospellbook"

SlashCmdList["MACROSPELLBOOK"] = function()
    if not MSB.mainFrame then
        CreateMainFrame()
    end
    if MSB.mainFrame:IsShown() then
        MSB.mainFrame:Hide()
    else
        MSB.mainFrame:Show()
    end
end
