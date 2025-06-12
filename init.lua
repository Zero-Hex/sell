local mq                = require('mq')
local ICONS             = require('mq.Icons')
local ImGui             = require('ImGui')
local vendorInv         = require('vendor_inv')
local actors            = require 'actors'

local openGUI           = true
local shouldDrawGUI     = false

local terminate         = false

local animItems         = mq.FindTextureAnimation("A_DragItem")

local sourceIndex       = 1
local sellAllJunk       = false
local vendItem          = nil

local ColumnID_ItemIcon = 0
local ColumnID_Item     = 1
local ColumnID_Junk     = 2
local ColumnID_Sell     = 3
local ColumnID_LAST     = ColumnID_Sell + 1
local settings_file     = mq.configDir .. "/vendor.lua"
local custom_sources    = mq.configDir .. "/vendor_sources.lua"

local settings          = {}

local Output            = function(msg, ...)
    local formatted = msg
    if ... then
        formatted = string.format(msg, ...)
    end
    printf('\aw[' .. mq.TLO.Time() .. '] [\aoDerple\'s Vendor Helper\aw] ::\a-t %s', formatted)
end

local function SaveSettings()
    mq.pickle(settings_file, settings)
    actors.send({ from = mq.TLO.Me.DisplayName(), script = "DerpleVend", event = "SaveSettings", })
end

local function LoadSettings()
    local config, err = loadfile(settings_file)
    if err or not config then
        Output("\ayNo valid configuration found. Creating a new one: %s", settings_file)
        settings = {}
        SaveSettings()
    else
        settings = config()
    end

    settings.Junk = settings.Junk or {}

    local vendorSources = {}
    local config, err = loadfile(custom_sources)
    if not err and config then
        vendorSources = config()
    end

    vendorInv = vendorInv:new(vendorSources)
end

local function sellItem(item)
    if not mq.TLO.Window("MerchantWnd").Open() then
        return
    end

    local tabPage = mq.TLO.Window("MerchantWnd").Child("MW_MerchantSubWindows")
    if tabPage.CurrentTab.Name() ~= "MW_PurchasePage" then
        tabPage.SetCurrentTab(1)
        return
    end

    if item and item.Item then
        Output("\aySelling item: \at%s\ay in Slot\aw(\am%d\aw)\ay, Slot2\aw(\am%d\aw)", item.Item.Name(), item.Item.ItemSlot(), item.Item.ItemSlot2())

        mq.cmd("/itemnotify in " ..
            vendorInv.toPack(item.Item.ItemSlot()) ..
            " " .. vendorInv.toBagSlot(item["Item"].ItemSlot2()) .. " leftmouseup")

        repeat
            mq.delay(10)
        until mq.TLO.Window("MerchantWnd").Child("MW_Sell_Button")() == "TRUE" and mq.TLO.Window("MerchantWnd").Child("MW_Sell_Button").Enabled()

        repeat
            mq.delay(500)
            if mq.TLO.Window("MerchantWnd").Child("MW_Sell_Button").Enabled() then
                Output("Pushign sell")
                mq.cmd("/shift /notify MerchantWnd MW_Sell_Button leftmouseup")
            end
        until mq.TLO.Window("MerchantWnd").Child("MW_Sell_Button")() ~= "TRUE"

        Output("\agDone selling...")
    else
        vendorInv:resetState()
    end
end

local function renderItems()
    if ImGui.BeginTable("BagItemList", ColumnID_LAST, bit32.bor(ImGuiTableFlags.Resizable, ImGuiTableFlags.Borders)) then
        ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0, 1.0, 1)
        ImGui.TableSetupColumn('Icon', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0,
            ColumnID_ItemIcon)
        ImGui.TableSetupColumn('Item',
            bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.PreferSortDescending,
                ImGuiTableColumnFlags.WidthStretch),
            150.0, ColumnID_Item)
        ImGui.TableSetupColumn('Junk', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0,
            ColumnID_Junk)
        ImGui.TableSetupColumn('Sell', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0,
            ColumnID_Sell)
        ImGui.PopStyleColor()
        ImGui.TableHeadersRow()

        for idx, item in ipairs(vendorInv.items) do
            local itemStartString = item.Item.Name():sub(1, 1)
            settings.Junk[itemStartString] = settings.Junk[itemStartString] or {}

            ImGui.PushID("#_itm_" .. tostring(idx))
            local currentItem = item.Item
            ImGui.TableNextColumn()
            animItems:SetTextureCell((tonumber(currentItem.Icon()) or 500) - 500)
            ImGui.DrawTextureAnimation(animItems, 20, 20)
            ImGui.TableNextColumn()
            if ImGui.Selectable(currentItem.Name(), false, 0) then
                currentItem.Inspect()
            end
            ImGui.TableNextColumn()
            if settings.Junk[itemStartString][item.Item.Name()] == true then
                ImGui.PushStyleColor(ImGuiCol.Text, 0.02, 0.8, 0.02, 1.0)
            else
                ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.02, 0.02, 1.0)
            end
            ImGui.PushID("#_btn_" .. tostring(idx))
            if ImGui.Selectable(ICONS.FA_TRASH_O) then
                settings.Junk[itemStartString][item.Item.Name()] = settings.Junk[itemStartString][item.Item.Name()] == nil and true or
                    not settings.Junk[itemStartString][item.Item.Name()]
                Output("\awToggled %s\aw for item: \at%s", settings.Junk[itemStartString][item.Item.Name()] and "\arJunk" or "\agNot-Junk", item.Item.Name())
                SaveSettings()
            end
            ImGui.PopID()
            ImGui.PopStyleColor()
            ImGui.TableNextColumn()
            if ImGui.Selectable(ICONS.MD_MONETIZATION_ON) then
                vendItem = item
            end
            ImGui.PopID()
        end

        ImGui.EndTable()
    end
