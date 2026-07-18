local TeleportService, GuiService, plr = game:GetService("TeleportService"), game:GetService("GuiService"),
    game:GetService("Players").LocalPlayer

local autoRejoinEnabled = true -- default: เปิด
local earlyRejoinConn = GuiService.ErrorMessageChanged:Connect(function()
  if not autoRejoinEnabled then return end
  if GuiService:GetErrorMessage() ~= "" then TeleportService:Teleport(game.PlaceId, plr) end
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

--==================================================================
-- BOOTSTRAP — กดผ่านหน้าจอตอนเข้าเกม
--==================================================================
-- ยิง MouseButton1Click ของปุ่มโดยไม่ต้องขยับเมาส์จริง
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
    elseif getconnections then
      for _, conn in pairs(getconnections(button.MouseButton1Click)) do
        conn:Fire()
      end
    end
  end))
end

-- ปิด changelog
clickButton(function()
  local cl = PlayerGui:FindFirstChild("Changelogs")
  return cl and cl:FindFirstChild("Frame") and cl.Frame:FindFirstChild("TextButton")
end, 10)

task.wait(0.5)

-- กด Play
clickButton(function()
  local menu = PlayerGui:FindFirstChild("MenuGUI")
  return menu and menu:FindFirstChild("Play")
end, 10)

-- รอ inventory โหลด (มี timeout กันค้างถ้าโหลดไม่เสร็จ)
do
  local itemsLoaded = LocalPlayer:FindFirstChild("ItemsLoaded")
  local t = os.clock()
  repeat
    task.wait(0.1)
    itemsLoaded = itemsLoaded or LocalPlayer:FindFirstChild("ItemsLoaded")
  until (itemsLoaded and itemsLoaded.Value) or (os.clock() - t) > 60
end

local Data         = LocalPlayer:WaitForChild("Data")
local StandData    = Data.Stand
local AttriData    = Data.Attri
local CurrentLevel = Data.Level
local ServerAge    = workspace.Age

local SlotOrder    = { "Slot1", "Slot2", "Slot3", "Slot4", "Slot5" }
local SlotRefs     = {}
for i, slotName in ipairs(SlotOrder) do
  SlotRefs[slotName] = {
    Stand     = Data[slotName .. "Stand"],
    Attribute = Data[slotName .. "Attri"],
  }
end

local cascade    = loadstring(game:HttpGet("https://github.com/biggaboy212/Cascade/releases/download/v1.2.0/dist.luau"))()

--==================================================================
-- 1. CONFIG SYSTEM (registry-driven, debounced save)
--==================================================================
local saveFolder = "C-test"
local fileName   = saveFolder .. "/Stand-" .. LocalPlayer.Name .. ".json"

local Config     = {}
Config.store     = {}
Config.elements  = {}
Config.ready     = false
Config.syncing   = false
Config._queued   = false

local function fileSupport()
  return readfile and writefile and isfile and isfolder and makefolder
end

function Config:Register(key, getFn, setFn)
  self.elements[key] = { get = getFn, set = setFn }
end

function Config:Read()
  if not fileSupport() then
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
  if not fileSupport() then return end

  for key, el in pairs(self.elements) do
    local ok, val = pcall(el.get)
    if ok and val ~= nil then
      self.store[key] = val
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
  for key, el in pairs(self.elements) do
    local val = self.store[key]
    if val ~= nil then
      pcall(el.set, val)
    end
  end
  self.syncing = false
end

Config:Read()

--==================================================================
-- LIFECYCLE (thread + connection manager, cleanup on unload)
--==================================================================
local window -- forward declare (สร้างจริงในหัวข้อ APP + WINDOW)
local Auto   -- forward declare (สร้างจริงในหัวข้อ AUTOMATION — Lifecycle ต้องใช้)

local Lifecycle       = {}
Lifecycle.connections = {}
Lifecycle.unloaded    = false
Lifecycle.onUnload    = {} -- callback เพิ่มเติมที่อยากให้รันตอน unload

-- ผูก signal ผ่านตัวนี้ เพื่อให้ disconnect อัตโนมัติตอน unload
function Lifecycle:Connect(signal, fn)
  local conn = signal:Connect(fn)
  table.insert(self.connections, conn)
  return conn
end

-- ฝาก connection ที่สร้างเองไว้ให้จัดการ
function Lifecycle:Track(conn)
  if conn then table.insert(self.connections, conn) end
  return conn
end

function Lifecycle:AddCleanup(fn)
  table.insert(self.onUnload, fn)
end

-- ฝาก connection ที่ผูกไว้ตั้งแต่ก่อน Lifecycle เกิด
Lifecycle:Track(earlyRejoinConn)

function Lifecycle:Unload()
  if self.unloaded then return end
  self.unloaded = true

  -- 1. save ครั้งสุดท้าย (ตอนนี้ค่า toggle ยังเป็นของจริง)
  pcall(function() Config:Write() end)

  -- 2. ปิด gate ห้ามเขียนอีก — ต้องปิดก่อนหยุด loop
  --    ไม่งั้นถ้ามีอะไรไป set toggle=false มันจะ save ทับด้วยค่า false
  Config.ready = false

  -- 3. หยุด loop ทั้งหมด (ครอบ pcall กันพลาดแล้วข้ามขั้นที่เหลือ)
  pcall(function()
    if not Auto then return end
    for key in pairs(Auto.state) do
      Auto.state[key] = false
    end
    -- เก็บชื่อก่อน แล้วค่อย cancel กันปัญหาแก้ table ระหว่างวน
    local names = {}
    for name in pairs(Auto.threads) do
      table.insert(names, name)
    end
    for _, name in ipairs(names) do
      Auto:KillThread(name)
    end
    -- thread อาจโดน cancel ระหว่างถือ lock อยู่ → ปลดทิ้ง
    Auto.useLock = false
  end)

  -- 4. disconnect ทุก signal ที่ผูกไว้
  for _, conn in ipairs(self.connections) do
    pcall(function() conn:Disconnect() end)
  end
  table.clear(self.connections)

  -- 5. cleanup เพิ่มเติมที่ฝากไว้
  for _, fn in ipairs(self.onUnload) do
    pcall(fn)
  end
  table.clear(self.onUnload)

  -- 6. ทำลาย UI
  pcall(function()
    if window and window.__instance then
      window.__instance:Destroy()
    end
  end)

  print("[Script] unloaded — threads stopped, connections disconnected")
end

--==================================================================
-- 2. DATA
--==================================================================
local comboList = {}

local StandNameConvert = ReplicatedStorage.StandNameConvert

local STAND_OPTIONS = { "Any" }
do
  local seen = {}
  for _, item in ipairs(StandNameConvert:GetChildren()) do
    if not seen[item.Name] then
      seen[item.Name] = true
      table.insert(STAND_OPTIONS, item.Name)
    end
  end
  table.sort(STAND_OPTIONS, function(a, b)
    if a == "Any" then return true end
    if b == "Any" then return false end
    return a < b
  end)
end

local ATTRIBUTE_OPTIONS = {
  "Any", "None", "Strong", "Tough", "Sloppy", "Powerful", "Manic", "Enrage",
  "Lethargic", "Godly", "Daemon", "Glass Cannon", "Invincible", "Scourge",
  "Tragic", "Hacker", "Legendary",
}

--==================================================================
-- 3. AUTOMATION CORE
--==================================================================
-- STRICT_SLOT_MATCH:
--   true  = slot ถือว่า "เก็บไว้" เมื่อ stand+attribute ตรง combo ทั้งคู่
--           (DTW ที่ attribute ไม่ตรง = ของไม่ต้องการ → ทับได้)
--   false = slot ถือว่า "เก็บไว้" แค่ stand อยู่ใน combo (ไม่สน attribute)
local STRICT_SLOT_MATCH = true

local app -- forward declare (สร้างจริงในหัวข้อ 4, Auto loop ใช้ตัวนี้)

Auto                    = {}
Auto.threads            = {}
Auto.state              = { -- ตัวคุม loop จริง (แยกจาก UI toggle)
  saveStand   = false,
  rerollStand = false,
  rerollAttri = false,
  doubleOrb   = false,
  hopServer   = false,
}
Auto.hopAfterSeconds    = 10800 -- server อายุเกินเท่านี้ = hop (default 3 ชม.)

