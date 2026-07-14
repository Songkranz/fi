local TS, GS, plr = game:GetService("TeleportService"), game:GetService("GuiService"), game:GetService("Players").LocalPlayer
    GS.ErrorMessageChanged:Connect(function()
    if GS:GetErrorMessage() ~= "" then TS:Teleport(game.PlaceId, plr) end
end)

repeat task.wait() until game:IsLoaded()
repeat task.wait() until game.Players.LocalPlayer

local Players           = game:GetService("Players")
local TeleportService   = game:GetService("TeleportService")
local HttpService       = game:GetService("HttpService")
local VirtualUser       = game:GetService("VirtualUser")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui           = game:GetService("CoreGui")

local LocalPlayer       = Players.LocalPlayer
local PlaceId           = game.PlaceId
local startTime         = os.clock()

local PlayerGui         = LocalPlayer:WaitForChild("PlayerGui")
local Events            = ReplicatedStorage:WaitForChild("Events")
local TradeEvents       = ReplicatedStorage:WaitForChild("TradeEvents")

local saveFolder        = "Songkranz"
local fileName          = saveFolder .. "/Stand-" .. LocalPlayer.Name .. ".json"

local function clickButton(getButtonFn, timeout)
    timeout = timeout or 10
    local t = os.clock()
    local button
    repeat
        button = getButtonFn()
        if button then break end
        task.wait(0.1)
    until (os.clock() - t) > timeout

    if not button then return false end

    return (pcall(function()
        if firesignal then
            firesignal(button.MouseButton1Click)
        elseif button.MouseButton1Click then
            for _, conn in pairs(getconnections(button.MouseButton1Click)) do
                conn:Fire()
            end
        end
    end))
end

clickButton(function()
    local cl = PlayerGui:FindFirstChild("Changelogs")
    return cl and cl:FindFirstChild("Frame") and cl.Frame:FindFirstChild("TextButton")
end, 10)

task.wait(0.5)

clickButton(function()
    local menu = PlayerGui:FindFirstChild("MenuGUI")
    return menu and menu:FindFirstChild("Play")
end, 10)

do
    local itemsLoaded = LocalPlayer:FindFirstChild("ItemsLoaded")
    local t = os.clock()
    repeat
        task.wait(0.1)
        itemsLoaded = itemsLoaded or LocalPlayer:FindFirstChild("ItemsLoaded")
    until (itemsLoaded and itemsLoaded.Value) or (os.clock() - t) > 30
end

--==================================================================
-- 2. REFERENCES (player data & slot value objects)
--==================================================================
local Data      = LocalPlayer:WaitForChild("Data")
local StandData = Data.Stand
local AttriData = Data.Attri
local CurrentLevel = Data.Level
local ServerAge = workspace.Age

local SlotOrder = { "Slot1", "Slot2", "Slot3", "Slot4", "Slot5" }
local SlotRefs  = {}
for i, slotName in ipairs(SlotOrder) do
    SlotRefs[slotName] = {
        Stand     = Data[slotName .. "Stand"],
        Attribute = Data[slotName .. "Attri"],
    }
end

local StandNameConvert = ReplicatedStorage.StandNameConvert

local Stand_Include = { "Any" }
do
    local seen = {}
    for _, item in ipairs(StandNameConvert:GetChildren()) do
        if not seen[item.Name] then
            seen[item.Name] = true
            table.insert(Stand_Include, item.Name)
        end
    end
    table.sort(Stand_Include, function(a, b)
        if a == "Any" then return true end
        if b == "Any" then return false end
        return a < b
    end)
end

local Attribute_Include = {
    "Any", "None", "Strong", "Tough", "Sloppy", "Powerful", "Manic", "Enrage",
    "Lethargic", "Godly", "Daemon", "Glass Cannon", "Invincible", "Scourge",
    "Tragic", "Hacker", "Legendary",
}

local Players_Include   = {}
local Items_Include     = {}

--==================================================================
-- 3. STATE
--==================================================================
local Environment       = {}
local Threads           = {}

