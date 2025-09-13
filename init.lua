-- Combined Vendor Helper & Bag Seller
-- Original scripts by Derple and the author of sell_bags.lua
-- Merged and modified to integrate functionality.

local mq = require('mq')
local ImGui = require('ImGui')
local Icons = require('mq.Icons')
local showHidden = false
local vendorInv = require('vendor_inv')
local actors = require 'actors'
local animItems = mq.FindTextureAnimation("A_DragItem")

-- ===================================================================
-- == USER CONFIGURATION ==
-- ===================================================================
local DELAYS = {
    select = 1, -- Ticks to wait after selecting an item.
    sell   = 2, -- Ticks to wait after clicking the 'Sell' button.
    accept = 2, -- Ticks to wait after accepting a quantity window.
}
-- ===================================================================

-- General State
local openGUI = true
local shouldDrawGUI = false
local terminate = false

-- Settings Files
local settings_file = mq.configDir .. "/vendor.lua"
local custom_sources = mq.configDir .. "/vendor_sources.lua"
local settings = {}

-- Original Vendor Functionality State
local sourceIndex = 1
local lastInventoryScan = 0
local trackPlatDuringSell = false
local totalPlatThisSell = 0

-- Universal Selling State
local isSelling = false
local sellQueue = {}
local currentSellItem = nil
local sellStep = 'idle'
local stepDelay = 0

-- UI State
local bagSellUICollapsed = false
local showBagSellUI = false
local selectedBags = {}


-- ===================================================================
-- == HELPER FUNCTIONS ==
-- ===================================================================

local function Output(msg, ...)
    local formatted = msg
    if ... then
        formatted = string.format(msg, ...)
    end
    printf('\aw[' .. mq.TLO.Time() .. '] [\aoDerple\'s Vendor Helper, brought to you by Zero-Hex\aw] ::\a-t %s', formatted)
end

function Tooltip(desc)
    ImGui.SameLine()
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 25.0)
        ImGui.Text(desc)
        ImGui.PopTextWrapPos()
        ImGui.EndTooltip()
    end
end

local function IsMerchantOpen()
    return mq.TLO.Window('MerchantWnd').Open()
end

-- ===================================================================
-- == SETTINGS & IGNORE LIST MANAGEMENT ==
-- ===================================================================

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
    settings.Ignore = settings.Ignore or {}
    settings.Hide = settings.Hide or {} -- Added for the hide list

    local vendorSources = {}
    config, err = loadfile(custom_sources)
    if not err and config then
        vendorSources = config()
    end
    vendorInv = vendorInv:new(vendorSources)
end

local function IsIgnored(itemName)
    local itemStartString = itemName:sub(1, 1)
    return settings.Ignore[itemStartString] and settings.Ignore[itemStartString][itemName] == true
end

local function ToggleIgnore(itemName)
    local itemStartString = itemName:sub(1, 1)
    settings.Ignore[itemStartString] = settings.Ignore[itemStartString] or {}

    if IsIgnored(itemName) then
        settings.Ignore[itemStartString][itemName] = nil
        Output('\agRemoved "\at%s\ag" from the ignore list.', itemName)
    else
        settings.Ignore[itemStartString][itemName] = true
        Output('\arAdded "\at%s\ar" to the ignore list.', itemName)
    end
    SaveSettings()
end

local function IsJunk(itemName)
    local itemStartString = itemName:sub(1, 1)
    return settings.Junk[itemStartString] and settings.Junk[itemStartString][itemName] == true
end

-- Check if an item is marked as Hidden
local function IsHidden(itemName)
    local itemStartString = itemName:sub(1, 1)
    return settings.Hide[itemStartString] and settings.Hide[itemStartString][itemName] == true
end

-- Toggle an item's status in the Hide list
local function ToggleHide(itemName)
    local itemStartString = itemName:sub(1, 1)
    settings.Hide[itemStartString] = settings.Hide[itemStartString] or {}

    if IsHidden(itemName) then
        settings.Hide[itemStartString][itemName] = nil -- Use nil to remove the key
        Output('\agUn-hid item: "\at%s\ag".', itemName)
    else
        settings.Hide[itemStartString][itemName] = true
        Output('\arHid item: "\at%s\ar".', itemName)
    end
    SaveSettings()
