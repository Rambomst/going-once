-- Scenario tests for Going Once on forever_sim, the headless Forever client from cjber/forever-core, with
-- Blizzard's real auction house UI and a fake server (fake_ah.lua). Run with tests/run.sh, which sets FOREVER_SIM
-- and GOINGONCE_SIM_CACHE.
local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local SIM = assert(os.getenv("FOREVER_SIM"), "FOREVER_SIM is not set: run tests/run.sh")
local CACHE = assert(os.getenv("GOINGONCE_SIM_CACHE"), "GOINGONCE_SIM_CACHE is not set: run tests/run.sh")
-- The repository root holds the addon's TOC; GOINGONCE_ADDON_DIR runs the scenarios against another copy, such as the
-- installed one.
local ADDON_DIR = os.getenv("GOINGONCE_ADDON_DIR") or (here .. "..")

local Sim = dofile(SIM .. "sim.lua")
local Fake = dofile(here .. "fake_ah.lua")

local GOLD, SILVER = 10000, 100

local SPEC = {
	money = 100 * GOLD,
	items = {
		{
			itemID = 2001,
			name = "Test Sword",
			auctions = { { id = 101, buyout = 2 * GOLD }, { id = 102, buyout = 3 * GOLD } },
		},
		{
			itemID = 2002,
			name = "Test Helm",
			auctions = {
				{ id = 201, buyout = 1 * GOLD, own = true },
				{ id = 202, bid = 50 * SILVER },
				{ id = 203, buyout = 4 * GOLD },
			},
		},
		{ itemID = 2003, name = "Test Epic", auctions = { { id = 301, buyout = 60 * GOLD } } },
		{ itemID = 2004, name = "Test Ring", auctions = { { id = 401, buyout = 5 * GOLD, own = true } } },
		{ itemID = 2005, name = "Test Crown", auctions = { { id = 501, buyout = 500 * GOLD } } },
		{
			itemID = 2006,
			name = "Test Bag",
			auctions = { { id = 601, buyout = 1 * GOLD }, { id = 602, buyout = 1 * GOLD } },
		},
	},
	commodities = {
		{
			itemID = 2589,
			name = "Linen Cloth",
			tiers = { { unitPrice = 50, quantity = 10 }, { unitPrice = 60, quantity = 30 } },
		},
		{ itemID = 118, name = "Minor Healing Potion", tiers = { { unitPrice = 10 * SILVER, quantity = 5 } } },
	},
}

local function deepcopy(t)
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for k, v in pairs(t) do
		out[k] = deepcopy(v)
	end
	return out
end

-- Gaps in the sim that only Blizzard's auction house code reaches; the client does these itself.
local function patchSim(sim)
	local mt = getmetatable(sim.G) or {}
	local prev = mt.__index
	mt.__index = function(t, k)
		if type(k) == "string" and k:find(".", 1, true) then
			local v = t
			for part in k:gmatch("[^.]+") do
				if type(v) ~= "table" then
					return nil
				end
				v = v[part]
			end
			return v
		end
		if type(prev) == "function" then
			return prev(t, k)
		elseif prev then
			return prev[k]
		end
	end
	setmetatable(sim.G, mt)
	sim.impl["C_Item.GetItemClassInfo"] = function(classID)
		return "Class " .. tostring(classID)
	end
	sim.impl["C_Item.GetItemSubClassInfo"] = function(classID, subClassID)
		return "Subclass " .. tostring(classID) .. "." .. tostring(subClassID)
	end
	sim.impl["C_Item.GetItemInventorySlotInfo"] = function(slot)
		return "Slot " .. tostring(slot)
	end
	-- Native in the client; the sim's generated stub returns "", which blanks every colored label.
	local function hex(color)
		local r, g, b, a = color.r, color.g, color.b, color.a
		local function byte(v)
			return math.floor((v or 1) * 255 + 0.5)
		end
		return string.format("%02x%02x%02x%02x", byte(a), byte(r), byte(g), byte(b))
	end
	sim.impl["C_ColorUtil.WrapTextInColor"] = function(text, color)
		return "|c" .. hex(color) .. tostring(text) .. "|r"
	end
	sim.impl["C_ColorUtil.WrapTextInColorCode"] = function(text, colorHexString)
		return "|c" .. tostring(colorHexString) .. tostring(text) .. "|r"
	end
end

local Session = {}
Session.__index = Session

-- A logged-in client at an open auction house that has searched once. opts.addon = false runs Blizzard alone.
local function open(opts)
	opts = opts or {}
	-- GOINGONCE_BASELINE=1 runs a scenario on Blizzard's UI alone, to tell a sim gap from an addon fault.
	if os.getenv("GOINGONCE_BASELINE") == "1" then
		opts.addon = false
	end
	local sim = Sim.new({ cache = CACHE })
	patchSim(sim)
	if opts.addon ~= false then
		sim:addon(ADDON_DIR)
	end
	local spec = deepcopy(SPEC)
	for k, v in pairs(opts.spec or {}) do
		spec[k] = v
	end
	local server = Fake.install(sim, spec)
	sim:login({ savedVariables = opts.saved })
	sim:takeErrors()
	sim:loadBlizzard("Blizzard_AuctionHouseUI")
	server:tick(0.1)
	local G = sim.G
	sim:showPanel(G.AuctionHouseFrame)
	server:tick(0.1)
	local s = setmetatable({ sim = sim, server = server, G = G }, Session)
	s:search()
	return s
end

function Session:search()
	self.sim:click(self.G.AuctionHouseFrame.SearchBar.SearchButton)
	self.server:tick(0.3)
end