--==================================================================
-- 4. CONFIG SYSTEM (schema-driven, single debounced save path)
--==================================================================
local ConfigSchema      = {
    { key = "SelectStands",        option = "SelectStands" },
    { key = "SelectAttribute",     option = "SelectAttribute" },
    { key = "SelectArrow",         option = "SelectItemForReroll" },
    { key = "SelectSlot",          option = "SelectSlot" },
    { key = "WebhookInput",        option = "WebhookInput" },
    { key = "AutoSendWebhook",     option = "AutoSendWebhook" },
    { key = "AntiAFK",             option = "AntiAFK" },
    { key = "AutoRejoinWhenKick",  option = "AutoRejoinWhenKick" },
    { key = "AutoRerollStand",     option = "AutoRerollStand" },
    { key = "AutoRerollAttribute", option = "AutoRerollAttribute" },
    { key = "AutoSaveStand",       option = "AutoSaveStand" },
    { key = "AutoHopServer",       option = "AutoHopServer" },
}

local Config            = {}
Config.store            = {}
Config.ready            = false
Config.syncing          = false
Config._queued          = false

local function executorFileSupport()
    return readfile and writefile and isfile and isfolder and makefolder
end

local function findElement(name)
    return Options[name] or Toggles[name]
end

function Config:Read()
    if not executorFileSupport() then
        warn("[Config] executor lacks file API; persistence disabled")
        return
    end
    if not isfolder(saveFolder) then makefolder(saveFolder) end
    if not isfile(fileName) then
        writefile(fileName, HttpService:JSONEncode(self.store))
        return
    end
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(readfile(fileName))
    end)
    if ok and type(decoded) == "table" then
        self.store = decoded
    else
        warn("[Config] save file corrupt; starting fresh")
    end
end

function Config:Write()
    if not self.ready or self.syncing then return end
    if not executorFileSupport() then return end
    for _, entry in ipairs(ConfigSchema) do
        local opt = findElement(entry.option)
        if opt ~= nil and opt.Value ~= nil then
            self.store[entry.key] = opt.Value
        end
    end
    pcall(function()
        writefile(fileName, HttpService:JSONEncode(self.store))
    end)
end

function Config:Request()
    if self._queued then return end
    self._queued = true
    task.delay(0.5, function()
        self._queued = false
        self:Write()
    end)
end

function Config:Apply()
    self.syncing = true
    for _, entry in ipairs(ConfigSchema) do
        local opt = findElement(entry.option)
        local val = self.store[entry.key]
        if opt and val ~= nil then
            pcall(function() opt:SetValue(val) end)
        end
    end
    self.syncing = false
end

--==================================================================
-- 5. COLLECTION (core logic)
--==================================================================
local Collection = {}
Collection.__index = Collection

function Collection:GetBackpack()
    return LocalPlayer:WaitForChild("Backpack")
end

function Collection:RefreshPlayers()
    Players_Include = {}
    for _, v in pairs(Players:GetChildren()) do
        if v ~= LocalPlayer then
            table.insert(Players_Include, tostring(v))
        end
    end
end

function Collection:RefreshItems()
    Items_Include = {}
    for _, v in pairs(self:GetBackpack():GetChildren()) do
        if v:IsA("Tool") then
            table.insert(Items_Include, v.Name)
        end
    end
    table.sort(Items_Include)
    table.insert(Items_Include, 1, "All")
end

function Collection:HasStand(stand)
    local v = Environment.SelectStands and Environment.SelectStands.Value
    return v ~= nil and v[stand] == true
end

function Collection:HasAttribute(attr)
    local v = Environment.SelectAttribute and Environment.SelectAttribute.Value
    return v ~= nil and v[attr] == true
end

function Collection:GetSelectedSlots()
    local list = {}
    local sel  = Environment.SelectSlot and Environment.SelectSlot.Value or {}
    for _, slotName in ipairs(SlotOrder) do
        if sel[slotName] then table.insert(list, slotName) end
    end
    return list
end

function Collection:SlotIsGood(slotName)
    local ref = SlotRefs[slotName]
    if ref.Stand.Value == "None" then return false end
    local standOK = self:HasStand(ref.Stand.Value) or self:HasStand("Any")
    local attriOK = self:HasAttribute(ref.Attribute.Value) or self:HasAttribute("Any")
    return standOK and attriOK
end

function Collection:GetTargetSlot()
    local selected = self:GetSelectedSlots()
    for _, slotName in ipairs(selected) do
        if SlotRefs[slotName].Stand.Value == "None" then return slotName end
    end
    for _, slotName in ipairs(selected) do
        if not self:SlotIsGood(slotName) then return slotName end
    end
    return nil