end
-- ===================================================================
-- == SELLING LOGIC ==
-- ===================================================================

-- Scans selected bags and returns a table of sellable items and their total value.
local function GetSellableItemsFromSelectedBags()
    local items_to_sell = {}
    local total_value = 0
    for slot, selected in pairs(selectedBags) do
        if selected then
            local bag = mq.TLO.Me.Inventory(slot)
            if bag and bag() and bag.Item then
                for i = 1, bag.Container() do
                    local item = bag.Item(i)
                    if item and item() and item.Value and not item.NoDrop() and not IsIgnored(item.Name()) then
                        local itemValue = item.Value()
                        if type(itemValue) == 'number' and itemValue > 0 then
                            local stackSize = (item.Stack and item.Stack()) or 1
                            table.insert(items_to_sell, { Item = item, count = stackSize })
                            total_value = total_value + (itemValue * stackSize)
                        end
                    end
                end
            end
        end
    end
    return items_to_sell, total_value
end

-- Prepares the queue for bag selling.
local function PrepareBagSell()
    local items_to_sell, total_value = GetSellableItemsFromSelectedBags()
    sellQueue = items_to_sell

    if #sellQueue > 0 then
        Output("\ayStarting to sell \at%d\ay items from selected bags. Total value: \ag%.2fpp", #sellQueue, total_value / 1000)
        isSelling = true
        sellStep = 'idle'
    else
        Output("\ayNo valuable, non-ignored items found in the selected bags.")
    end
end

-- The Universal Selling State Machine
local function ManageSellState()
    if stepDelay > 0 then
        stepDelay = stepDelay - 1
        return
    end

    if sellStep == 'idle' then
        if #sellQueue == 0 then
            Output('\agFinished selling all items.')
            isSelling = false
            currentSellItem = nil
            -- Refresh inventory after a sell session is complete
            vendorInv:createContainerInventory()
            vendorInv:getItems(sourceIndex)
            return
        end
        currentSellItem = table.remove(sellQueue, 1)
        sellStep = 'select_item'
    end

    if sellStep == 'select_item' then
        local itemObject = currentSellItem.Item
        Output("\aySelling item: \at%s", itemObject.Name())
        mq.cmd("/itemnotify in " ..
            vendorInv.toPack(itemObject.ItemSlot()) ..
            " " .. vendorInv.toBagSlot(itemObject.ItemSlot2()) .. " leftmouseup")
        stepDelay = DELAYS.select
        sellStep = 'click_sell'
    elseif sellStep == 'click_sell' then
        mq.cmd('/shift /notify MerchantWnd MW_Sell_Button leftmouseup')
        stepDelay = DELAYS.sell
        sellStep = 'check_quantity'
    elseif sellStep == 'check_quantity' then
        local qtyWnd = mq.TLO.Window and mq.TLO.Window('QuantityWnd')
        if qtyWnd and qtyWnd.Open and qtyWnd.Open() then
            sellStep = 'click_accept'
        else
            sellStep = 'idle'
        end
    elseif sellStep == 'click_accept' then
        mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
        stepDelay = DELAYS.accept
        sellStep = 'idle'
    end
end

-- ===================================================================
-- == UI RENDERING ==
-- ===================================================================

local function renderItems()
    if ImGui.BeginTable("BagItemList", 6, bit32.bor(ImGuiTableFlags.Resizable, ImGuiTableFlags.Borders)) then
        ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0, 1.0, 1)
        ImGui.TableSetupColumn('Icon', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0)
        ImGui.TableSetupColumn('Item', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.PreferSortDescending, ImGuiTableColumnFlags.WidthStretch), 150.0)
        ImGui.TableSetupColumn('Junk', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0)
        ImGui.TableSetupColumn('Sell', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0)
        ImGui.TableSetupColumn('Ignore', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0)
        ImGui.TableSetupColumn('Hide', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0)
        ImGui.PopStyleColor()
        ImGui.TableHeadersRow()

        for idx, item in ipairs(vendorInv.items) do
            if item and item.Item() and item.Item.Name():len() > 0 then
                local itemName = item.Item.Name()
                local itemStartString = itemName:sub(1, 1)
                settings.Junk[itemStartString] = settings.Junk[itemStartString] or {}
                settings.Ignore[itemStartString] = settings.Ignore[itemStartString] or {}
                settings.Hide[itemStartString] = settings.Hide[itemStartString] or {}

                if not IsHidden(itemName) or showHidden then
                    ImGui.PushID("#_itm_" .. tostring(idx))
                    local currentItem = item.Item

                    ImGui.TableNextColumn()
                    animItems:SetTextureCell((tonumber(currentItem.Icon()) or 500) - 500)
                    ImGui.DrawTextureAnimation(animItems, 20, 20)

                    ImGui.TableNextColumn()

                    -- MODIFIED: Get stack count and format the display string
                    local stackCount = (currentItem.Stack and currentItem.Stack()) or 1
                    local displayText = itemName
                    if stackCount > 1 then
                        displayText = string.format("%s (%d)", itemName, stackCount)
                    end

                    -- MODIFIED: Use the new display text with the stack count
                    if ImGui.Selectable(displayText, false, 0) then
                        currentItem.Inspect()
                    end

                    ImGui.TableNextColumn()
                    ImGui.PushStyleColor(ImGuiCol.Text, unpack(IsJunk(itemName) and { 0.02, 0.8, 0.02, 1.0 } or { 0.8, 0.02, 0.02, 1.0 }))
                    ImGui.PushID("#_btn_jnk" .. tostring(idx))
                    if ImGui.Selectable(Icons.FA_TRASH_O) then
                        settings.Junk[itemStartString][itemName] = not IsJunk(itemName)
                        SaveSettings()
                    end
                    ImGui.PopID()
                    ImGui.PopStyleColor()

                    ImGui.TableNextColumn()
                    if ImGui.Selectable(Icons.MD_MONETIZATION_ON) then
                        table.insert(sellQueue, item)
                        isSelling = true
                    end
                    Tooltip("Sell this single item now")

                    ImGui.TableNextColumn()
                    ImGui.PushStyleColor(ImGuiCol.Text, unpack(IsIgnored(itemName) and { 0.02, 0.8, 0.02, 1.0 } or { 0.8, 0.02, 0.02, 1.0 }))
                    ImGui.PushID("#_btn_ignore" .. tostring(idx))
                    if ImGui.Selectable(IsIgnored(itemName) and Icons.FA_EYE or Icons.FA_EYE_SLASH) then
                        ToggleIgnore(itemName)
                    end
                    ImGui.PopID()
                    ImGui.PopStyleColor()

                    ImGui.TableNextColumn()
                    ImGui.PushStyleColor(ImGuiCol.Text, unpack(IsHidden(itemName) and { 0.02, 0.8, 0.02, 1.0 } or { 0.8, 0.02, 0.02, 1.0 }))
                    ImGui.PushID("#_btn_hide" .. tostring(idx))
                    if ImGui.Selectable(IsHidden(itemName) and Icons.FA_EYE_SLASH or Icons.FA_EYE) then
                        ToggleHide(itemName)
                    end
                    ImGui.PopID()
                    ImGui.PopStyleColor()

                    ImGui.PopID()
                end
            end
        end
        ImGui.EndTable()
    end