-- ---- จังหวะของ Auto Reroll Attribute (ปรับได้จาก dropdown "Reroll speed") ----
Auto.rerollTimeout      = 1.5 -- รอ server ตอบนานสุดกี่วิ ก่อนยิงรอบใหม่
Auto.rerollEquipWait    = 0.1 -- รอหลัง equip orb (เฉพาะตอนต้อง equip ใหม่)
Auto.rerollDelay        = 0   -- เว้นจังหวะท้ายรอบ (0 = รัวสุด)
Auto.toggles            = {}  -- เก็บ reference ของ toggle ไว้ปิดจากในโค้ด

--------------------------------------------------------------------
-- USE-ITEM LOCK
-- Events.UseItem:FireServer() ไม่มี argument — server ดูจาก "tool ที่ถืออยู่"
-- ถ้าหลาย loop equip พร้อมกันจะใช้ผิดชิ้น (เช่น reroll stand ไปยิงโดน 2x Orb)
-- ทุก loop ที่จะยิง UseItem ต้องจอง lock ก่อน แล้วถอด tool อื่นออกให้หมด
--------------------------------------------------------------------
Auto.useLock            = false

function Auto:AcquireUse(stillOn, timeout)
  timeout = timeout or 15
  local t = os.clock()
  while self.useLock do
    if stillOn and not stillOn() then return false end
    if (os.clock() - t) > timeout then return false end
    task.wait(0.05)
  end
  self.useLock = true
  return true
end

function Auto:ReleaseUse()
  self.useLock = false
end

-- ถอด tool อื่นกลับกระเป๋า เหลือถือแต่ตัวที่จะใช้
function Auto:UnequipOthers(char, keep)
  local bp = LocalPlayer:FindFirstChild("Backpack")
  if not (bp and char) then return end
  for _, t in ipairs(char:GetChildren()) do
    if t:IsA("Tool") and t ~= keep then
      pcall(function() t.Parent = bp end)
    end
  end
end

function Auto:RunThread(name, fn)
  if self.threads[name] then
    task.cancel(self.threads[name])
    self.threads[name] = nil
  end
  self.threads[name] = task.spawn(fn)
end

function Auto:KillThread(name)
  if self.threads[name] then
    task.cancel(self.threads[name])
    self.threads[name] = nil
  end
end

-- ปิด toggle จากในโค้ด (อัปเดตทั้ง state และ UI)
function Auto:Stop(key, toggleName, message)
  self.state[key] = false
  local tgl = self.toggles[toggleName]
  if tgl then pcall(function() tgl.Value = false end) end
  if message then
    app:Notification({ Title = "Stopped", Subtitle = message, Duration = 4 })
  end
end

-- ---- webhook ----
-- ส่งเฉพาะเมื่อเปิด toggle และใส่ URL แล้ว
function Auto:SendWebhook(title, description, color, fields)
  local url = self.webhookUrl
  if not url or url == "" then return end
  if not (self.toggles.AutoSendWebhook and self.toggles.AutoSendWebhook.Value) then return end

  local body = HttpService:JSONEncode({
    embeds = { {
      title       = title,
      description = description,
      color       = color,
      fields      = fields,
      footer      = { text = "Stand Upright | " .. os.date("%d/%m/%Y %I:%M %p") },
    } },
  })

  local request = http_request or request
      or (syn and syn.request) or (http and http.request)
  if not request then return end

  task.spawn(function()
    pcall(function()
      request({
        Url     = url,
        Method  = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body    = body,
      })
    end)
  end)
end

-- ---- combo matching ----
-- stand ตัวนี้อยู่ใน combo ไหม (ไม่สน attribute)
local function standInCombo(standName)
  for _, combo in ipairs(comboList) do
    if combo.stand == "Any" or combo.stand == standName then
      return true
    end
  end
  return false
end

-- stand + attribute ตรงกับ combo ใด combo หนึ่งไหม
local function matchesCombo(standName, attriName)
  for _, combo in ipairs(comboList) do
    if combo.stand == "Any" or combo.stand == standName then
      for _, a in ipairs(combo.attributes) do
        if a == "Any" or a == attriName then
          return true
        end
      end
    end
  end
  return false
end

-- ---- reroll completion signal ----
-- server ยิง notif ทุกครั้งที่ reroll เสร็จ (แม้ได้ attribute เดิม)
--   v4:FireClient(plr, "🎲 Trait rerolled! You received: " .. attri)
-- ใช้เป็นสัญญาณ "เสร็จแล้ว" ได้ ดีกว่ารอค่าเปลี่ยน เพราะถ้าสุ่มได้ค่าเดิม
-- การรอค่าเปลี่ยนจะค้างจนครบ timeout เปล่าๆ
Auto.rerollDone = false
do
  local notif = Events:FindFirstChild("GeneralNotif")
      or Events:FindFirstChild("ItemNotifEvent")
  if notif and notif:IsA("RemoteEvent") then
    Lifecycle:Connect(notif.OnClientEvent, function(msg)
      if type(msg) == "string" then
        local m = msg:lower()
        if m:find("reroll") or m:find("received") then
          Auto.rerollDone = true
        end
      end
    end)
  end
end

-- ---- rollback ----
-- ยิง client settings ที่ผิด type ให้ save พัง → ข้อมูลย้อนกลับตอน rejoin
function Auto:Rollback()
  return (pcall(function()
    Events.loadClientSettings:FireServer({ {
      skipItemPromptSetting           = false,
      lowFXModeSetting                = "\xFF",
      blurToggle                      = true,
      toggleTradingSetting            = true,
      markerToggle                    = false,
      experimentalMousePointerSetting = false,
      musicToggle                     = true,
      toggleInventorySetting          = true,
      newItemIconSetting              = true,
    } })
  end))
end

-- ---- attribute dropdown (ใช้กับ Auto Reroll Attribute — ไม่เกี่ยวกับ combo) ----
-- คืนชื่อ attribute ที่ติ๊กไว้ใน dropdown "Select attributes"
function Auto:GetSelectedAttributes()
  local picker = self.attriPicker
  local list = {}
  if not picker then return list end
  for _, idx in ipairs(picker.Value or {}) do
    local name = picker.Options[idx]
    if name then table.insert(list, name) end
  end
  return list
end

-- attribute ตัวนี้อยู่ใน dropdown ที่เลือกไว้ไหม
function Auto:AttributeSelected(attriName)
  for _, a in ipairs(self:GetSelectedAttributes()) do
    if a == "Any" or a == attriName then
      return true
    end
  end
  return false
end

-- slot นี้เป็นของที่อยากเก็บไหม
local function slotIsKeeper(slotName)
  local ref = SlotRefs[slotName]
  if ref.Stand.Value == "None" then return false end
  if STRICT_SLOT_MATCH then
    return matchesCombo(ref.Stand.Value, ref.Attribute.Value)
  end
  return standInCombo(ref.Stand.Value)
end

-- ---- character / item helpers ----
-- รอจนตัวละครพร้อมใช้งาน (เกิดใหม่เสร็จ + ยังไม่ตาย)
local function waitForCharacter(timeout, stillOn)
  timeout = timeout or 30
  local t = os.clock()
  repeat
    if stillOn and not stillOn() then return nil end
    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if char and hum and hrp and hum.Health > 0 then
      return char, hum
    end
    task.wait(0.2)
  until (os.clock() - t) > timeout
  return nil
end

-- หา tool ทั้งใน Backpack และบนตัว (เผื่อ equip ค้าง)
local function findTool(itemName)
  local bp = LocalPlayer:FindFirstChild("Backpack")
  local char = LocalPlayer.Character
  local tool = (bp and bp:FindFirstChild(itemName)) or (char and char:FindFirstChild(itemName))
  if tool and tool:IsA("Tool") then return tool end
  return nil
end

