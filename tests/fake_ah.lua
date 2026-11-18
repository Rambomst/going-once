-- A stand-in for Forever's auction house server, behind the sim's documented C_AuctionHouse stubs. It answers
-- after a short latency, enforces the rules the addon relies on (a bid only on an auction from the last item
-- search, a commodity purchase only after its quote), and logs every call so tests can check them.
local Fake = {}
Fake.__index = Fake

local function keyOf(itemKey)
	return string.format(
		"%d:%d:%d:%d",
		itemKey.itemID,
		itemKey.itemLevel or 0,
		itemKey.itemSuffix or 0,
		itemKey.battlePetSpeciesID or 0
	)
end
Fake.keyOf = keyOf

-- spec.items: { { itemID, name, itemLevel?, auctions = { { id, buyout?, own?, account? } } } }
-- spec.commodities: { { itemID, name, tiers = { { unitPrice, quantity, own? } } } }
-- spec.browseRefreshOnSearch: every item search also refreshes the browse results, as Forever's server does;
-- spec.browseRefreshDelay: seconds after the search's answer that the refresh comes (default: with the answer).
-- spec.secondAnswer: seconds after its first answer that an item search is answered again (0.13 to 0.58 s in game,
-- 2026-11-18). spec.browseAnswer: seconds until a browse search is answered (default: latency).
-- spec.buyAnswer: seconds until a bid or confirm is answered (default: latency); spec.buySilent: never answered.
-- spec.strayError: an error code sent right after each bid or confirm that still goes through.
-- A bid whose amount has copper in it is always answered with "Internal auction error" and still goes through, as
-- on Forever's server (all 4 such buyouts logged in game, 2026-11-15 to 18). self.errors counts the errors sent.
-- spec.wonNotice: a bought auction also gets the "You won an auction" notification; spec.noCompletedEvent drops
-- AUCTION_HOUSE_PURCHASE_COMPLETED.
function Fake.install(sim, spec)
	local self = setmetatable({}, Fake)
	self.sim = sim
	self.latency = spec.latency or 0.1
	self.money = spec.money or 1000000
	self.throttleReady = true
	self.calls = {}
	self.errors = 0
	self.queue = {}
	self.searched = {}
	self.lastSearch = nil
	self.browseRefreshOnSearch = spec.browseRefreshOnSearch
	self.browseRefreshDelay = spec.browseRefreshDelay
	self.secondAnswer = spec.secondAnswer
	self.browseAnswer = spec.browseAnswer
	self.silentRepeatSearch = spec.silentRepeatSearch
	self.buyAnswer = spec.buyAnswer
	self.buySilent = spec.buySilent
	self.strayError = spec.strayError
	self.wonNotice = spec.wonNotice
	self.noCompletedEvent = spec.noCompletedEvent
	self.items, self.commodities, self.info = {}, {}, {}
	for _, item in ipairs(spec.items or {}) do
		local itemKey =
			{ itemID = item.itemID, itemLevel = item.itemLevel or 0, itemSuffix = 0, battlePetSpeciesID = 0 }
		item.itemKey = itemKey
		self.items[keyOf(itemKey)] = item
		self.info[item.itemID] = { name = item.name, isCommodity = false, isEquipment = true }
	end
	for _, c in ipairs(spec.commodities or {}) do
		c.itemKey = { itemID = c.itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
		self.commodities[c.itemID] = c
		self.info[c.itemID] = { name = c.name, isCommodity = true, isEquipment = false }
	end

	local impl = sim.impl
	local function log(name, ...)
		self.calls[#self.calls + 1] =
			{ name = name, args = { ... }, hardware = sim.hardwareInput, taint = sim.taint.current }
	end
	local function api(name, f)
		impl["C_AuctionHouse." .. name] = function(...)
			log(name, ...)
			return f(...)
		end
	end

	-- Item data the client holds for real items; Blizzard's item display needs it to know what it shows.
	local function itemLink(itemID)
		local name = self.info[itemID] and self.info[itemID].name or ("Item " .. itemID)
		return string.format("|cff1eff00|Hitem:%d::::::::60:::::::::|h[%s]|h|r", itemID, name)
	end
	local function idOf(item)
		if type(item) == "number" then
			return item
		end
		return tonumber(tostring(item):match("item:(%d+)"))
	end
	impl["C_Item.GetItemInfo"] = function(item)
		local itemID = idOf(item)
		local info = itemID and self.info[itemID]
		if not info then
			return nil
		end
		local stack = info.isCommodity and 20 or 1
		return info.name, itemLink(itemID), 2, 20, 1, "Trade Goods", "Parts", stack, "", 134400, 100, 7, 0, 0
	end
	impl["C_Item.GetItemInfoInstant"] = function(item)
		local itemID = idOf(item)
		if not itemID or not self.info[itemID] then
			return nil
		end
		return itemID, "Trade Goods", "Parts", "", 134400, 7, 0
	end
	impl["C_Item.GetItemNameByID"] = function(item)
		local itemID = idOf(item)
		return itemID and self.info[itemID] and self.info[itemID].name or nil
	end
	impl["C_Item.GetItemQualityByID"] = function(item)
		local itemID = idOf(item)
		return itemID and self.info[itemID] and 2 or nil
	end
	impl["C_Item.GetItemIconByID"] = function()
		return 134400
	end
	impl["C_Item.DoesItemExistByID"] = function(item)
		local itemID = idOf(item)
		return itemID ~= nil and self.info[itemID] ~= nil
	end
	impl["C_Item.IsItemDataCachedByID"] = impl["C_Item.DoesItemExistByID"]

	impl.GetMoney = function()
		return self.money
	end
	api("IsThrottledMessageSystemReady", function()
		return self.throttleReady
	end)
	api("HasFavorites", function()
		return false
	end)
	api("SupportsCopperValues", function()
		return true
	end)
	api("HasFullBrowseResults", function()
		return true
	end)
	api("GetItemKeyInfo", function(itemKey)
		local info = itemKey and self.info[itemKey.itemID]
		if not info then
			return nil
		end
		return {
			itemID = itemKey.itemID,
			battlePetSpeciesID = 0,
			itemName = info.name,
			quality = 2,
			iconFileID = 134400,
			isPet = false,
			isCommodity = info.isCommodity,
			isEquipment = info.isEquipment,
		}
	end)
	api("SendBrowseQuery", function()
		self:after(function()
			self.browse = self:browseResults()
			self:fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
		end, self.browseAnswer)
	end)
	-- The client holds the results of the last browse search answered; an item search only refreshes its own row.
	api("GetBrowseResults", function()
		local out = {}
		for i, result in ipairs(self.browse or {}) do
			out[i] = {
				itemKey = result.itemKey,
				totalQuantity = result.totalQuantity,
				minPrice = result.minPrice,
				containsOwnerItem = result.containsOwnerItem,
			}
		end
		return out
	end)
	api("SendSearchQuery", function(itemKey)
		local key = keyOf(itemKey)
		local repeated = self.searched[key]
		self.searched[key] = true
		self.lastSearch = key
		-- A search while a quote is open spoils it (auxForever, "Internal auction error").
		if self.quote then
			self.quote.spoiled = true
		end
		if repeated and self.silentRepeatSearch then
			return
		end
		local function answer()
			if self.commodities[itemKey.itemID] then
				self:fire("COMMODITY_SEARCH_RESULTS_UPDATED", itemKey.itemID)
			else
				self:fire("ITEM_SEARCH_RESULTS_UPDATED", itemKey, nil)
			end
		end
		local function refresh()
			for _, fresh in ipairs(self:browseResults()) do
				for i, held in ipairs(self.browse or {}) do
					if keyOf(held.itemKey) == key and keyOf(fresh.itemKey) == key then
						self.browse[i] = fresh
					end
				end
			end
			self:fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
		end
		self:after(function()
			answer()
			if self.browseRefreshOnSearch and not self.browseRefreshDelay then
				refresh()
			end
		end)
		if self.browseRefreshOnSearch and self.browseRefreshDelay then
			self:after(refresh, self.latency + self.browseRefreshDelay)
		end
		if self.secondAnswer then
			self:after(answer, self.latency + self.secondAnswer)
		end
	end)
	api("HasSearchResults", function(itemKey)
		return self.searched[keyOf(itemKey)] == true
	end)
	api("GetNumItemSearchResults", function(itemKey)
		local item = self.items[keyOf(itemKey)]
		return item and #item.auctions or 0
	end)
	api("GetItemSearchResultInfo", function(itemKey, index)
		local item = self.items[keyOf(itemKey)]
		local a = item and self:sortedAuctions(item)[index]
		if not a then
			return nil
		end
		return {
			itemKey = item.itemKey,
			owners = {},
			totalNumberOfOwners = 1,
			timeLeft = 0,
			auctionID = a.id,
			quantity = 1,
			containsOwnerItem = a.own == true,
			containsAccountItem = a.account == true,
			containsSocketedItem = false,
			buyoutAmount = a.buyout,
			minBid = a.bid,
		}
	end)
	api("HasFullItemSearchResults", function()
		return true
	end)
	api("RequestMoreItemSearchResults", function()
		return true
	end)
	api("GetNumCommoditySearchResults", function(itemID)
		local c = self.commodities[itemID]
		return c and #c.tiers or 0
	end)
	api("GetCommoditySearchResultInfo", function(itemID, index)
		local c = self.commodities[itemID]
		local t = c and c.tiers[index]
		if not t then
			return nil
		end
		return {
			itemID = itemID,
			quantity = t.quantity,
			unitPrice = t.unitPrice,
			auctionID = itemID * 100 + index,
			owners = {},
			totalNumberOfOwners = 1,
			numOwnerItems = t.own or 0,
			containsOwnerItem = (t.own or 0) > 0,
			containsAccountItem = false,
		}
	end)
	api("HasFullCommoditySearchResults", function()
		return true
	end)
	local function refuse(code)
		self.errors = self.errors + 1
		self:after(function()
			self:fire("AUCTION_HOUSE_SHOW_ERROR", code)
		end)
	end
	-- What the server sends once a bid or confirm went through.
	local function bought(...)
		local events = { ... }
		if self.strayError then
			refuse(self.strayError)
		end
		if self.buySilent then
			return
		end
		self:after(function()
			for _, event in ipairs(events) do
				self:fire(unpack(event))
			end
			self:fire("PLAYER_MONEY")
		end, self.buyAnswer)
	end
	local errors = sim.G.Enum.AuctionHouseError
	api("PlaceBid", function(auctionID, amount)
		for key, item in pairs(self.items) do
			for i, a in ipairs(item.auctions) do
				if a.id == auctionID then
					-- The server only knows auctions from the last item search.
					if self.lastSearch ~= key then
						return refuse(errors.ItemNotFound)
					elseif a.own then
						return refuse(errors.BidOwn)
					elseif not a.buyout or amount < a.buyout then
						return refuse(errors.HigherBid)
					elseif amount > self.money then
						return refuse(errors.NotEnoughMoney)
					end
					if amount % 100 ~= 0 then
						refuse(errors.DatabaseError)
					end
					table.remove(item.auctions, i)
					self.money = self.money - amount
					local events = {}
					if not self.noCompletedEvent then
						events[#events + 1] = { "AUCTION_HOUSE_PURCHASE_COMPLETED", auctionID }
					end
					if self.wonNotice then
						local won = sim.G.Enum.AuctionHouseNotification.AuctionWon
						events[#events + 1] = { "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", won, item.name, auctionID }
					end
					return bought(unpack(events))
				end
			end
		end
		refuse(errors.ItemNotFound)
	end)
	api("StartCommoditiesPurchase", function(itemID, quantity)
		local c = self.commodities[itemID]
		local total, left = 0, quantity
		for _, t in ipairs(c and c.tiers or {}) do
			local take = math.min(left, t.quantity - (t.own or 0))
			total = total + take * t.unitPrice
			left = left - take
		end
		if not c or left > 0 then
			self:after(function()
				self:fire("COMMODITY_PRICE_UNAVAILABLE")
			end)
			return
		end
		self.quote = { itemID = itemID, quantity = quantity, total = total, at = sim.time }
		self:after(function()
			self:fire("COMMODITY_PRICE_UPDATED", math.ceil(total / quantity), total)
		end)
	end)
	api("ConfirmCommoditiesPurchase", function(itemID, quantity)
		local q = self.quote
		self.quote = nil
		if q and q.spoiled then
			self:after(function()
				self:fire("AUCTION_HOUSE_SHOW_ERROR", 10)
			end)
			return
		end
		if not q or q.itemID ~= itemID or q.quantity ~= quantity or q.total > self.money then
			self:after(function()
				self:fire("COMMODITY_PURCHASE_FAILED")
			end)
			return
		end
		local left = quantity
		for _, t in ipairs(self.commodities[itemID].tiers) do
			local take = math.min(left, t.quantity - (t.own or 0))
			t.quantity = t.quantity - take
			left = left - take
		end
		self.money = self.money - q.total
		bought({ "COMMODITY_PURCHASE_SUCCEEDED" })
	end)
	api("CancelCommoditiesPurchase", function()
		self.quote = nil
	end)
	api("GetQuoteDurationRemaining", function()
		if not self.quote then
			return 0
		end
		return math.max(0, 30 - (sim.time - self.quote.at))
	end)
	return self
end

function Fake:sortedAuctions(item)
	local list = {}
	for _, a in ipairs(item.auctions) do
		list[#list + 1] = a
	end
	table.sort(list, function(a, b)
		return (a.buyout or math.huge) < (b.buyout or math.huge)
	end)
	return list
end

function Fake:browseResults()
	local out = {}
	for _, item in pairs(self.items) do
		local minPrice, own, total = nil, false, 0
		for _, a in ipairs(item.auctions) do
			total = total + 1
			own = own or a.own == true
			local price = a.buyout or a.bid
			if price and (not minPrice or price < minPrice) then
				minPrice = price
			end
		end
		out[#out + 1] =
			{ itemKey = item.itemKey, totalQuantity = total, minPrice = minPrice or 0, containsOwnerItem = own }
	end
	for _, c in pairs(self.commodities) do
		local minPrice, total = nil, 0
		for _, t in ipairs(c.tiers) do
			total = total + t.quantity
			if t.quantity > 0 and (not minPrice or t.unitPrice < minPrice) then
				minPrice = t.unitPrice
			end
		end
		out[#out + 1] =
			{ itemKey = c.itemKey, totalQuantity = total, minPrice = minPrice or 0, containsOwnerItem = false }
	end
	table.sort(out, function(a, b)
		return a.itemKey.itemID < b.itemKey.itemID
	end)
	return out
end

function Fake:after(f, delay)
	self.queue[#self.queue + 1] = { due = self.sim.time + (delay or self.latency), f = f }
end

function Fake:fire(event, ...)
	self.sim.events.fire(event, ...)
end

-- Advances the client and delivers server answers as they fall due.
function Fake:tick(seconds)
	local remaining = seconds or 0.05
	repeat
		local d = math.min(0.05, remaining)
		remaining = remaining - d
		self.sim:advance(d)
		local due, keep = {}, {}
		for _, item in ipairs(self.queue) do
			if item.due <= self.sim.time + 1e-9 then
				due[#due + 1] = item
			else
				keep[#keep + 1] = item
			end
		end
		self.queue = keep
		for _, item in ipairs(due) do
			item.f()
		end
		self.sim.events.flush()
	until remaining <= 1e-9
end

function Fake:count(name)
	local n = 0
	for _, call in ipairs(self.calls) do
		if call.name == name then
			n = n + 1
		end
	end
	return n
end

function Fake:last(name)
	for i = #self.calls, 1, -1 do
		if self.calls[i].name == name then
			return self.calls[i]
		end
	end
end

return Fake