end

function Collection:SendWebhook(title, description, color, fields)
    local url = Environment.WebhookInput and Environment.WebhookInput.Value
    if not url or url == "" then return end
    if not (Environment.AutoSendWebhook and Environment.AutoSendWebhook.Value) then return end

    local body = HttpService:JSONEncode({
        embeds = { {
            title       = title,
            description = description,
            color       = color,
            fields      = fields,
            footer      = { text = "Stand Upright Auto Reroll | " .. os.date("%d/%m/%Y %I:%M %p") },
        } },
    })

    local request = http_request or request or (syn and syn.request) or (http and http.request)
    if not request then return end

    pcall(function()
        request({
            Url     = url,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = body,
        })
    end)
end

function Collection:UseRerollItem(itemName, conditionFn, isActiveFn, timeout, equipWait)
    timeout    = timeout or 8
    equipWait  = equipWait or 0.4

    local tool = self:GetBackpack():FindFirstChild(itemName)
    if not (tool and tool:IsA("Tool")) then return false end

    local char = LocalPlayer.Character
    if not char then return false end

    local ok = pcall(function()
        tool.Parent = char
        task.wait(equipWait)
        Events.UseItem:FireServer()
        if tool.Parent then
            tool.Parent = self:GetBackpack()
        end
    end)
    if not ok then return false end

    local t = os.clock()
    repeat
        task.wait()
    until conditionFn() or (os.clock() - t) > timeout or (isActiveFn and not isActiveFn())

    return true
end

function Collection:AutoSaveStand()
    if #self:GetSelectedSlots() == 0 then
        Library:Notify("select slot first", 3)
        Environment.AutoSaveStand:SetValue(false)
        return
    end

    while Environment.AutoSaveStand.Value do
        local allGood = true
        for _, slotName in ipairs(self:GetSelectedSlots()) do
            if not self:SlotIsGood(slotName) then
                allGood = false
                break
            end
        end
        if allGood then
            Library:Notify("Out of slot", 5)
            Environment.AutoSaveStand:SetValue(false)
            return
        end

        local standOK = self:HasStand(StandData.Value) or self:HasStand("Any")
        local attriOK = self:HasAttribute(AttriData.Value) or self:HasAttribute("Any")

        if StandData.Value ~= "None" and standOK and attriOK then
            local target = self:GetTargetSlot()
            if target then
                local savedStand, savedAttri = StandData.Value, AttriData.Value
                Events.SwitchStand:FireServer(target)
                local t = os.clock()
                repeat task.wait() until StandData.Value == "None" or (os.clock() - t) > 8

                self:SendWebhook("💾 Saved Stand to " .. target, "Save Stand", 16766720, {
                    { name = "Player",    value = "||" .. LocalPlayer.Name .. "||", inline = false },
                    { name = "Stand",     value = savedStand,                       inline = false },
                    { name = "Attribute", value = savedAttri,                       inline = false },
                    { name = "Slot",      value = target,                           inline = false },
                })
            end
        end

        task.wait(0.3)
    end
end

function Collection:AutoReroll()
    if not (Environment.SelectItemForReroll and Environment.SelectItemForReroll.Value) then
        Library:Notify("Select arrow first", 3)
        Environment.AutoRerollStand:SetValue(false)
        return
    end

    local function stillOn() return Environment.AutoRerollStand.Value end

    while stillOn() do
        local standOK = self:HasStand(StandData.Value) or self:HasStand("Any")
        local attriOK = self:HasAttribute(AttriData.Value) or self:HasAttribute("Any")

        if StandData.Value ~= "None" and standOK and attriOK then
            if not (Environment.AutoSaveStand and Environment.AutoSaveStand.Value) then
                self:SendWebhook("Got Stand: " .. StandData.Value,
                    "**Desired stand acquired!** Keeping it.", 65280, {
                        { name = "Player",    value = "||" .. LocalPlayer.Name .. "||", inline = false },
                        { name = "Stand",     value = StandData.Value,                  inline = false },
                        { name = "Attribute", value = AttriData.Value,                  inline = false },
                    })
                Library:Notify("Found: " .. StandData.Value .. " (" .. AttriData.Value .. ")", 5)
                Environment.AutoRerollStand:SetValue(false)
                return
            end
            task.wait(0.2)
        elseif StandData.Value == "None" then
            local itemName = Environment.SelectItemForReroll.Value
            local used = self:UseRerollItem(itemName, function()
                return StandData.Value ~= "None"
            end, stillOn)
            if not used then
                Library:Notify("Out of " .. tostring(itemName) .. ", stopped", 5)
                Environment.AutoRerollStand:SetValue(false)
                return
            end
        else
            local oldStand, oldAttri = StandData.Value, AttriData.Value
            local used = self:UseRerollItem("Rokakaka", function()
                return StandData.Value ~= oldStand or AttriData.Value ~= oldAttri
            end, stillOn)
            if not used then
                Library:Notify("Out of Rokakaka, stopped", 5)
                Environment.AutoRerollStand:SetValue(false)
                return
            end
        end

        task.wait(0.35)
    end