-- ใช้ item หนึ่งครั้ง แล้วรอจน condition เป็นจริง
-- คืน:  true  = ใช้สำเร็จ
--       false = ของหมดจริง (รอแล้วยังไม่มี)
--       nil   = ถูกสั่งหยุดกลางทาง
function Auto:UseItem(itemName, conditionFn, stillOn, timeout, equipWait)
  timeout    = timeout or 8
  equipWait  = equipWait or 0.4

  -- รอตัวละครพร้อม (ถ้าเพิ่งตาย จะรอจนเกิดใหม่)
  local char = waitForCharacter(30, stillOn)
  if not char then
    if stillOn and not stillOn() then return nil end -- ถูกสั่งหยุด
    return false                                     -- รอเกิดไม่สำเร็จจริง
  end

  -- รอ tool โหลดกลับ (หลัง respawn inventory ใช้เวลาโหลด)
  local tool
  local waited = 0
  repeat
    if stillOn and not stillOn() then return nil end
    tool = findTool(itemName)
    if tool then break end
    task.wait(0.25)
    waited = waited + 0.25
  until waited >= 8

  if not tool then return false end -- ของหมดจริง

  char = LocalPlayer.Character
  if not char then return nil end

  -- จอง lock กัน loop อื่นมา equip แทรกระหว่างที่กำลังจะยิง
  if not self:AcquireUse(stillOn, 15) then
    return nil
  end

  local ok = pcall(function()
    self:UnequipOthers(char, tool) -- เหลือถือแต่ตัวนี้ ก่อนยิง
    tool.Parent = char
    task.wait(equipWait)
    Events.UseItem:FireServer()
    -- คืน tool กลับกระเป๋า (ถ้ากระเป๋ายังอยู่)
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp and tool.Parent == char then
      tool.Parent = bp
    end
  end)

  self:ReleaseUse()

  if not ok then return false end

  -- รอผล
  local t = os.clock()
  repeat
    task.wait()
  until conditionFn()
    or (os.clock() - t) > timeout
    or (stillOn and not stillOn())

  return true
end

--==================================================================
-- AUTO SAVE STAND
--   1. หา slot ที่เป็น None ก่อน → save ลงตัวนั้น
--   2. ถ้าไม่มี None → หา slot ที่ไม่ใช่ของใน combo → save ทับ
--   3. ถ้า slot เต็มด้วยของใน combo หมด → ปิด auto save
--==================================================================
function Auto:GetSelectedSlots()
  local picker = self.slotPicker
  local list = {}
  if not picker then return list end
  for _, idx in ipairs(picker.Value or {}) do
    table.insert(list, picker.Options[idx])
  end
  return list
end

-- คืน slot ที่ควร save ลง + เหตุผล
function Auto:GetTargetSlot()
  local selected = self:GetSelectedSlots()

  -- ขั้นที่ 1: หา None ก่อน
  for _, slotName in ipairs(selected) do
    if SlotRefs[slotName].Stand.Value == "None" then
      return slotName, "empty"
    end
  end

  -- ขั้นที่ 2: หา slot ที่ไม่ใช่ของใน combo
  for _, slotName in ipairs(selected) do
    if not slotIsKeeper(slotName) then
      return slotName, "replace"
    end
  end

  -- ขั้นที่ 3: เต็มด้วยของดีหมด
  return nil, "full"
end