end

local function renderBagSellUI()
    ImGui.SetNextWindowSize(bagSellUICollapsed and 30 or 700, bagSellUICollapsed and 30 or 400)

    local visible, new_open_state = ImGui.Begin('Bag Selling', showBagSellUI, bit32.bor(ImGuiWindowFlags.NoDecoration, ImGuiWindowFlags.NoCollapse))
    showBagSellUI = new_open_state

    if not showBagSellUI then
        ImGui.End()
        return
    end

    -- MODIFIED: The window's content is now determined by our custom collapsed state.
    if bagSellUICollapsed then
        -- When collapsed, only show an "Expand" button.
        if ImGui.Button(">") then
            bagSellUICollapsed = false
        end
    else
        -- When expanded, show the "Collapse" button and all the content.
        if ImGui.Button("<") then
            bagSellUICollapsed = true
        end
        ImGui.SameLine()
        ImGui.Text("Bag Selling")
        ImGui.Separator()

        local disabled = isSelling
        if disabled then ImGui.BeginDisabled() end

        local items_to_preview, total_preview_value = GetSellableItemsFromSelectedBags()
        local _, avail_h = ImGui.GetContentRegionAvail()
        local child_height = avail_h - 60

        -- == LEFT COLUMN: BAG SELECTION ==
        ImGui.BeginChild("##BagSelect", 150, child_height, true)
        ImGui.Text("Select Bags:")
        ImGui.Separator()
        for i = 23, 32 do
            local item = mq.TLO.Me.Inventory(i)
            if item and item() and item.Container then
                local selected = selectedBags[i] or false
                local newSelected = ImGui.Checkbox(item.Name() .. '##' .. i, selected)
                if newSelected ~= selected then
                    selectedBags[i] = newSelected
                end
            end
        end
        ImGui.EndChild()

        ImGui.SameLine()

        -- == RIGHT COLUMN: ITEM PREVIEW ==
        ImGui.BeginChild("##ItemPreview", 0, child_height, true)
        local aggregated_items = {}
        local item_map = {}
        for _, item in ipairs(items_to_preview) do
            local name = item.Item.Name()
            if item_map[name] then
                item_map[name].count = item_map[name].count + item.count
            else
                item_map[name] = { count = item.count }
            end
        end
        for name, data in pairs(item_map) do
            table.insert(aggregated_items, { name = name, count = data.count })
        end
        table.sort(aggregated_items, function(a, b) return a.name < b.name end)

        ImGui.Text("Items to Sell (%d types)", #aggregated_items)
        ImGui.Text("Est. Total: %.2fpp", total_preview_value / 1000)
        ImGui.Separator()
        
        for _, item in ipairs(aggregated_items) do
            ImGui.Text("%s (%d)", item.name, item.count)
        end
        ImGui.EndChild()

        ImGui.Separator()

        if ImGui.Button(isSelling and "Selling..." or "Sell from Selected Bags") then
            PrepareBagSell()
        end

        if disabled then ImGui.EndDisabled() end
    end
    
    ImGui.End()
end

local openLastFrame = false
local collapsed = false
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
        ImGui.SetNextWindowSize(collapsed and 40 or 500, collapsed and 30 or merchantWnd.Height())

        openGUI, shouldDrawGUI = ImGui.Begin('DerpleVend', openGUI,
            bit32.bor(ImGuiWindowFlags.NoDecoration, ImGuiWindowFlags.NoCollapse, ImGuiWindowFlags.NoScrollWithMouse))

        ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 1, 1)

        if shouldDrawGUI then
            local disabled = isSelling
            if disabled then ImGui.BeginDisabled() end

            if collapsed then
                if ImGui.SmallButton(Icons.MD_CHEVRON_RIGHT) then collapsed = false end
            else
                ImGui.Text("Item Filters:")
            ImGui.SameLine()
            ImGui.PushItemWidth(200.0)
            local pressed
            sourceIndex, pressed = ImGui.Combo("##Select Bag", sourceIndex, function(idx) return vendorInv.sendSources[idx].name end, #vendorInv.sendSources)
            ImGui.PopItemWidth()
            if pressed then vendorInv:getItems(sourceIndex) end

                ImGui.SameLine()
                if ImGui.SmallButton(Icons.MD_CHEVRON_LEFT) then collapsed = true end

                ImGui.SameLine()
                if ImGui.SmallButton(Icons.MD_REFRESH) then
                    vendorInv:createContainerInventory()
                    vendorInv:getItems(sourceIndex)
                end
                Tooltip("Refresh item list")

                ImGui.Text(string.format("Filtered Items (%d):", #vendorInv.items or 0))
                ImGui.Separator()

                if ImGui.Button(isSelling and "Cancel" or "Sell Junk") then
                    if isSelling then
                        isSelling = false
                        sellQueue = {}
                        Output('\arSelling cancelled by user.')
                    else
                        for _, item in ipairs(vendorInv.items) do
                            if IsJunk(item.Item.Name()) then
                                table.insert(sellQueue, item)
                            end
                        end
                        if #sellQueue > 0 then
                            isSelling = true
                            trackPlatDuringSell = true
                            totalPlatThisSell = 0
                            Output("\ayStarting to sell \at%d\ay junk items.", #sellQueue)
                        else
                            Output("\ayNo junk items found to sell.")
                        end
                    end
                end
                Tooltip(isSelling and "Cancel the current sell queue" or "Sell all items marked as 'Junk'")

                ImGui.SameLine()
                if ImGui.Button("Bag Selling") then
                    showBagSellUI = not showBagSellUI
                end
                Tooltip("Open the 'Sell from Bags' window")
                
                -- MODIFIED: Added the new master toggle for showing hidden items
                ImGui.SameLine()
                if ImGui.SmallButton(showHidden and Icons.FA_EYE or Icons.FA_EYE_SLASH) then
                    showHidden = not showHidden
                end
                Tooltip("Toggle showing hidden items in the list")

                if disabled then ImGui.EndDisabled() end
                ImGui.Separator()

                ImGui.BeginChild("##VendorItems", 0, -1, ImGuiChildFlags.None, ImGuiWindowFlags.AlwaysVerticalScrollbar)
                renderItems()
                ImGui.EndChild()
            end
        end

        ImGui.PopStyleColor()
        
        local main_pos_x, main_pos_y = ImGui.GetWindowPos()
        local main_size_w, main_size_h = ImGui.GetWindowSize()
        ImGui.End()

        if showBagSellUI then
            ImGui.SetNextWindowPos(main_pos_x + main_size_w + 5, main_pos_y)
            renderBagSellUI()
        end
    else
        openLastFrame = false
    end
end
-- ===================================================================
-- == MAIN LOOP & INITIALIZATION ==
-- ===================================================================

mq.imgui.init('vendorGUI', vendorGUI)
mq.bind("/vendor", function() openGUI = not openGUI end)

mq.event('DerpleVend_PlatGain', '#*#You receive #1# platinum#*# from#*#', function(_, plat)
    if not trackPlatDuringSell then return end
    totalPlatThisSell = totalPlatThisSell + (tonumber((plat or '0'):gsub(',', '')) or 0)
end)

LoadSettings()
vendorInv:createContainerInventory()
vendorInv:getItems(sourceIndex)

Output("\aw>>> \ayDerple's Vendor tool (Combined) loaded! UI auto-shows with Merchant. Use \at/vendor\ay to toggle.")

while not terminate do
    if mq.TLO.MacroQuest.GameState() ~= "INGAME" then mq.delay(1000); goto continue end

    if openGUI and IsMerchantOpen() and mq.gettime() - lastInventoryScan > 1000 then
        lastInventoryScan = mq.gettime()
        vendorInv:getItems(sourceIndex)
    end

    -- Universal selling logic is now driven by the state machine
    if isSelling then
        if not IsMerchantOpen() then
            Output("\arMerchant window closed. Halting sell.")
            isSelling = false
            sellQueue = {}
        else
            ManageSellState()
        end
    elseif trackPlatDuringSell then
        -- This block runs once after a junk sale is completed (isSelling becomes false)
        Output("\agReceived \at%d\ag platinum from selling junk.", totalPlatThisSell)
        trackPlatDuringSell = false
        totalPlatThisSell = 0
    end

    mq.doevents()
    mq.delay(100)
    ::continue::
end