end

-- ---- auto reroll attribute (Trait Orb on equipped stand) ----
-- Re-equips the orb each iteration in case the game auto-unequips it.
function Collection:AutoRerollAttribute()
    if StandData.Value == "None" then
        Library:Notify("You must have stand equip", 4)
        Environment.AutoRerollAttribute:SetValue(false)
        return
    end
    if not (Environment.SelectAttribute and next(Environment.SelectAttribute.Value or {})) then
        Library:Notify("Select attribute first", 3)
        Environment.AutoRerollAttribute:SetValue(false)
        return
    end

    local function stillOn() return Environment.AutoRerollAttribute.Value end

    while stillOn() do
        if StandData.Value == "None" then
            Library:Notify("You must have stand equip", 4)
            break
        end

        -- got desired attribute -> stop
        if self:HasAttribute(AttriData.Value) or self:HasAttribute("Any") then
            self:SendWebhook("Got Attribute: " .. AttriData.Value,
                "**Desired attribute acquired!**", 65280, {
                    { name = "Player",    value = "||" .. LocalPlayer.Name .. "||", inline = false },
                    { name = "Stand",     value = StandData.Value,                  inline = false },
                    { name = "Attribute", value = AttriData.Value,                  inline = false },
                })
            Library:Notify("Found attribute: " .. AttriData.Value, 5)
            break
        end

        local char = LocalPlayer.Character
        if not char then
            task.wait(0.1); continue
        end

        local orb = self:GetBackpack():FindFirstChild("Trait Orb") or char:FindFirstChild("Trait Orb")

        if not (orb and orb:IsA("Tool")) then
            Library:Notify("Start Rollback", 6)
            Events.loadClientSettings:FireServer({ {
                skipItemPromptSetting = false,
                lowFXModeSetting = "\xFF",
                blurToggle = true,
                toggleTradingSetting = true,
                markerToggle = false,
                experimentalMousePointerSetting = false,
                musicToggle = true,
                toggleInventorySetting = true,
                newItemIconSetting = true,
            } })
            task.wait()
            TeleportService:Teleport(PlaceId, LocalPlayer)
            return
        end

        -- equip if not already equipped (re-equip if the game unequipped it)
        if orb.Parent ~= char then
            pcall(function() orb.Parent = char end)
            task.wait(0.1)
        end

        local oldAttri = AttriData.Value
        pcall(function() Events.UseItem:FireServer() end)

        -- wait for attribute to change (short timeout to stay responsive)
        local t = os.clock()
        repeat task.wait() until AttriData.Value ~= oldAttri or (os.clock() - t) > 1.5 or not stillOn()

        task.wait(0.05)
    end

    Environment.AutoRerollAttribute:SetValue(false)
end