function Session:list()
	return self.G.AuctionHouseFrame.BrowseResultsFrame.ItemList
end

function Session:rows()
	local out = {}
	local frames = self:list().ScrollBox:GetFrames()
	for _, row in ipairs(frames) do
		if row.rowData then
			out[#out + 1] = row
		end
	end
	return out
end

function Session:row(itemID)
	for _, row in ipairs(self:rows()) do
		if row.rowData.itemKey.itemID == itemID then
			return row
		end
	end
	error("no row for item " .. itemID, 2)
end

-- The row's Buy button: in the addon's column, anchored to the row.
function Session:button(itemID)
	local row = self:row(itemID)
	for _, child in ipairs({ self.G.GoingOnceColumn:GetChildren() }) do
		local _, relativeTo = child:GetPoint(1)
		if relativeTo == row and child:IsShown() then
			return child
		end
	end
	error("no Buy button for item " .. itemID, 2)
end

-- The button's text without color codes or money textures, e.g. "Buy", "4g", "11s".
function Session:label(itemID)
	local text = self:button(itemID):GetText() or ""
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	text = text:gsub("|T[^|]*GoldIcon[^|]*|t", "g")
		:gsub("|T[^|]*SilverIcon[^|]*|t", "s")
		:gsub("|T[^|]*CopperIcon[^|]*|t", "c")
	return text
end

function Session:enabled(itemID)
	return self:button(itemID):IsEnabled()
end

function Session:hoverRow(itemID, wait)
	self.sim:hover(self:row(itemID))
	self.server:tick(wait or 0.4)
end

function Session:hoverButton(itemID, wait)
	self.sim:hover(self:button(itemID))
	self.server:tick(wait or 0.4)
end

function Session:click(itemID, mouseButton, wait)
	self.sim:click(self:button(itemID), mouseButton)
	self.server:tick(wait or 0.4)
end

-- Color codes, links and money textures turned into plain text, e.g. "1g 50s 20c".
local function plain(line)
	line = line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	line = line:gsub("|T[^|]*GoldIcon[^|]*|t", "g"):gsub("|T[^|]*SilverIcon[^|]*|t", "s")
	line = line:gsub("|T[^|]*CopperIcon[^|]*|t", "c"):gsub("|H[^|]*|h", ""):gsub("|h", "")
	return line
end

-- Every chat line so far, as plain text.
function Session:chat()
	local lines = {}
	for _, line in ipairs(self.sim.chat) do
		lines[#lines + 1] = plain(line)
	end
	return table.concat(lines, " / ")
end

function Session:tooltip()
	local lines = {}
	local G = self.G
	for i = 1, G.GameTooltip:NumLines() do
		local fs = G["GameTooltipTextLeft" .. i]
		lines[#lines + 1] = plain(fs and fs:GetText() or "")
	end
	return table.concat(lines, " / ")
end

-- Errors the addon caused (in its code or in execution it tainted).
function Session:addonErrors()
	local out = {}
	for _, e in ipairs(self.sim:takeErrors()) do
		if e.taint == "GoingOnce" or tostring(e.message):find("GoingOnce", 1, true) then
			out[#out + 1] = e
		else
			self.otherErrors = self.otherErrors or {}
			self.otherErrors[#self.otherErrors + 1] = e
		end
	end
	return out
end

---------------------------------------------------------------------------------------------------------------
-- Runner
---------------------------------------------------------------------------------------------------------------

local tests = {}
local function test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

local function eq(actual, expected, what)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
	end
end

local function ok(value, what)
	if not value then
		error((what or "expected true") .. " was false", 2)
	end
end

local function noAddonErrors(s)
	local errors = s:addonErrors()
	if #errors > 0 then
		error("Going Once caused errors:\n" .. Sim.describe(errors), 2)
	end
end

---------------------------------------------------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------------------------------------------------

test("the browse list gets a Buy column", function()
	local s = open()
	eq(#s:rows() > 0, true, "rows shown")
	eq(s:label(2001), "Buy", "sword label")
	ok(s:enabled(2001), "sword button enabled")
	noAddonErrors(s)
end)

-- The sim does not lay out the auction house frame's own size, so this checks anchors, not pixels; the column's
-- real widths are worked out from Blizzard's XML in the ops README.
test("the Buy buttons have their own column right of Blizzard's, with a header", function()
	local function x(frame, which)
		for i = 1, frame:GetNumPoints() do
			local point, _, _, offset = frame:GetPoint(i)
			if point == which then
				return offset
			end
		end
	end
	local plain = open({ addon = false })
	local plainList = plain:list()
	local boxRight, barLeft = x(plainList.ScrollBox, "RIGHT"), x(plainList.ScrollBar, "TOPLEFT")

	local s = open()
	local list, column = s:list(), s.G.GoingOnceColumn
	ok(column and column:IsVisible(), "column shown")
	ok(column:DoesClipChildren(), "it clips the buttons where the list scrolls")
	local width = x(column, "BOTTOMRIGHT")
	ok(width and width >= 70, "a button wide")
	eq(x(list.ScrollBox, "RIGHT"), boxRight - width, "Blizzard's scroll box, and so its table, a column narrower")
	eq(x(list.ScrollBar, "TOPLEFT"), barLeft + width, "the scroll bar where it was")
	local button = s:button(2001)
	eq(button:GetParent(), column, "the button is in the column")
	local point, relativeTo, relativePoint = button:GetPoint(1)
	eq(point .. ">" .. relativePoint, "LEFT>RIGHT", "right of its row")
	eq(relativeTo, s:row(2001), "level with its row")
	local header
	for _, child in ipairs({ list.HeaderContainer:GetChildren() }) do
		if child:IsShown() and child.GetText and child:GetText() == "Buy" then
			header = child
		end
	end
	ok(header, "the column has a Buy header")
	eq(header:IsEnabled(), false, "which does not sort")
	noAddonErrors(s)
end)

test("a row scrolled out of the list takes its button with it", function()
	local items = {}
	for i = 1, 40 do
		items[i] = { itemID = 3000 + i, name = "Filler " .. i, auctions = { { id = 9000 + i, buyout = 1 * GOLD + i } } }
	end
	local s = open({ spec = { items = items, commodities = {} } })
	local column = s.G.GoingOnceColumn
	local function shown()
		local n = 0
		for _, child in ipairs({ column:GetChildren() }) do
			if child:IsShown() then
				n = n + 1
			end
		end
		return n
	end
	local rows = #s:rows()
	eq(shown(), rows, "one button per row on screen")
	s.sim.run(function()
		s:list().ScrollBox:ScrollToEnd(true)
	end)
	s.server:tick(0.1)
	eq(shown(), #s:rows(), "still one per row after scrolling")
	s:button(3040)
	noAddonErrors(s)
end)

test("Blizzard's own row click runs untainted", function()
	local s = open()
	s.sim:click(s:row(2001))
	s.server:tick(0.3)
	local query = s.server:last("SendSearchQuery")
	ok(query, "Blizzard searched the item")
	eq(query.taint, nil, "the search came from untainted code")
	eq(s.G.AuctionHouseFrame.ItemBuyFrame:IsShown(), true, "item view open")
	noAddonErrors(s)
end)

test("hovering a gear row reads its auctions, one click buys the cheapest", function()
	local s = open()
	s:hoverRow(2001)
	eq(s.server:count("SendSearchQuery"), 1, "searches after hover")
	eq(s.server.lastSearch, "2001:0:0:0", "last search")
	s:hoverButton(2001)
	eq(s.server:count("SendSearchQuery"), 1, "no second search for a fresh read")
	ok(s:tooltip():find("Cheapest: ", 1, true), "tooltip names the cheapest: " .. s:tooltip())
	s:click(2001)
	local bid = s.server:last("PlaceBid")
	ok(bid, "PlaceBid called")
	eq(bid.args[1], 101, "auction bought")
	eq(bid.args[2], 2 * GOLD, "price paid")
	ok(bid.hardware, "PlaceBid came from the click")
	eq(s.server.money, 98 * GOLD, "money after")
	eq(s:label(2001), "Bought", "flash after buying")
	s.server:tick(2)
	-- the next cheapest is read again while the mouse stays on the button
	eq(s.server:count("SendSearchQuery"), 2, "re-read after buying")
	eq(s:label(2001), "Buy", "label after the flash")
	noAddonErrors(s)
end)

test("buying again at the same price takes one click each", function()
	local s = open()
	s:hoverButton(2006)
	s:click(2006)
	eq(s:label(2006), "Bought", "first")
	s.server:tick(0.8)
	eq(s:label(2006), "Buy", "next one ready when the flash ends")
	s:click(2006)
	eq(s.server:count("PlaceBid"), 2, "second bought on one click")
	eq(s.server.money, 98 * GOLD, "paid twice")
	noAddonErrors(s)
end)

test("a click before the read only starts the read", function()
	local s = open()
	s.sim:hover(s:button(2001))
	s.sim:click(s:button(2001))
	eq(s.server:count("PlaceBid"), 0, "no bid without an auction")
	eq(s:label(2001), "...", "reading")
	s.server:tick(0.4)
	eq(s:label(2001), "Buy", "ready")
	s:click(2001)
	eq(s.server:count("PlaceBid"), 1, "bought on the next click")
	noAddonErrors(s)
end)

test("gear is read again when another item was searched since", function()
	local s = open()
	s:hoverRow(2001)
	s:hoverRow(2003)
	eq(s.server.lastSearch, "2003:0:0:0", "last search moved")
	-- moving onto the sword's button reads the sword again before the click can buy
	s.sim:hover(s:button(2001))
	s.sim:click(s:button(2001))
	eq(s.server:count("PlaceBid"), 0, "no bid on an auction from an older search")
	s.server:tick(0.4)
	s:click(2001)
	eq(s.server:count("PlaceBid"), 1, "bought after the new read")
	eq(s.server:last("PlaceBid").args[1], 101, "auction")
	noAddonErrors(s)
end)

test("own and bid-only auctions are skipped; a higher price asks for a second click", function()
	local s = open()
	s:hoverButton(2002)
	eq(s:label(2002), "Buy", "label while the list shows a lower price")
	ok(s:tooltip():find("More than the list shows", 1, true), "warns: " .. s:tooltip())
	s:click(2002)
	eq(s.server:count("PlaceBid"), 0, "first click only arms")
	eq(s:label(2002), "4g", "confirm shows the price")
	s:click(2002)
	eq(s.server:count("PlaceBid"), 1, "second click buys")
	eq(s.server:last("PlaceBid").args[1], 203, "the cheapest auction that is not ours and has a buyout")
	noAddonErrors(s)
end)

test("an armed confirm runs out", function()
	local s = open()
	s:hoverButton(2002)
	s:click(2002)
	eq(s:label(2002), "4g", "armed")
	s.server:tick(9)
	eq(s:label(2002), "Buy", "disarmed")
	noAddonErrors(s)
end)

test("expensive gear asks for a second click", function()
	local s = open()
	s:hoverButton(2003)
	s:click(2003)
	eq(s.server:count("PlaceBid"), 0, "armed only")
	s:click(2003)
	eq(s.server:count("PlaceBid"), 1, "bought")
	noAddonErrors(s)
end)

test("the confirm limit can be turned off", function()
	local s = open({ saved = { GoingOnceDB = { confirmAbove = 0 } } })
	s:hoverButton(2003)
	s:click(2003)
	eq(s.server:count("PlaceBid"), 1, "one click")
	noAddonErrors(s)
end)

test("only your own auctions: disabled with the reason", function()
	local s = open()
	s:hoverButton(2004)
	ok(not s:enabled(2004), "disabled")
	ok(s:tooltip():find("Only your own auctions", 1, true), "reason: " .. s:tooltip())
	noAddonErrors(s)
end)

test("too expensive for your gold: disabled", function()
	local s = open()
	ok(not s:enabled(2005), "disabled before the read")
	s:hoverButton(2005)
	ok(not s:enabled(2005), "disabled after the read")
	ok(s:tooltip():find("enough gold", 1, true), "reason: " .. s:tooltip())
	noAddonErrors(s)
end)

test("a trade good at the listed price buys on one click", function()
	local s = open()
	s:hoverButton(118)
	eq(s:label(118), "Buy", "label")
	s:click(118)
	local start = s.server:last("StartCommoditiesPurchase")
	ok(start and start.hardware, "purchase started from the click")
	eq(start.args[2], 1, "amount")
	local confirm = s.server:last("ConfirmCommoditiesPurchase")
	ok(confirm, "confirmed without a second click")
	eq(s.server.money, 100 * GOLD - 10 * SILVER, "paid")
	eq(s:label(118), "Bought", "flash")
	noAddonErrors(s)
end)

test("a trade good above the listed price shows the total and waits for the click", function()
	local s = open()
	s:hoverButton(2589)
	s:click(2589, "RightButton")
	local box = s.G.GameTooltip:GetOwner()
	ok(box and box.SetNumeric, "amount box shown")
	box:SetText("20")
	s.sim:input(function()
		box:GetScript("OnEnterPressed")(box)
	end)
	s.server:tick(0.2)
	eq(s:label(2589), "Buy 20", "amount kept")
	s:hoverButton(2589)
	ok(s:tooltip():find("About ", 1, true), "estimate: " .. s:tooltip())
	s:click(2589)
	eq(s.server:count("ConfirmCommoditiesPurchase"), 0, "waits: 10 at 50c and 10 at 60c average above 50c")
	eq(s:label(2589), "11s", "button shows the total")
	ok(s:tooltip():find("More than the list shows", 1, true), "warns: " .. s:tooltip())
	s:click(2589)
	eq(s.server:count("ConfirmCommoditiesPurchase"), 1, "confirmed by the click")
	eq(s.server.money, 100 * GOLD - 1100, "paid the quote")
	eq(s.sim:savedState().GoingOnceDB.amounts[2589], 20, "amount saved")
	noAddonErrors(s)
end)

test("an unconfirmed quote is given back when it runs out", function()
	local s = open({ saved = { GoingOnceDB = { amounts = { [2589] = 20 } } } })
	s:hoverButton(2589)
	s:click(2589)
	eq(s:label(2589), "11s", "waiting for the click")
	s.server:tick(31)
	ok(s.server:count("CancelCommoditiesPurchase") >= 1, "quote given back")
	eq(s:label(2589), "Buy 20", "back to Buy")
	noAddonErrors(s)
end)

test("with auto confirm off, a trade good always asks", function()
	local s = open({ saved = { GoingOnceDB = { autoConfirm = false } } })
	s:hoverButton(118)
	s:click(118)
	eq(s.server:count("ConfirmCommoditiesPurchase"), 0, "asks")
	s:click(118)
	eq(s.server:count("ConfirmCommoditiesPurchase"), 1, "confirmed")
	noAddonErrors(s)
end)

test("a blocked auto confirm falls back to the Confirm click", function()
	local s = open()
	-- the client refusing the confirm: the call is dropped and ADDON_ACTION_BLOCKED names it
	s.sim.impl["C_AuctionHouse.ConfirmCommoditiesPurchase"] = function()
		if not s.sim.hardwareInput then
			s.sim.events.queue("ADDON_ACTION_BLOCKED", "GoingOnce", "C_AuctionHouse.ConfirmCommoditiesPurchase()")
			return
		end
		s.server.money = s.server.money - 10 * SILVER
		s.server:after(function()
			s.server:fire("COMMODITY_PURCHASE_SUCCEEDED")
		end)
	end
	s:hoverButton(118)
	s:click(118)
	eq(s:label(118), "10s", "asks for the click instead")
	s:click(118)
	eq(s:label(118), "Bought", "bought with the click")
	eq(s.sim:savedState().GoingOnceDB.autoConfirm, false, "auto confirm turned off for good")
	noAddonErrors(s)
end)

test("an automatic confirm with no answer is not sent twice", function()
	local s = open()
	-- a server that never answers the confirm
	s.sim.impl["C_AuctionHouse.ConfirmCommoditiesPurchase"] = function()
		s.server.calls[#s.server.calls + 1] = { name = "ConfirmCommoditiesPurchase", args = {} }
	end
	s:hoverButton(118)
	s:click(118, nil, 11)
	eq(s.server:count("ConfirmCommoditiesPurchase"), 1, "one confirm")
	ok(s:chat():find("no answer from the auction house", 1, true), "says so: " .. s:chat())
	eq(s:label(118), "Buy", "back to Buy")
	eq(s.sim:savedState().GoingOnceDB.autoConfirm, true, "auto confirm stays on")
	noAddonErrors(s)
end)

test("a row whose item info loads late is read once it arrives", function()
	local s = open()
	local info = s.server.info[2001]
	s.server.info[2001] = nil
	s:search()
	s:hoverButton(2001)
	eq(s.server:count("SendSearchQuery"), 0, "nothing to read yet")
	ok(not s:enabled(2001), "disabled while loading")
	s.server.info[2001] = info
	s.server:fire("ITEM_KEY_ITEM_INFO_RECEIVED", 2001)
	s.server:tick(0.4)
	eq(s.server:count("SendSearchQuery"), 1, "read once the info came")
	eq(s:label(2001), "Buy", "ready")
	noAddonErrors(s)
end)

test("the request limit queues the read", function()
	local s = open()
	s.server.throttleReady = false
	s:hoverRow(2001)
	eq(s.server:count("SendSearchQuery"), 0, "held back")
	eq(s:label(2001), "...", "waiting")
	s.server.throttleReady = true
	s.server:fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
	s.server:tick(0.3)
	eq(s.server:count("SendSearchQuery"), 1, "sent when ready")
	eq(s:label(2001), "Buy", "ready")
	noAddonErrors(s)
end)

test("results the client already holds are read without an event", function()
	local s = open({ spec = { silentRepeatSearch = true } })
	s:hoverRow(2001)
	s:hoverRow(2003)
	s:hoverRow(2001, 1.5)
	eq(s.server:count("SendSearchQuery"), 3, "read again")
	s:hoverButton(2001)
	s:click(2001)
	eq(s.server:count("PlaceBid"), 1, "bought from the cached results")
	noAddonErrors(s)
end)

test("an item search that refreshes the browse list keeps its scroll position", function()
	local items = {}
	for i = 1, 40 do
		items[i] = { itemID = 3000 + i, name = "Filler " .. i, auctions = { { id = 9000 + i, buyout = 1 * GOLD + i } } }
	end
	local s = open({ spec = { items = items, commodities = {}, browseRefreshOnSearch = true } })
	local box = s:list().ScrollBox
	s.sim.run(function()
		box:ScrollToOffset(200, true)
	end)
	s.server:tick(0.1)
	local before = box:GetDerivedScrollOffset()
	ok(before > 0, "scrolled down")
	local row = s:rows()[3]
	s.sim:hover(row)
	s.server:tick(0.5)
	eq(s.server:count("SendSearchQuery"), 1, "the hover searched")
	eq(math.floor(box:GetDerivedScrollOffset() + 0.5), math.floor(before + 0.5), "scroll offset kept")
	s:search()
	eq(box:GetDerivedScrollOffset(), 0, "a new search starts at the top")
	noAddonErrors(s)
end)

test("closing the auction house gives back a pending quote", function()
	local s = open({ saved = { GoingOnceDB = { amounts = { [2589] = 20 } } } })
	s:hoverButton(2589)
	s:click(2589)
	s.sim.run(function()
		s.G.HideUIPanel(s.G.AuctionHouseFrame)
	end)
	s.server:fire("AUCTION_HOUSE_CLOSED")
	s.server:tick(0.2)
	ok(s.server:count("CancelCommoditiesPurchase") >= 1, "quote given back")
	noAddonErrors(s)
end)

-- Blizzard's own buy windows stop short in the sim (its static popups cannot take a script on a font string, and
-- its money display reads 0, so the commodity dialog refuses every quote). So these compare a run without Browse
-- Buy against a run with it: the same steps must end the same way, with no purchase call from Going Once.
local PURCHASE_CALLS = { PlaceBid = true, StartCommoditiesPurchase = true, ConfirmCommoditiesPurchase = true }

local function runBlizzardFlow(addon, steps)
	local s = open({ addon = addon })
	s.sim:takeErrors()
	local seen = steps(s)
	local calls, ours = {}, 0
	for _, call in ipairs(s.server.calls) do
		if PURCHASE_CALLS[call.name] then
			calls[#calls + 1] = call.name .. (call.taint and ("@" .. call.taint) or "")
			if call.taint == "GoingOnce" then
				ours = ours + 1
			end
		end
	end
	local messages = {}
	for _, e in ipairs(s.sim:takeErrors()) do
		messages[#messages + 1] = tostring(e.message):sub(1, 120)
	end
	table.sort(messages)
	return table.concat(seen, ",") .. " | " .. table.concat(calls, ",") .. " | " .. table.concat(messages, ";"), ours
end

local function gearSteps(s)
	local G = s.G
	s.sim:click(s:row(2001))
	s.server:tick(0.3)
	local frame = G.AuctionHouseFrame.ItemBuyFrame
	for _, row in ipairs(frame.ItemList.ScrollBox:GetFrames()) do
		if row.rowData and row.rowData.auctionID == 101 then
			s.sim:click(row)
		end
	end
	s.server:tick(0.1)
	s.sim:click(frame.BuyoutFrame.BuyoutButton)
	s.server:tick(0.1)
	local dialog = G.StaticPopup_FindVisible("BUYOUT_AUCTION")
	if dialog then
		s.sim:click(dialog:GetButton1())
		s.server:tick(0.3)
	end
	return {
		"view " .. tostring(frame:IsShown()),
		"selected " .. tostring(frame.auctionID),
		"popup " .. tostring(dialog ~= nil),
	}
end

local function commoditySteps(s)
	local G = s.G
	s.sim:click(s:row(118))
	s.server:tick(0.3)
	local frame = G.AuctionHouseFrame.CommoditiesBuyFrame
	s.sim:click(frame.BuyDisplay.BuyButton)
	s.server:tick(0.3)
	local dialog = G.AuctionHouseFrame.BuyDialog
	local seen = {
		"view " .. tostring(frame:IsShown()),
		"dialog " .. tostring(dialog:IsShown()),
		"buy now " .. tostring(dialog.BuyNowButton:IsShown()),
	}
	if dialog.BuyNowButton:IsShown() then
		s.sim:click(dialog.BuyNowButton)
		s.server:tick(0.3)
	end
	return seen
end

test("Blizzard's own gear buyout runs as it does without Going Once", function()
	local without = runBlizzardFlow(false, gearSteps)
	local with, ours = runBlizzardFlow(nil, gearSteps)
	eq(with, without, "same steps, same result")
	eq(ours, 0, "no purchase call from Going Once")
end)

test("Blizzard's own trade good purchase runs as it does without Going Once", function()
	local without = runBlizzardFlow(false, commoditySteps)
	local with, ours = runBlizzardFlow(nil, commoditySteps)
	eq(with, without, "same steps, same result")
	eq(ours, 0, "no purchase call from Going Once")
end)

test("the options live in the settings panel, and /goingonce opens it", function()
	local s = open()
	local G = s.G
	local opened
	s.sim.impl["C_SettingsUtil.OpenSettingsPanel"] = function(categoryID)
		opened = categoryID
	end
	local auto = G.Settings.GetSetting("GoingOnce_autoConfirm")
	local announce = G.Settings.GetSetting("GoingOnce_announce")
	local gear = G.Settings.GetSetting("GoingOnce_confirmAbove")
	ok(auto and announce and gear, "settings registered")
	eq(gear:GetValue(), 50 * GOLD, "50g by default")
	s.sim.run(function()
		auto:SetValue(false)
		announce:SetValue(false)
		gear:SetValue(1 * GOLD + 50 * SILVER + 20)
	end)
	local db = s.sim:savedState().GoingOnceDB
	eq(db.autoConfirm, false, "auto confirm off")
	eq(db.announce, false, "chat line off")
	eq(db.confirmAbove, 15020, "second click from 1g 50s 20c")
	s.sim:slash("/goingonce")
	ok(opened, "settings panel opened")
	local category = G.Settings.GetCategory(opened)
	eq(category and category:GetName(), "Going Once", "on Going Once's page")
	noAddonErrors(s)
end)

test("the second-click amount takes gold, silver and copper in the settings panel", function()
	local s = open()
	local G = s.G
	local opened
	s.sim.impl["C_SettingsUtil.OpenSettingsPanel"] = function(categoryID)
		opened = categoryID
	end
	s.sim:slash("/goingonce")
	local category = opened and G.Settings.GetCategory(opened)
	ok(category, "category registered")
	s.sim.run(function()
		G.SettingsPanel:Show()
		G.SettingsPanel:SelectCategory(category)
	end)
	s.server:tick(0.1)
	local row
	for _, frame in ipairs(G.SettingsPanel:GetSettingsList().ScrollBox:GetFrames()) do
		if frame.Input and frame.data and frame.data.setting:GetVariable() == "GoingOnce_confirmAbove" then
			row = frame
		end
	end
	ok(row, "the money row is shown")
	eq(row.Input.gold:GetText(), "50", "gold box shows the default")
	s.sim:input(function()
		row.Input.gold:SetText("1")
		row.Input.silver:SetText("50")
		row.Input.copper:SetText("20")
	end)
	eq(s.sim:savedState().GoingOnceDB.confirmAbove, 15020, "typed amount saved")
	s.sim:input(function()
		row.Input.gold:SetText("")
		row.Input.silver:SetText("")
		row.Input.copper:SetText("")
	end)
	eq(s.sim:savedState().GoingOnceDB.confirmAbove, 0, "empty is never")
	eq(row.Hint:GetText(), "Never", "says so")
	s.sim.run(function()
		G.Settings.GetSetting("GoingOnce_confirmAbove"):SetValue(3 * GOLD + 7)
	end)
	eq(row.Input.gold:GetText() .. "/" .. row.Input.copper:GetText(), "3/7", "boxes follow the setting")
	eq(row.Hint:GetText(), "", "hint gone")
	noAddonErrors(s)
end)

-- The rows of Going Once's page in Blizzard's settings panel, opened as /goingonce opens it.
local function settingsRows(s)
	local G = s.G
	local opened
	s.sim.impl["C_SettingsUtil.OpenSettingsPanel"] = function(categoryID)
		opened = categoryID
	end
	s.sim:slash("/goingonce")
	s.sim.run(function()
		G.SettingsPanel:Show()
		G.SettingsPanel:SelectCategory(G.Settings.GetCategory(opened))
	end)
	s.server:tick(0.1)
	return G.SettingsPanel:GetSettingsList().ScrollBox:GetFrames()
end

local function leftX(region)
	for i = 1, region:GetNumPoints() do
		local point, _, relativePoint, x = region:GetPoint(i)
		if point == "LEFT" then
			return relativePoint .. " " .. x
		end
	end
end

test("the settings rows line up, and Forget clears the saved amounts", function()
	local s = open({ saved = { GoingOnceDB = { amounts = { [2589] = 20 } } } })
	local checkbox, money, forget
	for _, row in ipairs(settingsRows(s)) do
		if row.Checkbox then
			checkbox = row.Checkbox
		elseif row.Input then
			money = row.Input
		elseif row.Button and row.data and row.data.buttonText == "Forget" then
			forget = row.Button
		end
	end
	ok(checkbox and money and forget, "a checkbox, the money boxes and Forget")
	eq(leftX(checkbox), "CENTER -80", "Blizzard's checkbox")
	-- The gold box draws its border 5 outside itself.
	eq(leftX(money), "CENTER -75", "money boxes start where the checkbox does")
	eq(leftX(forget), "CENTER -80", "Forget starts there too")
	eq(forget:GetWidth(), 191, "and is as wide as the money boxes")
	s.sim:click(forget)
	eq(s.sim:savedState().GoingOnceDB.amounts[2589], nil, "amounts forgotten")
	ok(s:chat():find("trade goods buy one at a time again", 1, true), "says so: " .. s:chat())
	noAddonErrors(s)
end)

test("Shift-click chooses a trade good's amount; it never buys gear", function()
	local s = open()
	s:hoverButton(118)
	ok(s:tooltip():find("Right-click or Shift-click to choose how many.", 1, true), "tooltip says how: " .. s:tooltip())
	s.sim.modifiers.shift = true
	s:click(118)
	s.sim.modifiers.shift = false
	eq(s.server:count("StartCommoditiesPurchase"), 0, "no purchase")
	local box = s.G.GameTooltip:GetOwner()
	ok(box and box.SetNumeric, "amount box shown")
	box:SetText("5")
	s.sim:input(function()
		box:GetScript("OnEnterPressed")(box)
	end)
	s.server:tick(0.2)
	eq(s:label(118), "Buy 5", "amount kept")
	s:hoverButton(2001)
	s.sim.modifiers.shift = true
	s:click(2001)
	s.sim.modifiers.shift = false
	eq(s.server:count("PlaceBid"), 0, "a Shift-click on gear does not buy")
	noAddonErrors(s)
end)

test("the first single trade good bought tells once how to buy more", function()
	local s = open()
	s:hoverButton(118)
	s:click(118)
	local tip = "to buy more than one, right-click or Shift-click a trade good's Buy button."
	ok(s:chat():find(tip, 1, true), "tip shown: " .. s:chat())
	s.server:tick(1)
	s:click(118)
	local _, count = s:chat():gsub("to buy more than one", "")
	eq(count, 1, "only once")
	eq(s.sim:savedState().GoingOnceDB.amountTip, true, "remembered")
	noAddonErrors(s)
end)

test("gear from an odd second-click amount up asks twice; cheaper buys at once", function()
	local s = open({ saved = { GoingOnceDB = { confirmAbove = 1 * GOLD + 50 * SILVER + 20 } } })
	s:hoverButton(2006)
	s:click(2006)
	eq(s.server:count("PlaceBid"), 1, "1g bought on one click")
	s.server:tick(1)
	s:hoverButton(2001)
	ok(s:tooltip():find("Click twice to buy (1g 50s 20c or more)", 1, true), "tooltip says so: " .. s:tooltip())
	s:click(2001)
	eq(s.server:count("PlaceBid"), 1, "2g only armed")
	s:click(2001)
	eq(s.server:count("PlaceBid"), 2, "second click buys")
	noAddonErrors(s)
end)

test("a purchase says in chat what it cost", function()
	local s = open()
	s:hoverButton(2001)
	s:click(2001)
	ok(s:chat():find("bought .*Test Sword.* for 2g"), "gear line: " .. s:chat())
	s:hoverButton(118)
	s:click(118)
	ok(s:chat():find("bought 1 .*Minor Healing Potion.* for 10s %(10s each%)"), "trade good line: " .. s:chat())
	noAddonErrors(s)
end)

test("the chat line can be turned off", function()
	local s = open({ saved = { GoingOnceDB = { announce = false } } })
	s:hoverButton(2001)
	s:click(2001)
	eq(s:chat():find("bought", 1, true), nil, "no line")
	noAddonErrors(s)
end)

test("a refused purchase says nothing was bought", function()
	local s = open()
	s:hoverButton(2001)
	-- someone else buys it between the read and the click
	table.remove(s.server.items["2001:0:0:0"].auctions, 1)
	s:click(2001)
	ok(s:chat():find("refused that purchase", 1, true), "says so: " .. s:chat())
	ok(s:chat():find("Nothing was bought", 1, true), "nothing bought")
	eq(s.server.money, 100 * GOLD, "no money spent")
	noAddonErrors(s)
end)

-- In game (2026-11-15 and 16): the server answered 2 of 7 logged buyouts with "Internal auction error" within 30 ms,
-- then sold the item 2 to 3 seconds later.
test("a buyout the server answers with an error still goes through, and chat says so", function()
	local s = open({ spec = { strayError = 10, buyAnswer = 2.5, wonNotice = true } })
	s:hoverButton(2001)
	s:click(2001, nil, 1)
	eq(s:label(2001), "...", "still waiting for the bid's answer")
	eq(s:chat():find("refused", 1, true), nil, "no refusal: " .. s:chat())
	s.server:tick(2)
	ok(s:chat():find("bought .*Test Sword.* for 2g%."), "bought line: " .. s:chat())
	ok(s:chat():find('The "Internal auction error" message did not stop it.', 1, true), "explains: " .. s:chat())
	eq(s:chat():find("Nothing was bought", 1, true), nil, "no false claim: " .. s:chat())
	eq(s.server.money, 98 * GOLD, "paid")
	noAddonErrors(s)
end)

test("a trade good bought through an unclear error is announced", function()
	local s = open({ spec = { strayError = 10, buyAnswer = 2.5 } })
	s:hoverButton(118)
	s:click(118, nil, 3)
	ok(s:chat():find("bought 1 .*Minor Healing Potion.* for 10s"), "bought line: " .. s:chat())
	eq(s:chat():find("refused", 1, true), nil, "no refusal: " .. s:chat())
	noAddonErrors(s)
end)

test("an unclear error with no answer says to check the mail, not that nothing was bought", function()
	local s = open({ spec = { strayError = 10, buySilent = true } })
	s:hoverButton(2001)
	s:click(2001, nil, 4)
	eq(s:chat():find("answered with an error", 1, true), nil, "still waiting after 4 seconds: " .. s:chat())
	s.server:tick(2)
	ok(s:chat():find("answered with an error (", 1, true), "says so: " .. s:chat())
	ok(s:chat():find("Check your mail", 1, true), "points at the mail: " .. s:chat())
	eq(s:chat():find("Nothing was bought", 1, true), nil, "no false claim: " .. s:chat())
	eq(s:label(2001), "Buy", "button back")
	noAddonErrors(s)
end)

test("a purchase answered after it was given up on is still reported", function()
	local s = open({ spec = { strayError = 10, buyAnswer = 8, wonNotice = true } })
	s:hoverButton(2001)
	s:click(2001, nil, 6)
	ok(s:chat():find("answered with an error (", 1, true), "gave up: " .. s:chat())
	s.server:tick(3)
	ok(s:chat():find("bought .*Test Sword.* for 2g after all%."), "late line: " .. s:chat())
	noAddonErrors(s)
end)

test("the You won an auction notice settles a bid on its own", function()
	local s = open({ spec = { noCompletedEvent = true, wonNotice = true } })
	s:hoverButton(2001)
	s:click(2001)
	ok(s:chat():find("bought .*Test Sword.* for 2g%."), "bought line: " .. s:chat())
	noAddonErrors(s)
end)

test("no read goes out while a trade good's quote is open", function()
	local s = open({ saved = { GoingOnceDB = { amounts = { [2589] = 20 } } } })
	s:hoverButton(2589)
	s:click(2589)
	eq(s:label(2589), "11s", "quote open, waiting for the click")
	local searches = s.server:count("SendSearchQuery")
	s:hoverRow(2001, 0.6)
	eq(s.server:count("SendSearchQuery"), searches, "the read waits")
	s:hoverButton(2589)
	s:click(2589)
	eq(s.server:count("ConfirmCommoditiesPurchase"), 1, "confirmed")
	eq(s.server.money, 100 * GOLD - 1100, "the quote was still good")
	eq(s.server:count("SendSearchQuery"), searches + 2, "the held read and the re-read went out after")
	noAddonErrors(s)
end)

test("a trade good is read again when another item was searched since", function()
	local s = open()
	s:hoverRow(118)
	s:hoverRow(2001)
	s.sim:hover(s:button(118))
	s.sim:click(s:button(118))
	eq(s.server:count("StartCommoditiesPurchase"), 0, "the click only reads")
	s.server:tick(0.4)
	s:click(118)
	eq(s.server:count("StartCommoditiesPurchase"), 1, "bought on the next click")
	eq(s.server.money, 100 * GOLD - 10 * SILVER, "paid")
	noAddonErrors(s)
end)

test("purchases are logged for later", function()
	local s = open()
	s:hoverButton(2001)
	s:click(2001)
	-- another addon's request
	s.sim.run(function()
		s.G.C_AuctionHouse.QueryOwnedAuctions({})
	end)
	local log = table.concat(s.sim:savedState().GoingOnceDB.log, "\n")
	ok(log:find("bid 2001:0:0:0 auction 101 buyout 20000", 1, true), "bid logged:\n" .. log)
	ok(log:find("sent PlaceBid 101 20000", 1, true), "request logged:\n" .. log)
	ok(log:find("bought 2001:0:0:0", 1, true), "result logged")
	ok(log:find("sent QueryOwnedAuctions {}", 1, true), "other senders' requests logged:\n" .. log)
	noAddonErrors(s)
end)

test("Going Once adds no Blizzard errors", function()
	-- Both runs see the same server events; only the run with the addon clicks its buttons.
	local function blizzardErrors(addon)
		local s = open({ addon = addon })
		s:hoverRow(2001)
		s:hoverRow(118)
		if addon ~= false then
			s:hoverButton(2001)
			s:click(2001)
			s:hoverButton(118)
			s:click(118)
		else
			s.server:fire("PLAYER_MONEY")
		end
		s.server:tick(2)
		s.sim.run(function()
			s.G.HideUIPanel(s.G.AuctionHouseFrame)
		end)
		s.server:fire("AUCTION_HOUSE_CLOSED")
		s.server:tick(0.2)
		local counts = {}
		for _, e in ipairs(s.sim:takeErrors()) do
			local m = tostring(e.message):sub(1, 160)
			counts[m] = (counts[m] or 0) + 1
		end
		return counts
	end
	local without = blizzardErrors(false)
	local with = blizzardErrors(true)
	local extra = {}
	for m in pairs(with) do
		if not without[m] then
			extra[#extra + 1] = m
		end
	end
	if #extra > 0 then
		error("errors only with Going Once:\n" .. table.concat(extra, "\n"))
	end
end)

---------------------------------------------------------------------------------------------------------------

local filter = arg and arg[1]
local passed, failed = 0, 0
for _, t in ipairs(tests) do
	if not filter or t.name:find(filter, 1, true) then
		local ok_, err = xpcall(t.fn, debug.traceback)
		if ok_ then
			passed = passed + 1
			print("ok    " .. t.name)
		else
			failed = failed + 1
			print("FAIL  " .. t.name .. "\n      " .. tostring(err):gsub("\n", "\n      "))
		end
	end
end
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