end
local openLastFrame = false
local function vendorGUI()
    if mq.TLO.MacroQuest.GameState() ~= "INGAME" then return end

    local merchantWnd = mq.TLO.Window("MerchantWnd")
    if openGUI and merchantWnd.Open() then
        if not openLastFrame then
            vendorInv:createContainerInventory()
            vendorInv:getItems(sourceIndex)
        end

        openLastFrame = true
        ImGui.SetNextWindowPos(merchantWnd.X() + merchantWnd.Width(), merchantWnd.Y())
        ImGui.SetNextWindowSize(400, merchantWnd.Height())

        openGUI, shouldDrawGUI = ImGui.Begin('DerpleVend', openGUI,
            bit32.bor(ImGuiWindowFlags.NoResize, ImGuiWindowFlags.NoDecoration, ImGuiWindowFlags.NoCollapse, ImGuiWindowFlags.NoScrollWithMouse))

        ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 1, 1)
        local pressed

        if shouldDrawGUI then
            local disabled = false
            if vendItem ~= nil or sellAllJunk then
                ImGui.BeginDisabled()
                disabled = true
            end

            ImGui.Text("Item Filters: ")
            ImGui.SameLine()
            sourceIndex, pressed = ImGui.Combo("##Select Bag", sourceIndex, function(idx) return vendorInv.sendSources[idx].name end, #vendorInv.sendSources)
            if pressed then
                vendorInv:getItems(sourceIndex)
            end

            ImGui.Text(string.format("Filtered Items (%d):", #vendorInv.items or 0))

            ImGui.SameLine()

            if ImGui.SmallButton(ICONS.MD_REFRESH) then
                vendorInv:createContainerInventory()
                vendorInv:getItems(sourceIndex)
            end

            ImGui.SameLine()

            if ImGui.SmallButton("Sell Junk") then
                sellAllJunk = true
            end

            ImGui.Separator()

            ImGui.BeginChild("##VendorItems", -1, -1)
            renderItems()
            ImGui.EndChild()

            if disabled then
                ImGui.EndDisabled()
            end
        end

        ImGui.PopStyleColor()
        ImGui.End()
    else
        openLastFrame = false
    end
end

mq.imgui.init('vendorGUI', vendorGUI)

mq.bind("/vendor", function()
    openGUI = not openGUI
end
)

LoadSettings()

vendorInv:createContainerInventory()
vendorInv:getItems(sourceIndex)

Output("\aw>>> \ayDerple's Vendor tool loaded! Use \at/vendor\ay to open UI!")

-- Global Messaging callback
---@diagnostic disable-next-line: unused-local
local script_actor = actors.register(function(message)
    local msg = message()

    if msg["from"] == mq.TLO.Me.DisplayName() then
        return
    end
    if msg["script"] ~= "DerpleVend" then
        return
    end

    ---@diagnostic disable-next-line: redundant-parameter
    Output("\ayGot Event from(\am%s\ay) event(\at%s\ay)", msg["from"], msg["event"])

    if msg["event"] == "SaveSettings" then
        LoadSettings()
    end
end)

while not terminate do
    if mq.TLO.MacroQuest.GameState() ~= "INGAME" then return end

    if vendItem ~= nil then
        sellItem(vendItem)
        vendItem = nil
        mq.delay(50)
        Output("\amRefreshing inv...")
        vendorInv:createContainerInventory()
        vendorInv:getItems(sourceIndex)
    end

    if sellAllJunk then
        for _, item in ipairs(vendorInv.items) do
            local itemStartString = item.Item.Name():sub(1, 1)
            if settings.Junk[itemStartString] and settings.Junk[itemStartString][item.Item.Name()] == true then
                sellItem(item)
                mq.delay(50)
            end
        end

        Output("\amRefreshing inv...")
        vendorInv:createContainerInventory()
        vendorInv:getItems(sourceIndex)
        sellAllJunk = false
    end

    mq.doevents()
    mq.delay(400)
end