function Collection:HopServer()
    local servers = {}
    local ok, body = pcall(function()
        return HttpService:JSONDecode(game:HttpGet( "https://games.roblox.com/v1/games/" .. PlaceId .. "/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true"))
    end)

    if ok and body and body.data then
        for _, v in next, body.data do
            if type(v) == "table" and tonumber(v.playing) and tonumber(v.maxPlayers)
                and v.playing < v.maxPlayers and v.id ~= game.JobId then
                table.insert(servers, v.id)
            end
        end
    end

    if #servers > 0 then
        TeleportService:TeleportToPlaceInstance(PlaceId, servers[math.random(1, #servers)], LocalPlayer)
    else
        Library:Notify("Serverhop: couldn't find a server", 5)
    end
end

function Collection:AutoHopServer()
    while Environment.AutoHopServer.Value do
        if ServerAge.Value >= 10800 then self:HopServer() end
        task.wait(1)
    end
end

function Collection:StartRejoinKick()
    if self.RejoinConnection then return end
    local promptOverlay = CoreGui.RobloxPromptGui.promptOverlay

    local function checkPrompt(prompt)
        if not (Environment.AutoRejoinWhenKick and Environment.AutoRejoinWhenKick.Value) then return end
        if prompt.Name == "ErrorPrompt"
            and prompt:FindFirstChild("MessageArea")
            and prompt.MessageArea:FindFirstChild("ErrorFrame") then
            pcall(function() TeleportService:Teleport(PlaceId) end)
        end
    end

    for _, prompt in ipairs(promptOverlay:GetChildren()) do
        task.spawn(checkPrompt, prompt)
    end
    self.RejoinConnection = promptOverlay.ChildAdded:Connect(checkPrompt)
end

function Collection:StopRejoinKick()
    if self.RejoinConnection then
        self.RejoinConnection:Disconnect()
        self.RejoinConnection = nil
    end
end

function Collection:StartAntiAFK()
    if self.AntiAFKConnection then return end
    self.AntiAFKConnection = LocalPlayer.Idled:Connect(function()
        if Environment.AntiAFK and Environment.AntiAFK.Value then
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end
    end)
end

function Collection:StopAntiAFK()
    if self.AntiAFKConnection then
        self.AntiAFKConnection:Disconnect()
        self.AntiAFKConnection = nil
    end
end

function Collection:RunThread(name, fn)
    if Threads[name] then
        task.cancel(Threads[name]); Threads[name] = nil
    end
    Threads[name] = task.spawn(fn)
end

function Collection:KillThread(name)
    if Threads[name] then
        task.cancel(Threads[name]); Threads[name] = nil
    end
end

function Collection:DisconnectAll()
    for name in pairs(Threads) do self:KillThread(name) end
    self:StopRejoinKick()
    self:StopAntiAFK()
    if Environment.AutoSaveStand then Environment.AutoSaveStand:SetValue(false) end
    if Environment.AutoRerollStand then Environment.AutoRerollStand:SetValue(false) end
    if Environment.AutoRerollAttribute then Environment.AutoRerollAttribute:SetValue(false) end
end

--==================================================================
-- INITIAL DATA LOAD (before UI so dropdowns have values)
--==================================================================
Config:Read()
Collection:RefreshItems()
Collection:RefreshPlayers()

--==================================================================
-- 6. UI
--==================================================================
local repo            = "https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/"
local Library         = loadstring(game:HttpGet("https://raw.githubusercontent.com/xQuartyx/UILibrary/refs/heads/main/LinoriaLib/Library.lua"))()
local ThemeManager    = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local SaveManager     = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()

local RAMAccount = loadstring(game:HttpGet'https://raw.githubusercontent.com/ic3w0lf22/Roblox-Account-Manager/master/RAMAccount.lua')()

local MyAccount = RAMAccount.new(LocalPlayer.Name)

local Window          = Library:CreateWindow({
    Title        = "Stand Upright: Rebooted | " .. game.PlaceVersion,
    Center       = true,
    AutoShow     = true,
    TabPadding   = 8,
    MenuFadeTime = 0,
})

local Tabs            = {
    Main            = Window:AddTab("Main"),
    ["UI Settings"] = Window:AddTab("UI Settings"),
}

local TradingGroupBox = Tabs.Main:AddLeftGroupbox("Trade helper ⚖️")
local MiscTabbox      = Tabs.Main:AddLeftTabbox()
local KetchupGroupBox = Tabs.Main:AddLeftGroupbox("Ketchup 🍅")
local UserGroupBox    = Tabs.Main:AddRightGroupbox("User 👤")
local StandGroupBox   = Tabs.Main:AddRightGroupbox("Stand reroll 🗿")
local ServerGroupBox  = Tabs["UI Settings"]:AddRightGroupbox("Server 🌐")

-- ---------- Trade helper ----------
TradingGroupBox:AddDropdown("MyDropdown", {
    Values = Players_Include,
    Default = 1,
    Multi = false,
    Text = "Select player",
    Tooltip = "Select player for trade",
    Callback = function() end,
})

local SendTrade = TradingGroupBox:AddButton({
    Text = "Send",
    Func = function() Events.UICMDS:FireServer(Options.MyDropdown.Value, "Trade") end,
    DoubleClick = false,
})
SendTrade:AddButton({
    Text = "Refresh",
    Func = function()
        Collection:RefreshPlayers()
        Options.MyDropdown:SetValues(Players_Include)
    end,
    DoubleClick = false,
})

TradingGroupBox:AddDivider()

TradingGroupBox:AddDropdown("TradingItemDropDown", {
    Values = Items_Include,
    Default = 1,
    Multi = true,
    Text = "Select items",
    Callback = function() end,
})

TradingGroupBox:AddInput("AmountItemsTextBox", {
    Default = nil,
    Numeric = true,
    Finished = false,
    Text = "Amount Items",
    Placeholder = 1,
    Callback = function() end,
})

local AddItemsBtn = TradingGroupBox:AddButton({
    Text = "Add items",
    Func = function()
        local amount   = tonumber(Options.AmountItemsTextBox.Value)
        local selected = Options.TradingItemDropDown.Value

        local function add(itemName)
            TradeEvents.TradeComm:FireServer("AddItem", { ItemName = itemName, Amount = amount })
            task.wait()
        end

        if selected["All"] then
            for _, itemName in ipairs(Items_Include) do
                if itemName ~= "All" then add(itemName) end
            end
        else
            for itemName, isSelected in pairs(selected) do
                if isSelected then add(itemName) end
            end
        end

        task.wait()
        TradeEvents.TradeComm:FireServer("AcceptTrade")
    end,
    DoubleClick = false,
})
AddItemsBtn:AddButton({
    Text = "Refresh",
    Func = function()
        Collection:RefreshItems()
        Options.TradingItemDropDown:SetValues(Items_Include)
    end,
    DoubleClick = false,
})

-- ---------- User ----------
Environment.CurrentLabel = UserGroupBox:AddLabel("Current: N/A")
UserGroupBox:AddDivider()

local SlotLabels = {}
for _, slotName in ipairs(SlotOrder) do
    SlotLabels[slotName] = UserGroupBox:AddLabel(slotName .. ": N/A")
end

local function updateCurrentLabel()
    pcall(function()
        Environment.CurrentLabel:SetText("Current: " .. StandData.Value .. " (" .. AttriData.Value .. ")")
    end)
end

local function updateSlotLabel(slotName)
    pcall(function()
        local ref = SlotRefs[slotName]
        SlotLabels[slotName]:SetText(slotName .. ": " .. ref.Stand.Value .. " (" .. ref.Attribute.Value .. ")")
    end)
end

StandData:GetPropertyChangedSignal("Value"):Connect(updateCurrentLabel)
AttriData:GetPropertyChangedSignal("Value"):Connect(updateCurrentLabel)
updateCurrentLabel()

for _, slotName in ipairs(SlotOrder) do
    local ref = SlotRefs[slotName]
    ref.Stand:GetPropertyChangedSignal("Value"):Connect(function() updateSlotLabel(slotName) end)
    ref.Attribute:GetPropertyChangedSignal("Value"):Connect(function() updateSlotLabel(slotName) end)
    updateSlotLabel(slotName)
end

UserGroupBox:AddDivider()
UserGroupBox:AddLabel("Slot")

Environment.SelectSlot = UserGroupBox:AddDropdown("SelectSlot", {
    Values = SlotOrder,
    Default = 1,
    Multi = true,
    Text = "Select slot for save stand",
    Callback = function() end,
})

Environment.AutoSaveStand = UserGroupBox:AddToggle("AutoSaveStand", {
    Text = "Auto Save Stands",
    Default = false,
    Tooltip = "Save stands to selected slot (fills empty/None slots first)",
    Callback = function(value)
        if Config.syncing then return end
        if value then
            Collection:RunThread("AutoSaveStand", function() Collection:AutoSaveStand() end)
        else
            Collection:KillThread("AutoSaveStand")
        end
    end,
})

UserGroupBox:AddButton({
    Text = "Open Storage",
    Func = function()
        workspace:WaitForChild("Map"):WaitForChild("NPCs")
            :WaitForChild("admpn"):WaitForChild("Done"):FireServer()
    end,
    DoubleClick = false,
})

-- ---------- Stand reroll ----------
Environment.SelectStands = StandGroupBox:AddDropdown("SelectStands", {
    Values = Stand_Include,
    Default = {},
    Multi = true,
    Text = "Select stands",
    Callback = function() end,
})

Environment.SelectAttribute = StandGroupBox:AddDropdown("SelectAttribute", {
    Values = Attribute_Include,
    Default = {},
    Multi = true,
    Text = "Select attributes",
    Callback = function() end,
})

Environment.SelectItemForReroll = StandGroupBox:AddDropdown("SelectItemForReroll", {
    Values = { "Stand Arrow", "Charged Arrow" },
    Default = 1,
    Multi = false,
    Text = "Select arrow",
    Callback = function() end,
})

Environment.AutoRerollStand = StandGroupBox:AddToggle("AutoRerollStand", {
    Text = "Auto Reroll Stand",
    Default = false,
    Tooltip = "Reroll until desired stand & attribute",
    Callback = function(value)
        if Config.syncing then return end
        if value then
            Collection:RunThread("AutoReroll", function() Collection:AutoReroll() end)
        else
            Collection:KillThread("AutoReroll")
        end
    end,
})

Environment.AutoRerollAttribute = StandGroupBox:AddToggle("AutoRerollAttribute", {
    Text = "Auto Reroll Attribute",
    Default = false,
    Tooltip = "Use Trait Orb to reroll attribute of equipped stand",
    Callback = function(value)
        if Config.syncing then return end
        if value then
            Collection:RunThread("AutoRerollAttribute", function() Collection:AutoRerollAttribute() end)
        else
            Collection:KillThread("AutoRerollAttribute")
        end
    end,
})

-- ---------- Misc tab ----------
local MiscTab = MiscTabbox:AddTab("Misc")

MiscTab:AddButton({
    Text = "Rollback ⛓️‍💥",
    Func = function()
        Events.loadClientSettings:FireServer({ {
            skipItemPromptSetting = false,
            lowFXModeSetting = "\xFF",
            blurToggle = true,
            toggleTradingSetting = true,
            markerToggle = false,
            experimentalMousePointerSetting = false,
            musicToggle = true,
            toggleInventorySetting = true,
            newItemIconSetting = true,
        } })
        task.wait()
        Library:Notify("Rollback success", 5)
    end,
    DoubleClick = false,
})

MiscTab:AddButton({
    Text = "Rejoin 🔄",
    Func = function() TeleportService:Teleport(PlaceId, LocalPlayer) end,
    DoubleClick = false,
})

function Collection:BuildStandDescription()
    local parts = {}

    if StandData.Value ~= "None" then
        table.insert(parts, StandData.Value .. " (" .. AttriData.Value .. ")")
    end

    for _, slotName in ipairs(SlotOrder) do
        local ref = SlotRefs[slotName]
        if ref.Stand.Value ~= "None" then
            table.insert(parts, ref.Stand.Value .. " (" .. ref.Attribute.Value .. ")")
        end
    end

    return table.concat(parts, "\n")
end

MiscTab:AddButton({
    Text = "Set Desc",
    Func = function() MyAccount:SetDescription(Collection:BuildStandDescription()) end,
    DoubleClick = false,
})

-- ---------- Ketchup tab ----------

Environment.CurrentLevelKetchupLabel = KetchupGroupBox:AddLabel("Level : " .. CurrentLevel.Value .. " → " .. "N/A")
Environment.TotalKetchupLabel = KetchupGroupBox:AddLabel("Total Ketchup : N/A" .. " 🥫")

KetchupGroupBox:AddInput("AmountLevelTextBox", {
    Default = nil,
    Numeric = true,
    Finished = false,
    Text = "Amount Level",
    Placeholder = 1,
    Callback = function() end,
})

KetchupGroupBox:AddButton({
    Text = "Calculate",
    Func = function()
        local function comma(n)
            local s = tostring(math.floor(n))
            local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
            return (out:gsub("^,", ""))
        end

        local function expForLevel(L)
            return (30 * 3 * (L * L / 10)) + 20
        end

        local fromLevel = tonumber(CurrentLevel.Value) or 1
        local toLevel   = tonumber(Options.AmountLevelTextBox.Value)

        if not toLevel then
            Library:Notify("Enter target level first", 3)
            return
        end
        if toLevel <= fromLevel then
            Library:Notify("Target level must be higher than current level (" .. fromLevel .. ")", 4)
            return
        end

        local totalExp = 0
        for L = fromLevel, toLevel - 1 do
            totalExp = totalExp + expForLevel(L)
        end

        local totalKetchup = math.ceil(totalExp / 100)

        Environment.CurrentLevelKetchupLabel:SetText(
            string.format("Level : %d → %d", fromLevel, toLevel))
        Environment.TotalKetchupLabel:SetText(
            string.format("Total Ketchup : %s 🥫", comma(totalKetchup)))
    end,
    DoubleClick = false,
})


-- ---------- Webhook tab ----------
local WebhookTab = MiscTabbox:AddTab("Webhook")

Environment.WebhookInput = WebhookTab:AddInput("WebhookInput", {
    Default = "",
    Numeric = false,
    Finished = false,
    Text = "Webhook",
    Placeholder = "",
    Callback = function() end,
})

Environment.AutoSendWebhook = WebhookTab:AddToggle("AutoSendWebhook", {
    Text = "Webhook",
    Default = false,
    Tooltip = "Send webhook when reroll stand",
    Callback = function() end,
})

-- ---------- Server settings ----------
Environment.AntiAFK = ServerGroupBox:AddToggle("AntiAFK", {
    Text = "Anti AFK",
    Default = true,
    Tooltip = "Prevents AFK kicks",
    Callback = function(value)
        if value then Collection:StartAntiAFK() else Collection:StopAntiAFK() end
    end,
})

Environment.AutoHopServer = ServerGroupBox:AddToggle("AutoHopServer", {
    Text = "Auto Hop Server",
    Default = false,
    Tooltip = "Hop when server age is 3 hrs+",
    Callback = function(value)
        if Config.syncing then return end
        if value then
            Collection:RunThread("AutoHop", function() Collection:AutoHopServer() end)
        else
            Collection:KillThread("AutoHop")
        end
    end,
})

Environment.AutoRejoinWhenKick = ServerGroupBox:AddToggle("AutoRejoinWhenKick", {
    Text = "Auto Rejoin When Disconnect",
    Default = true,
    Tooltip = "Rejoin automatically on kick",
    Callback = function(value)
        if value then Collection:StartRejoinKick() else Collection:StopRejoinKick() end
    end,
})

-- ---------- UI Settings tab ----------
Library.KeybindFrame.Visible = true

Library:OnUnload(function()
    print("Unloaded!")
    Collection:DisconnectAll()
    Library.Unloaded = true
end)

local MenuGroup = Tabs["UI Settings"]:AddLeftGroupbox("Menu")
MenuGroup:AddButton("Unload", function() Library:Unload() end)
MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "L", NoUI = false, Text = "Menu keybind" })
Library.ToggleKeybind = Options.MenuKeybind

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
ThemeManager:SetFolder("MyScriptHub")
SaveManager:SetFolder("MyScriptHub/specific-game")
SaveManager:BuildConfigSection(Tabs["UI Settings"])
ThemeManager:ApplyToTab(Tabs["UI Settings"])
SaveManager:LoadAutoloadConfig()

--==================================================================
-- 7. INIT
--==================================================================
Config:Apply()

local function resumeIfOn(toggleName, threadName, fn)
    local tgl = Toggles[toggleName]
    if tgl and tgl.Value == true then
        Collection:RunThread(threadName, fn)
    end
end

resumeIfOn("AutoRerollStand", "AutoReroll", function() Collection:AutoReroll() end)
resumeIfOn("AutoSaveStand", "AutoSaveStand", function() Collection:AutoSaveStand() end)
resumeIfOn("AutoHopServer", "AutoHop", function() Collection:AutoHopServer() end)
resumeIfOn("AutoRerollAttribute", "AutoRerollAttribute", function() Collection:AutoRerollAttribute() end)

for _, opt in pairs(Options) do
    if opt.OnChanged then opt:OnChanged(function() Config:Request() end) end
end
for _, tgl in pairs(Toggles) do
    if tgl.OnChanged then tgl:OnChanged(function() Config:Request() end) end
end

Config.ready = true
Config:Write()

Library:Notify("Script loaded in " .. string.format("%.2f s", os.clock() - startTime), 5)