function Auto:SaveStandLoop()
  local function stillOn() return self.state.saveStand end

  if #self:GetSelectedSlots() == 0 then
    self:Stop("saveStand", "AutoSaveStand", "Select at least one slot first")
    return
  end
  if #comboList == 0 then
    self:Stop("saveStand", "AutoSaveStand", "Add a combo first")
    return
  end

  while stillOn() do
    -- stand ที่ใส่อยู่ตรง combo ไหม
    if StandData.Value ~= "None" and matchesCombo(StandData.Value, AttriData.Value) then
      local target, reason = self:GetTargetSlot()

      if reason == "full" then
        self:Stop("saveStand", "AutoSaveStand", "All selected slots are filled with combo stands")
        return
      end

      if target then
        local savedStand, savedAttri = StandData.Value, AttriData.Value
        Events.SwitchStand:FireServer(target)

        -- รอจน stand ในตัวหายไป (= save ลง slot แล้ว)
        local t = os.clock()
        repeat
          task.wait()
        until StandData.Value == "None" or (os.clock() - t) > 8 or not stillOn()

        app:Notification({
          Title    = "Saved to " .. target,
          Subtitle = string.format("%s (%s) — %s",
            savedStand, savedAttri,
            reason == "empty" and "empty slot" or "replaced old one"),
          Duration = 4,
        })

        self:SendWebhook("💾 Saved to " .. target, "Auto Save Stand", 16766720, {
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

--==================================================================
-- AUTO REROLL STAND
--   reroll จนได้ stand+attribute ที่ตรง combo
--   ถ้าตาย → รอเกิดใหม่แล้วสุ่มต่อ
--==================================================================
function Auto:RerollStandLoop()
  local function stillOn() return self.state.rerollStand end

  if #comboList == 0 then
    self:Stop("rerollStand", "AutoRerollStand", "Add a combo first")
    return
  end

  local arrowName = self.arrowPicker and self.arrowPicker.Options[self.arrowPicker.Value]
  if not arrowName then
    self:Stop("rerollStand", "AutoRerollStand", "Select an arrow first")
    return
  end

  while stillOn() do
    -- รอตัวละครพร้อมก่อนทุกรอบ (กันเคสตายกลางทาง)
    if not waitForCharacter(30, stillOn) then
      if not stillOn() then return end
      task.wait(0.5)
      continue
    end

    -- ถ้าเปิด Auto 2x Orb คู่กัน: รอให้บัฟ DoubleArrowSpeed ติดก่อนค่อย reroll
    --   • จะได้ reroll ทุกครั้งด้วยความเร็ว 3x (server delay เหลือ 30%)
    --   • ตอนบัฟหมด loop นี้หยุดนิ่ง = ไม่แย่ง lock กับ 2x Orb loop
    -- ถ้าไม่ได้เปิด 2x Orb ก็ reroll ตามปกติ ไม่ต้องรอ
    if self.state.doubleOrb and not self:HasDoubleBuff() then
      task.wait(0.3)
      continue
    end

    -- ได้ของที่ต้องการแล้ว
    if StandData.Value ~= "None" and matchesCombo(StandData.Value, AttriData.Value) then
      -- ถ้าเปิด auto save ไว้ ปล่อยให้ save จัดการ แล้ว reroll ต่อ
      if not self.state.saveStand then
        app:Notification({
          Title    = "Found!",
          Subtitle = StandData.Value .. " (" .. AttriData.Value .. ")",
          Icon     = cascade.Symbols.checkmark,
          Duration = 6,
        })
        self:SendWebhook("🎯 Got Stand: " .. StandData.Value,
          "**Desired stand acquired!**", 65280, {
            { name = "Player",    value = "||" .. LocalPlayer.Name .. "||", inline = false },
            { name = "Stand",     value = StandData.Value,                  inline = false },
            { name = "Attribute", value = AttriData.Value,                  inline = false },
          })
        self:Stop("rerollStand", "AutoRerollStand")
        return
      end
      task.wait(0.3)

      -- ไม่มี stand → ใช้ arrow
    elseif StandData.Value == "None" then
      local used = self:UseItem(arrowName, function()
        return StandData.Value ~= "None"
      end, stillOn)

      if used == nil then return end
      if used == false then
        self:Stop("rerollStand", "AutoRerollStand", "Out of " .. arrowName)
        return
      end

      -- มี stand แต่ไม่ตรง combo → Rokakaka ล้างทิ้ง
    else
      local oldStand, oldAttri = StandData.Value, AttriData.Value
      local used = self:UseItem("Rokakaka", function()
        return StandData.Value ~= oldStand or AttriData.Value ~= oldAttri
      end, stillOn)

      if used == nil then return end
      if used == false then
        self:Stop("rerollStand", "AutoRerollStand", "Out of Rokakaka")
        return
      end
    end

    task.wait(0.35)
  end
end

--==================================================================
-- AUTO REROLL ATTRIBUTE
--   ใช้ Trait Orb reroll attribute ของ stand ที่ใส่อยู่
--   จนกว่า attribute จะตรง combo ของ stand ตัวนั้น
--==================================================================
function Auto:RerollAttributeLoop()
  local function stillOn() return self.state.rerollAttri end

  if StandData.Value == "None" then
    self:Stop("rerollAttri", "AutoRerollAttribute", "You must have a stand equipped")
    return
  end
  -- อ้างอิงจาก dropdown "Select attributes" อย่างเดียว ไม่สนใจ combo
  if #self:GetSelectedAttributes() == 0 then
    self:Stop("rerollAttri", "AutoRerollAttribute", "Select attributes first")
    return
  end

  -- หา orb แบบทนหน่วง (หลัง reroll/respawn ของอาจหายชั่วขณะ)
  -- คืน nil = หมดจริง
  local function findOrb(char)
    for _ = 1, 8 do
      if not stillOn() then return nil end
      local bp = LocalPlayer:FindFirstChild("Backpack")
      local orb = (bp and bp:FindFirstChild("Trait Orb"))
          or (char and char:FindFirstChild("Trait Orb"))
      if orb and orb:IsA("Tool") then return orb end
      task.wait(0.15)
      char = LocalPlayer.Character
    end
    return nil
  end

  while stillOn() do
    local char = waitForCharacter(30, stillOn)
    if not char then
      if not stillOn() then return end
      task.wait(0.5)
      continue
    end

    -- stand หลุดระหว่างทาง
    if StandData.Value == "None" then
      self:Stop("rerollAttri", "AutoRerollAttribute", "Stand was lost")
      return
    end

    -- ได้ attribute ที่เลือกไว้แล้ว
    if self:AttributeSelected(AttriData.Value) then
      app:Notification({
        Title    = "Found attribute!",
        Subtitle = StandData.Value .. " (" .. AttriData.Value .. ")",
        Icon     = cascade.Symbols.checkmark,
        Duration = 6,
      })
      self:SendWebhook("✨ Got Attribute: " .. AttriData.Value,
        "**Desired attribute acquired!**", 65280, {
          { name = "Player",    value = "||" .. LocalPlayer.Name .. "||", inline = false },
          { name = "Stand",     value = StandData.Value,                  inline = false },
          { name = "Attribute", value = AttriData.Value,                  inline = false },
        })
      self:Stop("rerollAttri", "AutoRerollAttribute")
      return
    end

    local orb = findOrb(char)
    if not orb then
      if not stillOn() then return end

      -- Trait Orb หมด → rollback แล้ว rejoin
      -- toggle ยังเป็น true อยู่ → พอเข้าเกมใหม่ resumeIfOn จะ reroll ต่อเอง
      app:Notification({
        Title    = "Out of Trait Orb",
        Subtitle = "Rolling back and rejoining...",
        Duration = 5,
      })

      self:Rollback()
      task.wait(0.5)

      self.state.rerollAttri = false       -- หยุด loop แต่ไม่แตะ toggle
      pcall(function() Config:Write() end) -- save ตอน toggle ยังเป็น true
      task.wait(0.3)

      pcall(function() TeleportService:Teleport(PlaceId, LocalPlayer) end)
      return
    end

    -- จอง lock ก่อน — กัน loop อื่น (เช่น Auto 2x Orb) equip แทร
    if not self:AcquireUse(stillOn, 15) then
      if not stillOn() then return end
      continue
    end

    -- ถือ orb ค้างไว้ — equip เฉพาะตอนที่ยังไม่ได้ถือ
    -- ไม่ย้ายกลับกระเป๋าทุกรอบ = เร็วขึ้นมาก
    if orb.Parent ~= char then
      self:UnequipOthers(char, orb)
      pcall(function() orb.Parent = char end)
      task.wait(self.rerollEquipWait)
    end

    -- ยิง remote รัวๆ
    self.rerollDone = false
    local oldAttri = AttriData.Value
    pcall(function() Events.UseItem:FireServer() end)

    -- เสร็จเมื่อ: server แจ้ง reroll เสร็จ (แม้ได้ค่าเดิม) หรือค่าเปลี่ยนจริง
    -- ตัวหลังเป็น fallback เผื่อเกมไม่มี notif event
    local t = os.clock()
    repeat
      task.wait()
    until self.rerollDone
      or AttriData.Value ~= oldAttri
      or (os.clock() - t) > self.rerollTimeout
      or not stillOn()

    self:ReleaseUse()

    if self.rerollDelay > 0 then
      task.wait(self.rerollDelay)
    end
  end
end

--==================================================================
-- AUTO 2x ORB
--   เช็ค attribute "DoubleArrowSpeed" บน LocalPlayer
--     ไม่มี / false  = บัฟหมด  -> ใช้ 2x Orb
--     true           = บัฟติดอยู่ -> รอจนหมดแล้วค่อยใช้ใหม่
--   (จาก decompile: p2:GetAttribute("DoubleArrowSpeed") == true and 0.3 or 1
--    บัฟนี้ทำให้ทุก task.wait ของ arrow/orb เหลือ 30%)
--==================================================================
function Auto:HasDoubleBuff()
  return LocalPlayer:GetAttribute("DoubleArrowSpeed") == true
end

function Auto:DoubleOrbLoop()
  local function stillOn() return self.state.doubleOrb end

  -- หา 2x Orb แบบทนหน่วง (หลังใช้/respawn ของอาจหายชั่วขณะ)
  local function findDoubleOrb(char)
    for _ = 1, 8 do
      if not stillOn() then return nil end
      local bp = LocalPlayer:FindFirstChild("Backpack")
      local orb = (bp and bp:FindFirstChild("2x Orb"))
          or (char and char:FindFirstChild("2x Orb"))
      if orb and orb:IsA("Tool") then return orb end
      task.wait(0.15)
      char = LocalPlayer.Character
    end
    return nil
  end

  while stillOn() do
    -- บัฟยังติดอยู่ -> รอจนหมด ไม่ต้องเปลืองลูก
    if self:HasDoubleBuff() then
      repeat
        task.wait(1)
      until not self:HasDoubleBuff() or not stillOn()
      if not stillOn() then return end
    end

    local char = waitForCharacter(30, stillOn)
    if not char then
      if not stillOn() then return end
      task.wait(0.5)
      continue
    end

    -- เช็คซ้ำ เผื่อบัฟกลับมาระหว่างรอเกิด
    if self:HasDoubleBuff() then continue end

    local orb = findDoubleOrb(char)
    if not orb then
      if not stillOn() then return end
      -- เช็คซ้ำอีกทีหลังเว้นนาน — กันเคส loop อื่นกำลังย้าย tool อยู่พอดี
      task.wait(1)
      if findDoubleOrb(LocalPlayer.Character) then continue end
      if not stillOn() then return end
      self:Stop("doubleOrb", "AutoDoubleOrb", "Out of 2x Orb")
      return
    end

    -- จอง lock ก่อน — กัน loop อื่นยิง UseItem ตอน 2x Orb อยู่บนตัว
    -- (ตอนนี้ reroll stand ควรหยุดรอบัฟอยู่แล้ว คิวจึงไม่ควรยาว)
    if not self:AcquireUse(stillOn, 15) then
      if not stillOn() then return end
      continue -- แค่รอคิว ไม่ใช่ของหมด — วนไปลองใหม่
    end

    -- equip 2x Orb ชั่วคราว โดยถอด tool อื่นออกก่อน
    self:UnequipOthers(char, orb)
    if orb.Parent ~= char then
      pcall(function() orb.Parent = char end)
      task.wait(self.rerollEquipWait)
    end

    pcall(function() Events.UseItem:FireServer() end)

    -- รอบัฟติด (ถ้าไม่ติดใน 3 วิ ถือว่าพลาด วนไปลองใหม่)
    local t = os.clock()
    repeat
      task.wait(0.1)
    until self:HasDoubleBuff()
      or (os.clock() - t) > 3
      or not stillOn()

    -- คืน orb กลับกระเป๋า — ห้ามถือค้าง
    -- ไม่งั้น loop อื่นจะยิง UseItem แล้วโดน 2x Orb แทน
    do
      local bp = LocalPlayer:FindFirstChild("Backpack")
      if bp and orb.Parent == char then
        pcall(function() orb.Parent = bp end)
      end
    end

    self:ReleaseUse()

    if self:HasDoubleBuff() then
      app:Notification({
        Title    = "2x Orb",
        Subtitle = "Speed buff active",
        Icon     = cascade.Symbols.checkmark,
        Duration = 3,
      })
    end

    task.wait(0.2)
  end
end

--==================================================================
-- AUTO HOP SERVER
--   hop ไปเซิร์ฟใหม่เมื่อ server อายุเกินที่ตั้งไว้
--==================================================================
function Auto:HopServer()
  local servers = {}
  local ok, body = pcall(function()
    return HttpService:JSONDecode(game:HttpGet(
      "https://games.roblox.com/v1/games/" .. PlaceId ..
      "/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true"))
  end)

  if ok and body and body.data then
    for _, v in next, body.data do
      if type(v) == "table"
          and tonumber(v.playing) and tonumber(v.maxPlayers)
          and v.playing < v.maxPlayers
          and v.id ~= game.JobId then
        table.insert(servers, v.id)
      end
    end
  end

  if #servers == 0 then
    return false
  end

  local ok2 = pcall(function()
    TeleportService:TeleportToPlaceInstance(
      PlaceId, servers[math.random(1, #servers)], LocalPlayer)
  end)
  return ok2
end

function Auto:HopServerLoop()
  local function stillOn() return self.state.hopServer end

  while stillOn() do
    if ServerAge.Value >= self.hopAfterSeconds then
      local hopped = self:HopServer()
      if not hopped then
        app:Notification({
          Title    = "Server hop",
          Subtitle = "Couldn't find another server — retrying",
          Duration = 4,
        })
        task.wait(10) -- หาไม่เจอ รอนานหน่อยค่อยลองใหม่
      else
        -- teleport สำเร็จ = กำลังจะออกจากเซิร์ฟ ไม่ต้องวนต่อ
        return
      end
    end
    task.wait(1)
  end
end

--==================================================================
-- 4. APP + WINDOW
--==================================================================
app = cascade.New({
  WindowPill = true,
  Theme      = cascade.Themes.Dark,
  Accent     = cascade.Accents.Blue,
})

window = app:Window({
  Title    = "Stand Upright: Rebooted",
  Subtitle = "by Songkranz",
  Size     = UDim2.fromOffset(645, 530),
})

local minimizeKeybind = Enum.KeyCode.RightControl
Lifecycle:Connect(game:GetService("UserInputService").InputEnded, function(input, gpe)
  if input.KeyCode == minimizeKeybind and not gpe then
    window.Minimized = not window.Minimized
  end
end)

-- safety net: ถ้า UI ถูกทำลายด้วยวิธีอื่น (เช่นลบ GUI เอง) ให้ cleanup ตาม
pcall(function()
  Lifecycle:Connect(window.__instance.AncestryChanged, function(_, parent)
    if not parent then
      task.defer(function() Lifecycle:Unload() end)
    end
  end)
end)

local function titledRow(parent, title, subtitle)
  local row   = parent:Row({ SearchIndex = title })
  local stack = row:Left():TitleStack({ Title = title, Subtitle = subtitle })
  return row, stack
end

--==================================================================
-- 5. UI — STAND
--==================================================================
local comboSection = window:Section({ Title = "Main", Disclosure = false })
local comboTab = comboSection:Tab({
  Title    = "Stand",
  Icon     = cascade.Symbols.user,
  Selected = true,
})

local miscTab = comboSection:Tab({
  Title    = "Miscellaneous",
  Icon     = cascade.Symbols.miscellaneous,
  Selected = false,
})

-- ---- Account info ----
local AccountForm = comboTab:PageSection({ Title = "Account information" }):Form()

local infoRow, infoStack = titledRow(AccountForm, "Info slots\n", "Loading ...")

local function refreshSlots()
  local lines = {}

  table.insert(lines, string.format("Current: %s (%s)",
    StandData.Value, AttriData.Value))

  for _, slotName in ipairs(SlotOrder) do
    local ref = SlotRefs[slotName]
    table.insert(lines, string.format("%s: %s (%s)",
      slotName, ref.Stand.Value, ref.Attribute.Value))
  end

  infoStack.Subtitle = table.concat(lines, "\n\n")
end

Lifecycle:Connect(StandData:GetPropertyChangedSignal("Value"), refreshSlots)
Lifecycle:Connect(AttriData:GetPropertyChangedSignal("Value"), refreshSlots)

for _, slotName in ipairs(SlotOrder) do
  local ref = SlotRefs[slotName]
  Lifecycle:Connect(ref.Stand:GetPropertyChangedSignal("Value"), refreshSlots)
  Lifecycle:Connect(ref.Attribute:GetPropertyChangedSignal("Value"), refreshSlots)
end

refreshSlots()

-- ---- Auto Save Stand ----
local SaveStandForm = comboTab:PageSection({ Title = "Auto Save Stand" }):Form()

local slotRow = titledRow(SaveStandForm, "Select slots", "Slots this may save into")
Auto.slotPicker = slotRow:Right():PopUpButton({
  Options      = SlotOrder,
  Maximum      = 5,
  ValueChanged = function(self, value)
    if Config.syncing then return end
    Config:Request()
  end,
})

local saveToggleRow = titledRow(SaveStandForm, "Auto Save Stand")

Auto.toggles.AutoSaveStand = saveToggleRow:Right():Toggle({
  Value = false,
  ValueChanged = function(self, value)
    if Config.syncing then return end -- Apply ใช้ resumeIfOn เริ่ม loop แทน
    Auto.state.saveStand = value
    if value then
      Auto:RunThread("saveStand", function() Auto:SaveStandLoop() end)
    else
      Auto:KillThread("saveStand")
    end
    if Config.syncing then return end
    Config:Request()
  end,
})

saveToggleRow:Right():Button({
  Label = "Open",
  State = "Primary",
  Pushed = function()
    workspace:WaitForChild("Map"):WaitForChild("NPCs"):WaitForChild("admpn"):WaitForChild("Done")
        :FireServer()
  end,
})

-- ---- Stand combo ----
local StandComboForm = comboTab:PageSection({ Title = "Stand combo" }):Form()

local lblRow, lblStack = titledRow(StandComboForm, "Combo list", "(None)")

local function refresh()
  if #comboList == 0 then
    lblStack.Subtitle = "(None)"
    return
  end
  local lines = {}
  for i, combo in ipairs(comboList) do
    table.insert(lines, string.format("- %s | %s",
      combo.stand, table.concat(combo.attributes, ", ")))
  end
  lblStack.Subtitle = table.concat(lines, "\n")
end

local standRow = titledRow(StandComboForm, "Select stand")
local standPicker = standRow:Right():PopUpButton({
  Options      = STAND_OPTIONS,
  Value        = 1,
  ValueChanged = function(self, value)
    if Config.syncing then return end
    Config:Request()
  end,
})

local attriRow = titledRow(StandComboForm, "Select attributes")
local attriPicker = attriRow:Right():PopUpButton({
  Options      = ATTRIBUTE_OPTIONS,
  Maximum      = 5,
  ValueChanged = function(self, value)
    if Config.syncing then return end
    Config:Request()
  end,
})
-- Auto Reroll Attribute อ่าน attribute ที่ต้องการจาก dropdown ตัวนี้ตรงๆ
Auto.attriPicker = attriPicker

local btnRow = titledRow(StandComboForm, "Manage combo")

btnRow:Right():Button({
  Label = "Add",
  State = "Primary",
  Pushed = function()
    local standName = standPicker.Options[standPicker.Value]

    local selected = {}
    for _, idx in ipairs(attriPicker.Value or {}) do
      table.insert(selected, attriPicker.Options[idx])
    end

    if #selected == 0 then
      app:Notification({
        Title    = "Select attribute first",
        Subtitle = "Pick at least one attribute",
        Duration = 3,
      })
      return
    end

    for _, combo in ipairs(comboList) do
      if combo.stand == standName then
        combo.attributes = selected
        refresh()
        Config:Request()
        app:Notification({
          Title    = "Updated",
          Subtitle = standName .. " → " .. table.concat(selected, ", "),
          Duration = 3,
        })
        return
      end
    end

    table.insert(comboList, { stand = standName, attributes = selected })
    refresh()
    Config:Request()
  end,
})

btnRow:Right():Button({
  Label = "Remove last",
  State = "Secondary",
  Pushed = function()
    if #comboList == 0 then return end
    table.remove(comboList)
    refresh()
    Config:Request()
  end,
})

btnRow:Right():Button({
  Label = "Remove all",
  State = "Destructive",
  Pushed = function()
    table.clear(comboList)
    refresh()
    Config:Request()
  end,
})

-- ---- Reroll ----
local RerollForm = comboTab:PageSection({ Title = "Auto Reroll" }):Form()



local rerollStandRow = titledRow(RerollForm, "Auto Reroll Stand",
  "Reroll until a combo matches — waits for respawn if you die")

Auto.toggles.AutoRerollStand = rerollStandRow:Right():Toggle({
  Value = false,
  ValueChanged = function(self, value)
    if Config.syncing then return end
    Auto.state.rerollStand = value
    if value then
      Auto:RunThread("rerollStand", function() Auto:RerollStandLoop() end)
    else
      Auto:KillThread("rerollStand")
    end
    if Config.syncing then return end
    Config:Request()
  end,
})

Auto.arrowPicker = rerollStandRow:Right():PopUpButton({
  Options      = { "Stand Arrow", "Charged Arrow" },
  Value        = 1,
  ValueChanged = function(self, value)
    if Config.syncing then return end
    Config:Request()
  end,
})

local rerollAttriRow = titledRow(RerollForm, "Auto Reroll Attribute",
  "Trait Orb until it matches 'Select attributes' — out of orbs: rollback + rejoin")

Auto.toggles.AutoRerollAttribute = rerollAttriRow:Right():Toggle({
  Value = false,
  ValueChanged = function(self, value)
    if Config.syncing then return end
    Auto.state.rerollAttri = value
    if value then
      Auto:RunThread("rerollAttri", function() Auto:RerollAttributeLoop() end)
    else
      Auto:KillThread("rerollAttri")
    end
    Config:Request()
  end,
})

local SPEED_CHOICES = { "Fast", "Normal", "Safe" }
local SPEED_PRESETS = {
  { timeout = 1.0, equip = 0.05, delay = 0.1 },  -- Fast
  { timeout = 1.5, equip = 0.10, delay = 0.2 },  -- Normal
  { timeout = 2.5, equip = 0.20, delay = 0.25 }, -- Safe
}

local function applyRerollSpeed(idx)
  local p              = SPEED_PRESETS[idx] or SPEED_PRESETS[2]
  Auto.rerollTimeout   = p.timeout
  Auto.rerollEquipWait = p.equip
  Auto.rerollDelay     = p.delay
end

Auto.speedPicker = rerollAttriRow:Right():PopUpButton({
  Options      = SPEED_CHOICES,
  Value        = 2, -- Normal
  ValueChanged = function(self, value)
    applyRerollSpeed(value)
    if Config.syncing then return end
    Config:Request()
  end,
})
applyRerollSpeed(Auto.speedPicker.Value)

Config:Register("RerollSpeed",
  function() return Auto.speedPicker.Value end,
  function(v)
    Auto.speedPicker.Value = v
    applyRerollSpeed(v)
  end
)

-- ---- Auto 2x Orb ----
local doubleOrbRow = titledRow(RerollForm, "Auto 2x Orb",
  "Use a 2x Orb whenever the speed buff runs out")

Auto.toggles.AutoDoubleOrb = doubleOrbRow:Right():Toggle({
  Value = false,
  ValueChanged = function(self, value)
    if Config.syncing then return end
    Auto.state.doubleOrb = value
    if value then
      Auto:RunThread("doubleOrb", function() Auto:DoubleOrbLoop() end)
    else
      Auto:KillThread("doubleOrb")
    end
    Config:Request()
  end,
})

Config:Register("AutoDoubleOrb",
  function() return Auto.toggles.AutoDoubleOrb.Value end,
  function(v) Auto.toggles.AutoDoubleOrb.Value = v end
)

-- ---- Register combo + automation settings ----
Config:Register("SelectStand",
  function() return standPicker.Value end,
  function(v) standPicker.Value = v end
)

Config:Register("SelectAttributes",
  function() return attriPicker.Value end,
  function(v) attriPicker.Value = v end
)

Config:Register("ComboList",
  function() return comboList end,
  function(v)
    table.clear(comboList)
    if type(v) == "table" then
      for _, combo in ipairs(v) do
        if type(combo) == "table"
            and type(combo.stand) == "string"
            and type(combo.attributes) == "table" then
          table.insert(comboList, combo)
        end
      end
    end
    refresh()
  end
)

Config:Register("SaveSlots",
  function() return Auto.slotPicker.Value end,
  function(v) Auto.slotPicker.Value = v end
)

Config:Register("SelectArrow",
  function() return Auto.arrowPicker.Value end,
  function(v) Auto.arrowPicker.Value = v end
)

-- toggle ของ automation: จำค่าไว้ แต่ไม่ auto-start ตอนโหลด
-- (setter ตั้งแค่ค่าใน UI, loop จะเริ่มเมื่อผู้ใช้กดเอง หรือใน resume ด้านล่าง)
Config:Register("AutoSaveStand",
  function() return Auto.toggles.AutoSaveStand.Value end,
  function(v) Auto.toggles.AutoSaveStand.Value = v end
)

Config:Register("AutoRerollStand",
  function() return Auto.toggles.AutoRerollStand.Value end,
  function(v) Auto.toggles.AutoRerollStand.Value = v end
)

Config:Register("AutoRerollAttribute",
  function() return Auto.toggles.AutoRerollAttribute.Value end,
  function(v) Auto.toggles.AutoRerollAttribute.Value = v end
)

refresh()

do
  --================================================================
  -- Trade helper
  --================================================================
  local TradeForm   = miscTab:PageSection({ Title = "Trade helper" }):Form()

  local playersList = {}
  local itemsList   = {}

  local function refreshPlayers()
    table.clear(playersList)
    for _, v in ipairs(Players:GetPlayers()) do
      if v ~= LocalPlayer then
        table.insert(playersList, v.Name)
      end
    end
    if #playersList == 0 then
      table.insert(playersList, "(no players)")
    end
  end

  local function refreshItems()
    table.clear(itemsList)
    table.insert(itemsList, "All")
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp then
      for _, v in ipairs(bp:GetChildren()) do
        if v:IsA("Tool") then
          table.insert(itemsList, v.Name)
        end
      end
    end
    table.sort(itemsList, function(a, b)
      if a == "All" then return true end
      if b == "All" then return false end
      return a < b
    end)
  end

  refreshPlayers()
  refreshItems()

  -- ---- เลือกผู้เล่น + ส่งคำขอเทรด ----
  local playerRow = titledRow(TradeForm, "Select player", "Who to send the trade to")
  local playerPicker = playerRow:Right():PopUpButton({
    Options      = playersList,
    Value        = 1,
    ValueChanged = function() end,
  })

  playerRow:Right():Button({
    Label = "Refresh",
    State = "Secondary",
    Pushed = function()
      refreshPlayers()
      pcall(function() playerPicker.Options = playersList end)
    end,
  })

  playerRow:Right():Button({
    Label = "Send",
    State = "Primary",
    Pushed = function()
      local target = playerPicker.Options[playerPicker.Value]
      if not target or target == "(no players)" then
        app:Notification({ Title = "Trade", Subtitle = "No player selected", Duration = 3 })
        return
      end
      pcall(function() Events.UICMDS:FireServer(target, "Trade") end)
    end,
  })

  -- ---- เลือกไอเทม + จำนวน ----
  local itemRow = titledRow(TradeForm, "Select items", "Items to put into the trade")
  local itemPicker = itemRow:Right():PopUpButton({
    Options      = itemsList,
    Maximum      = 20,
    ValueChanged = function() end,
  })

  itemRow:Right():Button({
    Label = "Refresh",
    State = "Secondary",
    Pushed = function()
      refreshItems()
      pcall(function() itemPicker.Options = itemsList end)
    end,
  })

  local amountRow = titledRow(TradeForm, "Amount", "How many of each item")
  local amountField = amountRow:Right():TextField({
    Value        = "1",
    ValueChanged = function() end,
  })

  amountRow:Right():Button({
    Label = "Add Item",
    State = "Primary",
    Pushed = function()
      local amount = tonumber(amountField.Value)
      if not amount or amount <= 0 then
        app:Notification({ Title = "Trade", Subtitle = "Enter a valid amount", Duration = 3 })
        return
      end

      -- แปลง index ที่เลือก -> ชื่อไอเทม
      local selected = {}
      for _, idx in ipairs(itemPicker.Value or {}) do
        table.insert(selected, itemPicker.Options[idx])
      end
      if #selected == 0 then
        app:Notification({ Title = "Trade", Subtitle = "Pick at least one item", Duration = 3 })
        return
      end

      local function add(itemName)
        pcall(function()
          TradeEvents.TradeComm:FireServer("AddItem",
            { ItemName = itemName, Amount = amount })
        end)
        task.wait()
      end

      task.spawn(function()
        -- ถ้าเลือก "All" = ใส่ทุกไอเทมในกระเป๋า
        local isAll = false
        for _, name in ipairs(selected) do
          if name == "All" then
            isAll = true
            break
          end
        end

        if isAll then
          for _, itemName in ipairs(itemsList) do
            if itemName ~= "All" then add(itemName) end
          end
        else
          for _, itemName in ipairs(selected) do
            add(itemName)
          end
        end

        task.wait()
        pcall(function() TradeEvents.TradeComm:FireServer("AcceptTrade") end)

        app:Notification({
          Title    = "Trade",
          Subtitle = "Added items and accepted",
          Duration = 3,
        })
      end)
    end,
  })

  --================================================================
  -- Webhook
  --================================================================
  local WebhookForm = miscTab:PageSection({ Title = "Webhook" }):Form()

  local hookRow = titledRow(WebhookForm, "Discord webhook", "Paste your webhook URL")
  local hookField = hookRow:Right():TextField({
    Value        = "",
    ValueChanged = function(self, value)
      Auto.webhookUrl = value
      if Config.syncing then return end
      Config:Request()
    end,
  })
  Auto.webhookUrl = hookField.Value

  local hookToggleRow = titledRow(WebhookForm, "Send Webhook",
    "Notify on save / stand found / attribute found")
  Auto.toggles.AutoSendWebhook = hookToggleRow:Right():Toggle({
    Value = false,
    ValueChanged = function(self, value)
      if Config.syncing then return end
      Config:Request()
    end,
  })

  hookToggleRow:Right():Button({
    Label = "Test",
    State = "Secondary",
    Pushed = function()
      if not Auto.webhookUrl or Auto.webhookUrl == "" then
        app:Notification({ Title = "Webhook", Subtitle = "Enter a URL first", Duration = 3 })
        return
      end
      if not Auto.toggles.AutoSendWebhook.Value then
        app:Notification({ Title = "Webhook", Subtitle = "Turn the toggle on first", Duration = 3 })
        return
      end
      Auto:SendWebhook("✅ Test", "Webhook is working", 5814783, {
        { name = "Player", value = "||" .. LocalPlayer.Name .. "||", inline = false },
      })
      app:Notification({ Title = "Webhook", Subtitle = "Test sent", Duration = 3 })
    end,
  })

  Config:Register("WebhookUrl",
    function() return hookField.Value end,
    function(v)
      hookField.Value = v
      Auto.webhookUrl = v
    end
  )
  Config:Register("AutoSendWebhook",
    function() return Auto.toggles.AutoSendWebhook.Value end,
    function(v) Auto.toggles.AutoSendWebhook.Value = v end
  )

  --================================================================
  -- Miscellaneous
  --================================================================
  local miscForm = miscTab:PageSection({ Title = "Miscellaneous" }):Form()

  local rollbackButton = titledRow(miscForm, "Rollback",
    "Send bad client settings to force a data rollback")

  rollbackButton:Right():Button({
    Label = "Click",
    State = "Destructive",
    Pushed = function()
      local ok = Auto:Rollback()
      task.wait()
      app:Notification({
        Title    = "Rollback",
        Subtitle = ok and "Sent — rejoin to apply" or "Failed to send",
        Duration = 4,
      })
    end,
  })

  -- สร้างข้อความสรุป stand ทั้งหมด (current + ทุก slot)
  local function buildStandDescription()
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

  local setDescButton = titledRow(miscForm, "Set Description",
    "Write your stands into the RAM account description")

  setDescButton:Right():Button({
    Label = "Click",
    State = "Primary",
    Pushed = function()
      local desc = buildStandDescription()
      if desc == "" then
        app:Notification({ Title = "Set Description", Subtitle = "No stands to write", Duration = 3 })
        return
      end

      -- RAM ต้องเปิดอยู่ ถ้าโหลดไม่ได้ก็ไม่พัง
      local ok, err = pcall(function()
        local RAMAccount = loadstring(game:HttpGet(
          "https://raw.githubusercontent.com/ic3w0lf22/Roblox-Account-Manager/master/RAMAccount.lua"))()
        local MyAccount = RAMAccount.new(LocalPlayer.Name)
        MyAccount:SetDescription(desc)
      end)

      app:Notification({
        Title    = "Set Description",
        Subtitle = ok and "Updated" or "Failed — is Account Manager running?",
        Duration = 4,
      })
      if not ok then warn("[SetDescription]", err) end
    end,
  })

  --================================================================
  -- Ketchup calculator
  --================================================================
  local KetchupForm = miscTab:PageSection({ Title = "Ketchup" }):Form()

  local CurrentLVRow, CurrentLVStack =
      titledRow(KetchupForm, "Level", CurrentLevel.Value .. " → N/A")
  local TotalKetchupRow, TotalKetchupStack =
      titledRow(KetchupForm, "Total Ketchup", "N/A 🥫")

  local amountKetchupRow = titledRow(KetchupForm, "Target level", "Level you want to reach")
  local levelField = amountKetchupRow:Right():TextField({
    Value        = "",
    ValueChanged = function() end,
  })

  amountKetchupRow:Right():Button({
    Label = "Calculate",
    State = "Primary",
    Pushed = function()
      -- ใส่ comma คั่นหลักพัน
      local function comma(n)
        local s = tostring(math.floor(n))
        local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
        return (out:gsub("^,", ""))
      end

      -- EXP ต่อเลเวล = (30 * 3 * (L * L / 10)) + 20  =  9L² + 20
      local function expForLevel(L)
        return (30 * 3 * (L * L / 10)) + 20
      end

      local fromLevel = tonumber(CurrentLevel.Value) or 1
      local toLevel   = tonumber(levelField.Value)

      if not toLevel then
        app:Notification({ Title = "Ketchup", Subtitle = "Enter a target level", Duration = 3 })
        return
      end
      if toLevel <= fromLevel then
        app:Notification({
          Title    = "Ketchup",
          Subtitle = "Target must be higher than " .. fromLevel,
          Duration = 4,
        })
        return
      end

      local totalExp = 0
      for L = fromLevel, toLevel - 1 do
        totalExp = totalExp + expForLevel(L)
      end
      local totalKetchup         = math.ceil(totalExp / 100)

      CurrentLVStack.Subtitle    = string.format("%d → %d", fromLevel, toLevel)
      TotalKetchupStack.Subtitle = string.format("%s 🥫  (%s EXP)",
        comma(totalKetchup), comma(totalExp))
    end,
  })

  -- อัปเดตเลเวลปัจจุบันบน label เอง
  Lifecycle:Connect(CurrentLevel:GetPropertyChangedSignal("Value"), function()
    local shown = CurrentLVStack.Subtitle or ""
    if shown:find("→ N/A") or shown == "" then
      CurrentLVStack.Subtitle = CurrentLevel.Value .. " → N/A"
    end
  end)

  amountKetchupRow:Right():Button({
    Label = "Sell all ketchup",
    State = "Destructive",
    Pushed = function()
      Events:WaitForChild("SellKetchup"):FireServer("Lots")
    end,
  })
end



--==================================================================
-- 7. UI — SETTINGS
--==================================================================
local settingsSection = window:Section({ Title = "Settings", Disclosure = true })
local settingsTab = settingsSection:Tab({ Title = "Settings", Icon = cascade.Symbols.gear })

do
  local serverForm = settingsTab:PageSection({ Title = "Server" }):Form()

  titledRow(serverForm, "Rejoin", "Rejoin this place"):Right():Button({
    Label = "Rejoin",
    State = "Primary",
    Pushed = function() TeleportService:Teleport(PlaceId, LocalPlayer) end,
  })

  -- ---- Auto rejoin when disconnected (default ON) ----
  local rejoinRow = titledRow(serverForm, "Auto Rejoin",
    "Rejoin automatically when kicked or disconnected")
  Auto.toggles.AutoRejoin = rejoinRow:Right():Toggle({
    Value = true,
    ValueChanged = function(self, value)
      autoRejoinEnabled = value
      if Config.syncing then return end
      Config:Request()
    end,
  })
  Config:Register("AutoRejoin",
    function() return Auto.toggles.AutoRejoin.Value end,
    function(v) Auto.toggles.AutoRejoin.Value = v end
  )

  -- ---- Anti AFK (default ON) ----
  local antiAfkConn

  -- แยกเป็น function เพื่อให้เรียกได้ทั้งจาก toggle และตอน init
  local function setAntiAFK(enabled)
    if enabled then
      if not antiAfkConn then
        antiAfkConn = Lifecycle:Track(LocalPlayer.Idled:Connect(function()
          VirtualUser:CaptureController()
          VirtualUser:ClickButton2(Vector2.new())
        end))
      end
    else
      if antiAfkConn then
        antiAfkConn:Disconnect(); antiAfkConn = nil
      end
    end
  end
  Auto.setAntiAFK = setAntiAFK

  local antiAfkRow = titledRow(serverForm, "Anti AFK", "Prevents AFK kicks")
  Auto.toggles.AntiAFK = antiAfkRow:Right():Toggle({
    Value = true,
    ValueChanged = function(self, value)
      setAntiAFK(value)
      if Config.syncing then return end
      Config:Request()
    end,
  })
  Config:Register("AntiAFK",
    function() return Auto.toggles.AntiAFK.Value end,
    function(v) Auto.toggles.AntiAFK.Value = v end
  )

  Lifecycle:AddCleanup(function() setAntiAFK(false) end)

  -- ---- Auto hop server ----
  local HOP_CHOICES = { "1 hour", "2 hours", "3 hours" }
  local HOP_SECONDS = { 3600, 7200, 10800 }

  local hopAgeRow = titledRow(serverForm, "Hop after",
    "Hop once the server is older than this")
  Auto.hopAgePicker = hopAgeRow:Right():PopUpButton({
    Options      = HOP_CHOICES,
    Value        = 3, -- 3 hours
    ValueChanged = function(self, value)
      Auto.hopAfterSeconds = HOP_SECONDS[value] or 10800
      if Config.syncing then return end
      Config:Request()
    end,
  })
  Auto.hopAfterSeconds = HOP_SECONDS[Auto.hopAgePicker.Value] or 10800

  local hopRow = titledRow(serverForm, "Auto Hop Server",
    "Move to a fresh server when this one gets old")
  Auto.toggles.AutoHopServer = hopRow:Right():Toggle({
    Value = false,
    ValueChanged = function(self, value)
      if Config.syncing then return end
      Auto.state.hopServer = value
      if value then
        Auto:RunThread("hopServer", function() Auto:HopServerLoop() end)
      else
        Auto:KillThread("hopServer")
      end
      if Config.syncing then return end
      Config:Request()
    end,
  })

  hopRow:Right():Button({
    Label = "Hop now",
    State = "Secondary",
    Pushed = function()
      if not Auto:HopServer() then
        app:Notification({
          Title    = "Server hop",
          Subtitle = "Couldn't find another server",
          Duration = 4,
        })
      end
    end,
  })

  Config:Register("HopAfter",
    function() return Auto.hopAgePicker.Value end,
    function(v)
      Auto.hopAgePicker.Value = v
      Auto.hopAfterSeconds = HOP_SECONDS[v] or 10800
    end
  )
  Config:Register("AutoHopServer",
    function() return Auto.toggles.AutoHopServer.Value end,
    function(v) Auto.toggles.AutoHopServer.Value = v end
  )

  local form = settingsTab:PageSection({ Title = "Appearance" }):Form()

  local darkRow = titledRow(form, "Dark Mode", "Switch theme")
  local darkToggle = darkRow:Right():Toggle({
    Value = app.Theme._id == "Dark",
    ValueChanged = function(self, value)
      app.Theme = value and cascade.Themes.Dark or cascade.Themes.Light
      if Config.syncing then return end
      Config:Request()
    end,
  })
  Config:Register("DarkMode",
    function() return darkToggle.Value end,
    function(v) darkToggle.Value = v end
  )

  local blurRow = titledRow(form, "UI Blur", "Blur behind the window")
  local blurToggle = blurRow:Right():Toggle({
    Value = window.UIBlur,
    ValueChanged = function(self, value)
      window.UIBlur = value
      if Config.syncing then return end
      Config:Request()
    end,
  })
  Config:Register("UIBlur",
    function() return blurToggle.Value end,
    function(v) blurToggle.Value = v end
  )

  local shadowRow = titledRow(form, "Dropshadow", "Shadow behind the window")
  local shadowToggle = shadowRow:Right():Toggle({
    Value = window.Dropshadow,
    ValueChanged = function(self, value)
      window.Dropshadow = value
      if Config.syncing then return end
      Config:Request()
    end,
  })
  Config:Register("Dropshadow",
    function() return shadowToggle.Value end,
    function(v) shadowToggle.Value = v end
  )

  local flatAccents = {}
  for accent in pairs(cascade.Accents) do
    table.insert(flatAccents, accent)
  end
  table.sort(flatAccents)

  local accentRow = titledRow(form, "Accent Color", "Accent colour")
  local accentPicker = accentRow:Right():PopUpButton({
    Options      = flatAccents,
    Value        = 1,
    ValueChanged = function(self, value)
      app.Accent = cascade.Accents[self.Options[value]]
      if Config.syncing then return end
      Config:Request()
    end,
  })
  Config:Register("Accent",
    function() return accentPicker.Value end,
    function(v) accentPicker.Value = v end
  )

  local keyRow = titledRow(form, "Minimize Keybind", "Key to minimise the UI")
  keyRow:Right():KeybindField({
    Value = minimizeKeybind,
    ValueChanged = function(self, value)
      minimizeKeybind = value
      if Config.syncing then return end
      Config:Request()
    end,
  })
  Config:Register("MinimizeKeybind",
    function() return minimizeKeybind.Name end,
    function(v)
      if type(v) == "string" and Enum.KeyCode[v] then
        minimizeKeybind = Enum.KeyCode[v]
      end
    end
  )

  local unloadRow = titledRow(form, "Unload script")

  unloadRow:Right():Button({
    Label = "Unload",
    State = "Secondary",
    Pushed = function()
      Lifecycle:Unload()
    end,
  })
end

do
  local form = settingsTab:PageSection({ Title = "Config" }):Form()

  titledRow(form, "Save file", fileName)

  local cfgRow = titledRow(form, "Manage", "Manage the save file")

  cfgRow:Right():Button({
    Label = "Reset",
    State = "Destructive",
    Pushed = function()
      Config.store = {}
      if fileSupport() and isfile(fileName) then
        pcall(delfile, fileName)
      end
      app:Notification({
        Title    = "Reset",
        Subtitle = "Save file deleted — reload the script to start fresh",
        Duration = 4,
      })
    end,
  })
end

Config:Apply()

autoRejoinEnabled = Auto.toggles.AutoRejoin.Value
if Auto.setAntiAFK then
  Auto.setAntiAFK(Auto.toggles.AntiAFK.Value)
end

local function resumeIfOn(toggleName, stateKey, threadName, fn)
  local tgl = Auto.toggles[toggleName]
  if tgl and tgl.Value == true then
    Auto.state[stateKey] = true
    Auto:RunThread(threadName, fn)
  end
end

resumeIfOn("AutoSaveStand", "saveStand", "saveStand",
  function() Auto:SaveStandLoop() end)
resumeIfOn("AutoRerollStand", "rerollStand", "rerollStand",
  function() Auto:RerollStandLoop() end)
resumeIfOn("AutoRerollAttribute", "rerollAttri", "rerollAttri",
  function() Auto:RerollAttributeLoop() end)
resumeIfOn("AutoDoubleOrb", "doubleOrb", "doubleOrb",
  function() Auto:DoubleOrbLoop() end)
resumeIfOn("AutoHopServer", "hopServer", "hopServer",
  function() Auto:HopServerLoop() end)

Config.ready = true
Config:Write()

app:Notification({
  Title    = "Stand Upright: Rebooted",
  Subtitle = string.format("Loaded in %.2f s", os.clock() - startTime),
  App      = "SCRIPT HUB",
  Icon     = cascade.Symbols.checkmark,
  Duration = 4,
})
