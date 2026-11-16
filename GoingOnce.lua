-- Going Once: a Buyout button on every row of the auction house's browse list (WoW: Forever).
--
-- Forever runs the modern auction house. A browse row only carries the item and its lowest price, and buying
-- gear needs an auction ID that only an item search returns; the server also only takes a bid on an auction
-- from the last item search sent (seen in game by auxForever). So hovering a row reads its auctions and the
-- click buys the cheapest. PlaceBid and StartCommoditiesPurchase must come from a click; trade goods also
-- need the server's quote before ConfirmCommoditiesPurchase, which does not.
--
-- A search sent while a trade good's quote is open spoils it ("Internal auction error", seen by auxForever), so
-- reads wait while a purchase is in flight.
--
-- An auction house error names no request, and Forever's server sometimes answers a buyout with "Internal auction
-- error" within 30 ms and still sells the item 2 to 3 seconds later (2 of 7 logged gear buyouts, 2026-11-15 and
-- 16, nothing else sent in between). So a purchase ends on its own answer, and on an error only when that error
-- can only be a bid's.
--
-- The buttons have a column of their own at the right. Blizzard sizes the browse table to the list's scroll box,
-- so making that box a column narrower frees the space without touching Blizzard's table; rows are followed with
-- hooksecurefunc hooks, so Blizzard's auction house code keeps running untainted. The one exception is putting
-- the scroll position back (KeepScroll).

local ADDON = ...

local HOVER_DELAY = 0.12
local OFFER_SECONDS = 30
local ANSWER_TIMEOUT = 4
-- The client may not fire the results event again for results it already holds (auxForever).
local CACHED_ANSWER_DELAY = 1
local CONFIRM_SECONDS = 8
local BOUGHT_SECONDS = 0.8
local PURCHASE_TIMEOUT = 10
-- How long a purchase still waits for its own answer after an error that may not end it. Bids were answered 2 to 3
-- seconds after they went out in game.
local ERROR_GRACE = 5
-- A purchase given up on is still reported if its answer comes within this.
local LATE_SECONDS = 60
local BUTTON_WIDTH, BUTTON_HEIGHT = 70, 18
local COLUMN_WIDTH = BUTTON_WIDTH + 8
-- Blizzard's column headers overlap by this much (AuctionHouseTableBuilder.GetBrowseListLayout).
local HEADER_OVERLAP = 2
local LABEL_MARGIN = 12
local LOG_SIZE = 200

local DEFAULTS = {
	confirmAbove = 50 * 10000,
	autoConfirm = true,
	announce = true,
}

local db
local sorts
local setUp = false
local browseList
-- The Buy column: a strip right of Blizzard's scroll box, which clips the buttons where the list scrolls.
local column
local settingsCategory

-- Offers are what a read found: the cheapest gear auction, or a trade good's price tiers.
local offers = {}
local commodityOffers = {}
-- Key of the last item or trade good search anyone sent; purchases go through it.
local lastSearch
local queued
local hovered
local hoverTimer
-- The one purchase in flight: { kind = "item" | "commodity", state = "quoting" | "quoted" | "buying", ... }.
local purchase
-- The last purchase given up on while buying, until LATE_SECONDS: its answer may still come.
local late
-- Gear waiting for a second click: { key, auctionID, untilTime }.
local confirming
local bought = {}
-- Set when a new browse search starts, so its results may scroll the list to the top.
local freshBrowse = false
-- The list's scroll position as of the last frame, before any refresh in this one.
local committedOffset = 0
local amountBox

-- One per row of Blizzard's browse list: its Buy button in the column, and the row's data.
local Slot = {}
Slot.__index = Slot
local slots = setmetatable({}, { __mode = "k" })

local Read, Refresh, RefreshAll

local function Now()
	return GetTime()
end

local function KeyOf(itemKey)
	return string.format(
		"%d:%d:%d:%d",
		itemKey.itemID,
		itemKey.itemLevel or 0,
		itemKey.itemSuffix or 0,
		itemKey.battlePetSpeciesID or 0
	)
end

local function CopyKey(itemKey)
	return {
		itemID = itemKey.itemID,
		itemLevel = itemKey.itemLevel or 0,
		itemSuffix = itemKey.itemSuffix or 0,
		battlePetSpeciesID = itemKey.battlePetSpeciesID or 0,
	}
end

local function Money(amount)
	return GetMoneyString(amount, true)
end

local function Green(text)
	return GREEN_FONT_COLOR:WrapTextInColorCode(text)
end

local function Orange(text)
	return ORANGE_FONT_COLOR:WrapTextInColorCode(text)
end

local function Red(text)
	return RED_FONT_COLOR:WrapTextInColorCode(text)
end

local function Print(text)
	DEFAULT_CHAT_FRAME:AddMessage(NORMAL_FONT_COLOR:WrapTextInColorCode("Going Once: ") .. text)
end

-- What the addon asked for and what the auction house answered, kept in the saved variables so a purchase
-- that went wrong can be read back after a /reload.
local function Log(...)
	if not db then
		return
	end
	local parts = { date("%H:%M:%S"), string.format("%.2f", GetTime()) }
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring((select(i, ...)))
	end
	local log = db.log
	log[#log + 1] = table.concat(parts, " ")
	while #log > LOG_SIZE do
		table.remove(log, 1)
	end
end

local function Amount(itemID)
	return db.amounts[itemID] or 1
end

local function Expensive(amount)
	return db.confirmAbove > 0 and amount >= db.confirmAbove
end

local function ItemText(itemKey, link)
	if link then
		return link
	end
	local _, itemLink = C_Item.GetItemInfo(itemKey.itemID)
	if itemLink then
		return itemLink
	end
	local info = C_AuctionHouse.GetItemKeyInfo(itemKey)
	return info and info.itemName or ("item " .. itemKey.itemID)
end

local function ErrorText(code)
	local text = AuctionHouseUtil and AuctionHouseUtil.GetErrorText and AuctionHouseUtil.GetErrorText(code)
	return (text and text ~= "") and text or ("error " .. tostring(code))
end

---------------------------------------------------------------------------------------------------------------
-- Offers
---------------------------------------------------------------------------------------------------------------

local function Offer(itemKey, commodity)
	local key = KeyOf(itemKey)
	local offer = offers[key]
	if not offer then
		offer = { key = key, itemKey = CopyKey(itemKey) }
		offers[key] = offer
	end
	if commodity ~= nil and offer.commodity ~= commodity then
		offer.commodity = commodity
		if commodity then
			commodityOffers[itemKey.itemID] = offer
		end
	end
	return offer
end

local function Waiting(offer)
	return offer.state == "loading" and Now() - offer.sentAt < ANSWER_TIMEOUT
end

-- An answer still worth showing: recent, and from the last search sent. Gear can only be bid on from that
-- search, and a trade good's quote from an older read failed for auxForever.
local function Known(offer)
	if offer.state ~= "ready" and offer.state ~= "none" then
		return false
	end
	if Now() - offer.readyAt >= OFFER_SECONDS then
		return false
	end
	return lastSearch == offer.key
end

local function Usable(offer)
	return Known(offer) and offer.state == "ready" and (offer.commodity or offer.auctionID ~= nil)
end

local function Forget(offer)
	offer.state = nil
	offer.auctionID = nil
	offer.price = nil
end

-- Reads go out only from the visible list, and never while a quote is open: Blizzard's buy dialog holds one
-- whenever it shows.
local function ListReady()
	if not browseList or not browseList:IsVisible() then
		return false
	end
	local dialog = AuctionHouseFrame.BuyDialog
	return not (dialog and dialog:IsShown())
end

local function Send(offer)
	if queued and queued ~= offer and queued.state == "loading" then
		Forget(queued)
		Refresh(queued)
	end
	offer.state = "loading"
	offer.sentAt = Now()
	offer.askedMore = nil
	if purchase then
		queued = offer
		Log("hold", offer.key)
		Refresh(offer)
		return
	end
	if not ListReady() then
		queued = nil
		Forget(offer)
		Refresh(offer)
		return
	end
	if not C_AuctionHouse.IsThrottledMessageSystemReady() then
		queued = offer
		Log("throttled", offer.key)
		Refresh(offer)
		return
	end
	queued = nil
	local sentAt = offer.sentAt
	C_AuctionHouse.SendSearchQuery(offer.itemKey, sorts, true)
	C_Timer.After(CACHED_ANSWER_DELAY, function()
		if offer.state == "loading" and offer.sentAt == sentAt and C_AuctionHouse.HasSearchResults(offer.itemKey) then
			Read(offer)
		end
	end)
	C_Timer.After(ANSWER_TIMEOUT, function()
		if offer.state == "loading" and offer.sentAt == sentAt then
			Refresh(offer)
		end
	end)
	Refresh(offer)
end

local function ReadItem(offer)
	local itemKey = offer.itemKey
	local best, own, bidsOnly
	for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) do
		local result = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
		if result then
			if result.containsOwnerItem or result.containsAccountItem then
				own = true
			elseif not result.buyoutAmount or result.buyoutAmount == 0 then
				bidsOnly = true
			elseif not best or result.buyoutAmount < best.buyoutAmount then
				best = result
			end
		end
	end
	if not best and not offer.askedMore and not purchase and not C_AuctionHouse.HasFullItemSearchResults(itemKey) then
		offer.askedMore = true
		C_AuctionHouse.RequestMoreItemSearchResults(itemKey)
		return
	end
	offer.readyAt = Now()
	if best then
		offer.state = "ready"
		offer.auctionID = best.auctionID
		offer.price = best.buyoutAmount
		offer.link = best.itemLink
		offer.reason = nil
		Log("read", offer.key, "auction", best.auctionID, "buyout", best.buyoutAmount)
	else
		offer.state = "none"
		offer.auctionID = nil
		offer.price = nil
		offer.reason = own and "own" or bidsOnly and "bids" or "gone"
		Log("read", offer.key, "none", offer.reason)
	end
	Refresh(offer)
end

local function ReadCommodity(offer)
	local itemID = offer.itemKey.itemID
	local tiers, available, own = {}, 0, false
	for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
		local result = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
		if result then
			-- The game skips your own units when it sells, cheapest first.
			local quantity = result.quantity - (result.numOwnerItems or 0)
			if quantity > 0 then
				tiers[#tiers + 1] = { unitPrice = result.unitPrice, quantity = quantity }
				available = available + quantity
			end
			own = own or result.containsOwnerItem
		end
	end
	offer.tiers = tiers
	offer.available = available
	offer.full = C_AuctionHouse.HasFullCommoditySearchResults(itemID)
	offer.readyAt = Now()
	if available > 0 or not offer.full then
		offer.state = "ready"
		offer.reason = nil
	else
		offer.state = "none"
		offer.reason = own and "own" or "gone"
	end
	Log("read", offer.key, "tiers", #tiers, "cheapest", tiers[1] and tiers[1].unitPrice, "available", available)
	Refresh(offer)
end

function Read(offer)
	if offer.commodity then
		ReadCommodity(offer)
	else
		ReadItem(offer)
	end
end

-- Total for the cheapest `quantity` units read so far, and whether the read held that many.
local function Estimate(offer, quantity)
	local total, left = 0, quantity
	for _, tier in ipairs(offer.tiers or {}) do
		local take = math.min(left, tier.quantity)
		total = total + take * tier.unitPrice
		left = left - take
		if left == 0 then
			return total, true
		end
	end
	return total, false
end

---------------------------------------------------------------------------------------------------------------
-- Hover
---------------------------------------------------------------------------------------------------------------

local function Want(slot)
	local row = slot.rowData
	if not row or row.totalQuantity == 0 then
		return
	end
	local info = C_AuctionHouse.GetItemKeyInfo(row.itemKey)
	if not info then
		return
	end
	local offer = Offer(row.itemKey, info.isCommodity)
	if Waiting(offer) or Known(offer) then
		return
	end
	if purchase and purchase.key == offer.key then
		return
	end
	Send(offer)
end

local function Hover(slot, delay)
	hovered = slot
	if hoverTimer then
		hoverTimer:Cancel()
		hoverTimer = nil
	end
	if delay <= 0 then
		Want(slot)
		return
	end
	hoverTimer = C_Timer.NewTimer(delay, function()
		hoverTimer = nil
		if hovered == slot and slot.button:IsVisible() then
			Want(slot)
		end
	end)
end

local function Unhover(slot)
	if hovered == slot then
		hovered = nil
		if hoverTimer then
			hoverTimer:Cancel()
			hoverTimer = nil
		end
	end
end

---------------------------------------------------------------------------------------------------------------
-- Purchases
---------------------------------------------------------------------------------------------------------------

local function Finish(p)
	if purchase == p then
		purchase = nil
	end
	if p.ticker then
		p.ticker:Cancel()
		p.ticker = nil
	end
	Forget(p.offer)
	-- A read held back during the purchase goes out now.
	local waiting = queued
	if not purchase and waiting and waiting.state == "loading" then
		queued = nil
		Send(waiting)
	end
end

-- afterAll: the purchase was given up on and a chat line said so, so this one is always shown.
local function Announce(p, afterAll)
	if not db.announce and not afterAll then
		return
	end
	local item = ItemText(p.offer.itemKey, p.offer.link)
	local text
	if p.kind == "item" then
		text = string.format("bought %s for %s", item, Money(p.price))
	else
		text = string.format("bought %d %s for %s (%s each)", p.quantity, item, Money(p.totalPrice), Money(p.unitPrice))
	end
	text = text .. (afterAll and " after all." or ".")
	-- Blizzard flashed the server's error during this purchase, which reads as if it failed.
	if p.errorCode then
		text = text .. ' The "' .. (ErrorText(p.errorCode):gsub("%.$", "")) .. '" message did not stop it.'
	end
	Print(text)
end

local function Succeed(p)
	Log("bought", p.key)
	Finish(p)
	Announce(p)
	if p.kind == "commodity" and p.quantity == 1 and db.announce and not db.amountTip then
		db.amountTip = true
		Print("to buy more than one, right-click or Shift-click a trade good's Buy button.")
	end
	local at = Now()
	bought[p.key] = at
	PlaySound(SOUNDKIT.LOOT_WINDOW_COIN_SOUND)
	Refresh(p.offer)
	-- The next cheapest is read during the flash, so a second buy is ready when it ends.
	if hovered and hovered.key == p.key and hovered.button:IsVisible() then
		Want(hovered)
	end
	C_Timer.After(BOUGHT_SECONDS, function()
		if bought[p.key] == at then
			bought[p.key] = nil
		end
		Refresh(p.offer)
	end)
end

local function Fail(p, message)
	Log("failed", p.key, message)
	Finish(p)
	if message then
		Print(message)
	end
	Refresh(p.offer)
	if hovered and hovered.key == p.key and hovered.button:IsVisible() then
		Want(hovered)
	end
end

local function Refused(p, code)
	if p.kind == "commodity" then
		C_AuctionHouse.CancelCommoditiesPurchase()
	end
	Fail(p, "the auction house refused that purchase (" .. ErrorText(code) .. "). Nothing was bought.")
end

-- No answer of its own came in time. A quote never buys anything, but a bid or confirm that went out still may.
local function GiveUp(p)
	if p.state ~= "buying" then
		if p.errorCode then
			Refused(p, p.errorCode)
		else
			if p.kind == "commodity" then
				C_AuctionHouse.CancelCommoditiesPurchase()
			end
			Fail(p, "no price came back from the auction house. Nothing was bought.")
		end
		return
	end
	if p.kind == "commodity" then
		C_AuctionHouse.CancelCommoditiesPurchase()
	end
	late = p
	p.lateUntil = Now() + LATE_SECONDS
	if p.errorCode then
		Fail(
			p,
			"the auction house answered with an error ("
				.. ErrorText(p.errorCode)
				.. ") and has not said whether the purchase went through. Check your mail before buying again."
		)
	else
		Fail(p, "no answer from the auction house. It may still go through: check your mail before buying again.")
	end
end

-- Gives up on the purchase if its answer has not come `seconds` from now; a later call moves the deadline.
local function Timeout(p, seconds)
	local deadline = Now() + seconds
	p.deadline = deadline
	C_Timer.After(seconds, function()
		if purchase == p and p.state ~= "quoted" and p.deadline == deadline then
			GiveUp(p)
		end
	end)
end

local function BoughtAfterAll()
	local p = late
	late = nil
	Log("bought after all", p.key)
	Announce(p, true)
end

-- Whether the given-up purchase is still waiting for an answer of this kind.
local function Late(kind)
	return late and late.kind == kind and Now() < late.lateUntil
end

-- A quote the player has not confirmed is given back when it runs out.
local function WatchQuote(p)
	if p.ticker then
		return
	end
	p.ticker = C_Timer.NewTicker(0.5, function()
		if purchase ~= p or p.state ~= "quoted" then
			if p.ticker then
				p.ticker:Cancel()
				p.ticker = nil
			end
			return
		end
		if C_AuctionHouse.GetQuoteDurationRemaining() <= 0 then
			Log("quote ran out", p.key)
			C_AuctionHouse.CancelCommoditiesPurchase()
			Finish(p)
			Refresh(p.offer)
		end
	end)
end

local function GiveBackQuote()
	local p = purchase
	if p and p.kind == "commodity" and p.state == "quoted" then
		Log("quote given back", p.key)
		C_AuctionHouse.CancelCommoditiesPurchase()
		Finish(p)
		Refresh(p.offer)
	end
end

local function OfferQuoteForClick(p)
	p.state = "quoted"
	p.auto = nil
	WatchQuote(p)
	Refresh(p.offer)
end

local function Confirm(p)
	p.state = "buying"
	p.confirmWhenReady = nil
	p.errorCode = nil
	Log("confirm", p.itemID, "x" .. p.quantity, "total", p.totalPrice, p.auto and "auto" or "click")
	C_AuctionHouse.ConfirmCommoditiesPurchase(p.itemID, p.quantity)
	Timeout(p, PURCHASE_TIMEOUT)
	Refresh(p.offer)
end

local function BuyItem(slot)
	local offer = Offer(slot.rowData.itemKey, false)
	if not Usable(offer) then
		if not Waiting(offer) then
			Send(offer)
		end
		return
	end
	if offer.price > GetMoney() then
		return
	end
	local wantsConfirm = offer.price > slot.rowData.minPrice or Expensive(offer.price)
	local confirmed = confirming
		and confirming.key == offer.key
		and confirming.auctionID == offer.auctionID
		and Now() < confirming.untilTime
	if wantsConfirm and not confirmed then
		local mine = { key = offer.key, auctionID = offer.auctionID, untilTime = Now() + CONFIRM_SECONDS }
		confirming = mine
		C_Timer.After(CONFIRM_SECONDS, function()
			if confirming == mine then
				confirming = nil
				Refresh(offer)
			end
		end)
		Refresh(offer)
		return
	end
	confirming = nil
	local p = {
		kind = "item",
		key = offer.key,
		offer = offer,
		auctionID = offer.auctionID,
		price = offer.price,
		state = "buying",
	}
	purchase = p
	Log("bid", p.key, "auction", p.auctionID, "buyout", p.price, "last search", lastSearch)
	C_AuctionHouse.PlaceBid(p.auctionID, p.price)
	Timeout(p, PURCHASE_TIMEOUT)
	Refresh(offer)
end

local function BuyCommodity(slot)
	local row = slot.rowData
	local offer = Offer(row.itemKey, true)
	local itemID = row.itemKey.itemID
	local p = purchase
	if p and p.key == offer.key then
		if p.state == "quoted" then
			Confirm(p)
		end
		return
	end
	if not Usable(offer) then
		if not Waiting(offer) then
			Send(offer)
		end
		return
	end
	local quantity = Amount(itemID)
	if row.minPrice * quantity > GetMoney() then
		return
	end
	p = {
		kind = "commodity",
		key = offer.key,
		offer = offer,
		itemID = itemID,
		quantity = quantity,
		expectUnit = row.minPrice,
		state = "quoting",
	}
	purchase = p
	Log("quote asked", itemID, "x" .. quantity, "list", row.minPrice, "last search", lastSearch)
	C_AuctionHouse.StartCommoditiesPurchase(itemID, quantity)
	Timeout(p, PURCHASE_TIMEOUT)
	Refresh(offer)
end

---------------------------------------------------------------------------------------------------------------
-- Amount box (right-click on a trade good's button)
---------------------------------------------------------------------------------------------------------------

local function CloseAmountBox()
	if not amountBox or not amountBox:IsShown() then
		return
	end
	local slot = amountBox.slot
	amountBox.slot = nil
	amountBox:Hide()
	if GameTooltip:IsOwned(amountBox) then
		GameTooltip_Hide()
	end
	RefreshAll()
	if slot and slot.button:IsVisible() and slot.button:IsMouseOver() then
		slot:ShowTooltip()
	end
end

local function AskAmount(slot)
	if not amountBox then
		amountBox = CreateFrame("EditBox", nil, UIParent, "InputBoxTemplate")
		amountBox:SetSize(46, 20)
		amountBox:SetNumeric(true)
		amountBox:SetMaxLetters(5)
		amountBox:SetAutoFocus(false)
		amountBox:SetFrameStrata("DIALOG")
		amountBox:SetJustifyH("CENTER")
		amountBox:SetScript("OnEnterPressed", function(self)
			local amount = tonumber(self:GetText())
			if amount and amount > 0 then
				db.amounts[self.itemID] = amount > 1 and amount or nil
			end
			self:ClearFocus()
			CloseAmountBox()
		end)
		amountBox:SetScript("OnEscapePressed", function(self)
			self:ClearFocus()
			CloseAmountBox()
		end)
		amountBox:SetScript("OnEditFocusLost", CloseAmountBox)
	end
	amountBox.slot = slot
	amountBox.itemID = slot.rowData.itemKey.itemID
	amountBox:ClearAllPoints()
	amountBox:SetPoint("RIGHT", slot.button, "LEFT", -6, 0)
	amountBox:SetText(tostring(Amount(amountBox.itemID)))
	amountBox:Show()
	amountBox:SetFocus()
	amountBox:HighlightText()
	GameTooltip:SetOwner(amountBox, "ANCHOR_TOP")
	GameTooltip_SetTitle(GameTooltip, "How many to buy")
	GameTooltip_AddNormalLine(GameTooltip, "Type an amount and press Enter. It is kept for this item.", true)
	GameTooltip:Show()
end

---------------------------------------------------------------------------------------------------------------
-- Slots
---------------------------------------------------------------------------------------------------------------

local function SlotFor(row)
	local slot = slots[row]
	if slot then
		return slot
	end
	slot = setmetatable({ row = row }, Slot)
	local button = CreateFrame("Button", nil, column, "UIPanelButtonTemplate")
	button:SetSize(BUTTON_WIDTH, BUTTON_HEIGHT)
	-- Rows span the scroll box, so their right edge is the column's left one.
	button:SetPoint("LEFT", row, "RIGHT", (COLUMN_WIDTH - BUTTON_WIDTH) / 2, 0)
	button:SetNormalFontObject(GameFontNormalSmall)
	button:SetHighlightFontObject(GameFontHighlightSmall)
	button:SetDisabledFontObject(GameFontDisableSmall)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:SetMotionScriptsWhileDisabled(true)
	button:SetScript("OnClick", function(_, mouseButton)
		slot:OnClick(mouseButton)
	end)
	button:SetScript("OnEnter", function()
		slot:OnEnter()
	end)
	button:SetScript("OnLeave", function()
		slot:OnLeave()
	end)
	button:SetScript("OnHide", function()
		Unhover(slot)
	end)
	slot.button = button
	slots[row] = slot
	return slot
end

function Slot:Populate(rowData)
	self.rowData = rowData
	self.key = KeyOf(rowData.itemKey)
	self.button:Show()
	self:Update()
end

-- The row went back to Blizzard's pool.
function Slot:Clear()
	self.rowData = nil
	self.key = nil
	self.button:Hide()
end

function Slot:OnEnter()
	local row = self.row
	if row.HighlightTexture then
		row.HighlightTexture:Show()
	end
	Hover(self, 0)
	self:ShowTooltip()
end

function Slot:OnLeave()
	local row = self.row
	if row.HighlightTexture and not row:IsMouseOver() then
		row.HighlightTexture:Hide()
	end
	Unhover(self)
	GameTooltip_Hide()
end

function Slot:OnClick(mouseButton)
	local row = self.rowData
	local info = row and C_AuctionHouse.GetItemKeyInfo(row.itemKey)
	if not info or row.totalQuantity == 0 then
		return
	end
	-- Shift-click picks an amount at a vendor too.
	if mouseButton == "RightButton" or IsShiftKeyDown() then
		if info.isCommodity then
			AskAmount(self)
		end
		return
	end
	if purchase and purchase.key ~= self.key then
		if purchase.state ~= "quoted" then
			return
		end
		GiveBackQuote()
	elseif purchase and purchase.kind == "item" then
		return
	end
	if info.isCommodity then
		BuyCommodity(self)
	else
		BuyItem(self)
	end
end

-- Shows `text` on the button, or `fallback` when it would not fit (a price is never cut short).
function Slot:SetLabel(text, fallback)
	local button = self.button
	button:SetText(text)
	if fallback and button:GetFontString():GetStringWidth() > button:GetWidth() - LABEL_MARGIN then
		button:SetText(fallback)
	end
end

-- The button's text, whether it can be clicked, the tooltip lines that explain it, and a shorter text for when
-- the first does not fit.
function Slot:State()
	local row = self.rowData
	if row.totalQuantity == 0 then
		return "Buy", false, { "None for sale." }
	end
	local info = C_AuctionHouse.GetItemKeyInfo(row.itemKey)
	if not info then
		return "Buy", false, { "Loading the item..." }
	end
	local offer = offers[self.key]
	local p = purchase and purchase.key == self.key and purchase or nil
	local money = GetMoney()

	if bought[self.key] then
		return Green("Bought"), false, { "Bought." }
	end

	if info.isCommodity then
		local amount = Amount(row.itemKey.itemID)
		if p and p.state == "quoted" then
			local each = Money(p.unitPrice) .. " each"
			local lines = { string.format("%d for %s (%s).", p.quantity, Money(p.totalPrice), each) }
			if p.unitPrice > p.expectUnit then
				lines[#lines + 1] = Orange("More than the list shows (" .. Money(p.expectUnit) .. " each).")
			end
			if p.totalPrice > money then
				lines[#lines + 1] = Red("You don't have enough gold.")
				return Green(Money(p.totalPrice)), false, lines, "Confirm"
			end
			lines[#lines + 1] = Green("Click to buy at this price.")
			return Green(Money(p.totalPrice)), true, lines, Green("Confirm")
		elseif p then
			return "...", false, { "Asking the auction house for the price..." }
		end
		if offer and Waiting(offer) then
			return "...", false, { "Reading the auctions..." }
		end
		local label = amount > 1 and ("Buy " .. amount) or "Buy"
		local lines = {
			amount > 1 and string.format("Buys %d, cheapest first.", amount) or "Buys one.",
			HIGHLIGHT_FONT_COLOR:WrapTextInColorCode("Right-click or Shift-click to choose how many."),
		}
		local cost = row.minPrice * amount
		if offer and Usable(offer) then
			local total, enough = Estimate(offer, amount)
			if enough then
				cost = total
				lines[#lines + 1] = "About " .. Money(total) .. "."
			elseif offer.full then
				lines[#lines + 1] = Orange(string.format("Only %d for sale.", offer.available))
			end
		elseif offer and Known(offer) and offer.state == "none" then
			return label, false, { offer.reason == "own" and "Only your own are for sale." or "None for sale." }
		else
			lines[#lines + 1] = "Click to check the price first."
		end
		if cost > money then
			lines[#lines + 1] = Red("You don't have enough gold.")
			return label, false, lines
		end
		if db.autoConfirm then
			lines[#lines + 1] = "One click buys when the price matches the list. If it costs more, you confirm."
		else
			lines[#lines + 1] = "The next click confirms the price."
		end
		return label, true, lines
	end

	if p then
		return "...", false, { "Buying..." }
	end
	if offer and Waiting(offer) then
		return "...", false, { "Reading the auctions..." }
	end
	if offer and Usable(offer) then
		local price = offer.price
		local lines = { "Cheapest: " .. Money(price) .. "." }
		if price > money then
			lines[#lines + 1] = Red("You don't have enough gold.")
			return "Buy", false, lines
		end
		if confirming and confirming.key == self.key and confirming.auctionID == offer.auctionID then
			lines[#lines + 1] = Orange("Click again to buy for " .. Money(price) .. ".")
			return Orange(Money(price)), true, lines, Orange("Confirm")
		end
		if price > row.minPrice then
			lines[#lines + 1] = Orange("More than the list shows: the cheaper ones are gone.")
			lines[#lines + 1] = "Click twice to buy."
			return Orange("Buy"), true, lines
		end
		if Expensive(price) then
			lines[#lines + 1] = "Click twice to buy (" .. Money(db.confirmAbove) .. " or more)."
			return "Buy", true, lines
		end
		lines[#lines + 1] = Green("Click to buy.")
		return "Buy", true, lines
	end
	if offer and Known(offer) and offer.state == "none" then
		local reason = offer.reason == "own" and "Only your own auctions are left."
			or offer.reason == "bids" and "These auctions only take bids."
			or "Nothing left to buy."
		return "Buy", false, { reason }
	end
	if row.minPrice > money then
		return "Buy", false, { Red("You don't have enough gold.") }
	end
	return "Buy", true, { "Click to find the cheapest." }
end

function Slot:Update()
	if not self.rowData or not db then
		return
	end
	local text, enabled, _, fallback = self:State()
	self:SetLabel(text, fallback)
	self.button:SetEnabled(enabled)
	if GameTooltip:IsOwned(self.button) then
		self:ShowTooltip()
	end
end

function Slot:ShowTooltip()
	if not self.rowData then
		return
	end
	local _, _, lines = self:State()
	GameTooltip:SetOwner(self.button, "ANCHOR_RIGHT")
	GameTooltip_SetTitle(GameTooltip, "Buy now")
	for _, line in ipairs(lines) do
		GameTooltip_AddNormalLine(GameTooltip, line, true)
	end
	GameTooltip:AddLine("Settings: /goingonce", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

function Refresh(offer)
	for _, slot in pairs(slots) do
		if slot.key == offer.key and slot.button:IsVisible() then
			slot:Update()
		end
	end
end

function RefreshAll()
	for _, slot in pairs(slots) do
		if slot.rowData and slot.button:IsVisible() then
			slot:Update()
		end
	end
end

---------------------------------------------------------------------------------------------------------------
-- Set-up on Blizzard's auction house
---------------------------------------------------------------------------------------------------------------

local function OnItemSearch(itemKey)
	lastSearch = itemKey and KeyOf(itemKey) or nil
	Log("search", lastSearch)
	RefreshAll()
end

local function OnBrowseSearch()
	lastSearch = nil
	freshBrowse = true
	Log("browse search")
end

local function Hook(name, f)
	if C_AuctionHouse[name] then
		hooksecurefunc(C_AuctionHouse, name, f)
	end
end

-- Requests to the server besides the searches hooked above.
local REQUESTS = {
	"PlaceBid",
	"StartCommoditiesPurchase",
	"ConfirmCommoditiesPurchase",
	"CancelCommoditiesPurchase",
	"RequestMoreBrowseResults",
	"RequestMoreItemSearchResults",
	"RequestMoreCommoditySearchResults",
	"SearchForItemKeys",
	"ReplicateItems",
	"QueryOwnedAuctions",
	"QueryBids",
	"RequestOwnedAuctionBidderInfo",
	"PostItem",
	"PostCommodity",
	"ConfirmPostItem",
	"ConfirmPostCommodity",
	"CancelAuction",
	"CancelSell",
	"SetFavoriteItem",
}

local function Brief(...)
	local parts = {}
	for i = 1, select("#", ...) do
		local value = select(i, ...)
		if type(value) == "table" then
			parts[#parts + 1] = value.itemID and KeyOf(value) or "{}"
		else
			parts[#parts + 1] = tostring(value)
		end
	end
	return table.concat(parts, " ")
end

-- An item search makes the server refresh the browse results (to update that item's price; Auctionator notes
-- this too), and Blizzard answers any refresh by scrolling the list to the top. Only a new browse search should.
-- Scrolling back re-lays the visible rows from this addon's code: the one place Blizzard's list runs tainted.
local function KeepScroll(list)
	if freshBrowse then
		freshBrowse = false
		committedOffset = 0
		return
	end
	if committedOffset > 0 and list.isInitialized then
		list.ScrollBox:ScrollToOffset(committedOffset, true)
	end
end

-- Blizzard's table builder for the list, made on the list's first show (ItemList:Init). Rows come and go through
-- it: AddRow and Arrange both end in ArrangeCells, a released row in RemoveRow.
local function FollowRows(builder)
	hooksecurefunc(builder, "ArrangeCells", function(_, row)
		local rowData = row.rowData
		if rowData and rowData.itemKey and rowData.minPrice then
			SlotFor(row):Populate(rowData)
		end
	end)
	hooksecurefunc(builder, "RemoveRow", function(_, row)
		local slot = slots[row]
		if slot then
			slot:Clear()
		end
	end)
end

-- The Buy column. UpdateTableBuilderLayout sizes the table to ScrollBox:GetWidth(), so a scroll box one column
-- narrower makes Blizzard lay out a narrower table itself; writing into its table builder instead (the first
-- version's extra column) tainted every browse update.
-- Moves the frame's anchors that `pick` chooses sideways, keeping the others. Read first: setting an anchor can
-- move it in the frame's list of anchors.
local function Nudge(frame, dx, pick)
	local anchors = {}
	for i = 1, frame:GetNumPoints() do
		anchors[i] = { frame:GetPoint(i) }
	end
	for _, a in ipairs(anchors) do
		if pick(a[1], a[2]) then
			frame:SetPoint(a[1], a[2], a[3], a[4] + dx, a[5])
		end
	end
end

local function MakeColumn(list)
	local box, bar, headers = list.ScrollBox, list.ScrollBar, list.HeaderContainer
	Nudge(box, -COLUMN_WIDTH, function(point)
		return point:find("RIGHT", 1, true) ~= nil
	end)
	-- The scroll bar hangs off the scroll box's right edge; it stays where it was.
	Nudge(bar, COLUMN_WIDTH, function(_, relativeTo)
		return relativeTo == box
	end)
	-- So the mouse wheel over the column scrolls the list, in Blizzard's own handler.
	box:SetHitRectInsets(0, -COLUMN_WIDTH, 0, 0)

	column = CreateFrame("Frame", "GoingOnceColumn", list)
	column:SetPoint("TOPLEFT", box, "TOPRIGHT")
	column:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", COLUMN_WIDTH, 0)
	column:SetClipsChildren(true)

	local header = CreateFrame("Button", nil, headers, "AuctionHouseTableHeaderStringTemplate")
	header:Init({}, "Buy")
	header:SetPoint("TOPRIGHT")
	header:SetPoint("BOTTOMRIGHT")
	header:SetWidth(COLUMN_WIDTH + HEADER_OVERLAP)
end

local function SetUp()
	if setUp then
		return
	end
	setUp = true
	sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
	local browse = AuctionHouseFrame.BrowseResultsFrame
	browseList = browse.ItemList

	MakeColumn(browseList)
	if browseList.tableBuilder then
		FollowRows(browseList.tableBuilder)
	else
		local following = false
		hooksecurefunc(browseList, "Init", function(list)
			if not following and list.tableBuilder then
				following = true
				FollowRows(list.tableBuilder)
			end
		end)
	end

	-- Only the browse list uses this cell (AuctionHouseTableBuilder.GetBrowseListLayout); its cells are made when
	-- rows first show, after this, so each one copies the hooked methods. The cell's row is its parent.
	local cellMixin = AuctionHouseTableCellItemDisplayMixin
	-- Runs when the item's info arrives after the row was drawn.
	hooksecurefunc(cellMixin, "UpdateDisplay", function(cell)
		local slot = slots[cell:GetParent()]
		if slot and slot.rowData then
			slot:Update()
			if hovered == slot then
				Want(slot)
			end
		end
	end)
	hooksecurefunc(cellMixin, "OnLineEnter", function(cell)
		local slot = slots[cell:GetParent()]
		if slot and slot.rowData then
			Hover(slot, HOVER_DELAY)
		end
	end)
	hooksecurefunc(cellMixin, "OnLineLeave", function(cell)
		local slot = slots[cell:GetParent()]
		if slot then
			Unhover(slot)
		end
	end)

	hooksecurefunc(browseList, "Reset", KeepScroll)
	local watch = CreateFrame("Frame", nil, browse)
	watch:SetScript("OnUpdate", function()
		if browseList.isInitialized then
			committedOffset = browseList.ScrollBox:GetDerivedScrollOffset()
		end
	end)

	Hook("SendSearchQuery", OnItemSearch)
	Hook("SendSellSearchQuery", OnItemSearch)
	Hook("RefreshItemSearchResults", OnItemSearch)
	Hook("RefreshCommoditySearchResults", function(itemID)
		OnItemSearch({ itemID = itemID })
	end)
	Hook("SendBrowseQuery", OnBrowseSearch)
	Hook("SearchForFavorites", OnBrowseSearch)
	Hook("ReplicateItems", function()
		lastSearch = nil
	end)
	-- The other requests, from any addon or Blizzard, so the log shows what an error may have answered.
	for _, name in ipairs(REQUESTS) do
		Hook(name, function(...)
			Log("sent", name, Brief(...))
		end)
	end
end

local function Reset()
	if purchase then
		if purchase.kind == "commodity" then
			C_AuctionHouse.CancelCommoditiesPurchase()
		end
		Finish(purchase)
	end
	purchase = nil
	confirming = nil
	queued = nil
	hovered = nil
	lastSearch = nil
	committedOffset = 0
	wipe(offers)
	wipe(commodityOffers)
	wipe(bought)
	if amountBox then
		amountBox:Hide()
	end
end

---------------------------------------------------------------------------------------------------------------
-- Settings: Options > AddOns > Going Once
---------------------------------------------------------------------------------------------------------------

-- Blizzard's rows put their control 80 left of the row's centre (SettingsCheckboxControlMixin); these rows line up
-- with that.
local CONTROL_X = -80
-- MoneyInputFrameTemplate: its three boxes and the gaps between them, and the left border its gold box draws 5
-- outside itself (MoneyFrameEditBoxTemplate).
local MONEY_WIDTH = 70 + 10 + 48 + 10 + 48
local MONEY_BORDER = 5

-- A settings row for an amount of money: the game's gold, silver and copper boxes where a slider would be. Its
-- template is in GoingOnce.xml (only XML makes templates); Blizzard's settings list runs each row's code in
-- securecallfunction, so this row cannot taint the rest of the panel.
GoingOnceMoneyControlMixin = CreateFromMixins(SettingsControlMixin)

local moneyInputs = 0

function GoingOnceMoneyControlMixin:OnLoad()
	SettingsControlMixin.OnLoad(self)
	-- Blizzard's money input names its boxes after itself ($parentGold), so each copy needs a name of its own.
	moneyInputs = moneyInputs + 1
	local input = CreateFrame("Frame", "GoingOnceMoneyInput" .. moneyInputs, self, "MoneyInputFrameTemplate")
	input:SetPoint("LEFT", self, "CENTER", CONTROL_X + MONEY_BORDER, 0)
	MoneyInputFrame_SetOnValueChangedFunc(input, function()
		self:OnMoneyChanged()
	end)
	self.Input = input
	local hint = self:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("LEFT", input, "RIGHT", 10, 0)
	self.Hint = hint
end

function GoingOnceMoneyControlMixin:Init(initializer)
	SettingsControlMixin.Init(self, initializer)
	self:SetValue(self:GetSetting():GetValue())
end

function GoingOnceMoneyControlMixin:SetValue(value)
	local input = self.Input
	if MoneyInputFrame_GetCopper(input) ~= value then
		-- Not MoneyInputFrame_SetCopper: it counts the text-change events it expects to come after it returns, and
		-- miscounts where they fire inside SetText (forever_sim).
		local gold = math.floor(value / COPPER_PER_GOLD)
		local silver = math.floor(value % COPPER_PER_GOLD / COPPER_PER_SILVER)
		local copper = value % COPPER_PER_SILVER
		self.updating = true
		input.gold:SetText(gold > 0 and tostring(gold) or "")
		input.silver:SetText(silver > 0 and tostring(silver) or "")
		input.copper:SetText(copper > 0 and tostring(copper) or "")
		self.updating = nil
	end
	self.Hint:SetText(value == 0 and (self.data.options.zeroText or "") or "")
end

function GoingOnceMoneyControlMixin:OnMoneyChanged()
	if not self.data or self.updating then
		return
	end
	local copper = MoneyInputFrame_GetCopper(self.Input)
	local setting = self:GetSetting()
	if setting:GetValue() ~= copper then
		setting:SetValue(copper)
	end
end

-- A settings row with a button, lined up with the other rows' controls and as wide as the money boxes: Blizzard's
-- own button row (CreateSettingsButtonInitializer) starts its button 40 further right.
GoingOnceButtonControlMixin = CreateFromMixins(SettingsListElementMixin)

function GoingOnceButtonControlMixin:OnLoad()
	SettingsListElementMixin.OnLoad(self)
	local button = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
	button:SetSize(MONEY_BORDER + MONEY_WIDTH, 22)
	button:SetPoint("LEFT", self, "CENTER", CONTROL_X, 0)
	button:SetScript("OnEnter", function()
		GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
		GameTooltip_SetTitle(GameTooltip, self.data.name)
		GameTooltip_AddNormalLine(GameTooltip, self.data.tooltip, true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)
	self.Button = button
end

function GoingOnceButtonControlMixin:Init(initializer)
	SettingsListElementMixin.Init(self, initializer)
	self.Button:SetText(self.data.buttonText)
	self.Button:SetScript("OnClick", self.data.onClick)
end

-- Rows go in through Settings.RegisterInitializer, as SkillUp Forever does: on Forever, rows inserted with
-- Settings.CreateCheckbox taint the settings search, and the stock dropdown trips a menu assertion.
local function RegisterSettings()
	local category = Settings.RegisterVerticalLayoutCategory("Going Once")
	settingsCategory = category

	local function Checkbox(key, name, tooltip)
		local setting = Settings.RegisterAddOnSetting(
			category,
			"GoingOnce_" .. key,
			key,
			db,
			Settings.VarType.Boolean,
			name,
			DEFAULTS[key]
		)
		setting:SetValueChangedCallback(RefreshAll)
		Settings.RegisterInitializer(category, Settings.CreateCheckboxInitializer(setting, nil, tooltip))
	end

	Checkbox(
		"autoConfirm",
		"Buy trade goods on one click",
		"When the price the auction house quotes matches the list, the first click buys. When it costs more, the button shows the total and a second click buys."
	)

	local gear = Settings.RegisterAddOnSetting(
		category,
		"GoingOnce_confirmAbove",
		"confirmAbove",
		db,
		Settings.VarType.Number,
		"Second click for gear from",
		DEFAULTS.confirmAbove
	)
	gear:SetValueChangedCallback(RefreshAll)
	Settings.RegisterInitializer(
		category,
		Settings.CreateControlInitializer(
			"GoingOnceMoneyControlTemplate",
			gear,
			{ zeroText = "Never" },
			"Gear at this price or more needs a second click; leave it at 0 for never. Gear that costs more than the list shows always needs one."
		)
	)

	Checkbox("announce", "Chat line after buying", "A chat line after every purchase with the item and the price paid.")

	Settings.RegisterInitializer(
		category,
		Settings.CreateElementInitializer("GoingOnceButtonControlTemplate", {
			name = "Saved trade good amounts",
			tooltip = "Every trade good goes back to buying one at a time. Right-click or Shift-click a trade good's Buy button to choose how many.",
			buttonText = "Forget",
			onClick = function()
				wipe(db.amounts)
				RefreshAll()
				Print("trade goods buy one at a time again.")
			end,
		})
	)

	Settings.RegisterAddOnCategory(category)
end

-- The settings panel opens through the client's own opener: Blizzard's Lua wrapper (Settings.OpenToCategory)
-- runs its gamepad focus code under the caller and is refused from addon code (ForeverCore does the same).
local function OpenSettings()
	if not settingsCategory then
		return
	end
	if InCombatLockdown() then
		Print("the settings open after combat.")
		return
	end
	local open = C_SettingsUtil and C_SettingsUtil.OpenSettingsPanel
	if open then
		securecallfunction(open, settingsCategory:GetID())
	else
		Print("Esc, Options, AddOns, Going Once.")
	end
end

---------------------------------------------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------------------------------------------

local events = CreateFrame("Frame")
local handlers = {}

function handlers.ADDON_LOADED(name)
	if name == ADDON then
		GoingOnceDB = GoingOnceDB or {}
		db = GoingOnceDB
		for key, value in pairs(DEFAULTS) do
			if db[key] == nil then
				db[key] = value
			end
		end
		db.amounts = db.amounts or {}
		db.log = db.log or {}
		RegisterSettings()
		if C_AddOns.IsAddOnLoaded("Blizzard_AuctionHouseUI") then
			SetUp()
		end
	elseif name == "Blizzard_AuctionHouseUI" and db then
		SetUp()
	end
end

function handlers.ITEM_SEARCH_RESULTS_UPDATED(itemKey)
	local offer = itemKey and offers[KeyOf(itemKey)]
	if offer and not offer.commodity and not (purchase and purchase.key == offer.key) then
		ReadItem(offer)
	end
end
handlers.ITEM_SEARCH_RESULTS_ADDED = handlers.ITEM_SEARCH_RESULTS_UPDATED

function handlers.COMMODITY_SEARCH_RESULTS_UPDATED(itemID)
	local offer = commodityOffers[itemID]
	if offer then
		ReadCommodity(offer)
	end
end
handlers.COMMODITY_SEARCH_RESULTS_ADDED = handlers.COMMODITY_SEARCH_RESULTS_UPDATED

local function ItemBought(auctionID)
	local p = purchase
	if p and p.kind == "item" and p.auctionID == auctionID then
		Succeed(p)
	elseif Late("item") and late.auctionID == auctionID then
		BoughtAfterAll()
	end
end

function handlers.AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)
	Log("event purchase completed", auctionID)
	ItemBought(auctionID)
end

-- The "You won an auction" line; it names the auction, so it settles a bid as surely as the event above.
function handlers.AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION(notification, _, auctionID)
	Log("event notification", notification, auctionID)
	if notification == Enum.AuctionHouseNotification.AuctionWon and auctionID then
		ItemBought(auctionID)
	end
end

-- The errors only a bid gets, so they end an item purchase at once.
local BID_ERRORS = {}
for _, name in ipairs({
	"NotEnoughMoney",
	"HigherBid",
	"BidIncrement",
	"BidOwn",
	"ItemNotFound",
	"MinBid",
	"DoubleBid",
	"ItemNotAvailable",
}) do
	local code = Enum.AuctionHouseError[name]
	if code then
		BID_ERRORS[code] = true
	end
end

-- Blizzard's frame flashes the error text. Any error but a bid's may answer another request, so the purchase keeps
-- waiting for its own answer a little longer, and only then says what failed.
function handlers.AUCTION_HOUSE_SHOW_ERROR(code)
	local p = purchase
	Log("event error", code, p and p.key, p and p.state)
	if not p or p.state == "quoted" then
		return
	end
	if p.kind == "item" and BID_ERRORS[code] then
		Refused(p, code)
		return
	end
	p.errorCode = code
	if p.deadline - Now() > ERROR_GRACE then
		Timeout(p, ERROR_GRACE)
	end
end

function handlers.COMMODITY_PRICE_UPDATED(unitPrice, totalPrice)
	local p = purchase
	Log("event quote", unitPrice, totalPrice, p and p.state)
	if not p or p.kind ~= "commodity" or p.state ~= "quoting" then
		return
	end
	p.unitPrice, p.totalPrice = unitPrice, totalPrice
	p.state = "quoted"
	-- An error while quoting answered something else.
	p.errorCode = nil
	if db.autoConfirm and unitPrice <= p.expectUnit and totalPrice <= GetMoney() and not Expensive(totalPrice) then
		p.auto = true
		if C_AuctionHouse.IsThrottledMessageSystemReady() then
			Confirm(p)
			return
		end
		p.confirmWhenReady = true
	end
	WatchQuote(p)
	Refresh(p.offer)
end

function handlers.COMMODITY_PRICE_UNAVAILABLE()
	local p = purchase
	Log("event quote unavailable", p and p.state)
	if p and p.kind == "commodity" and p.state == "quoting" then
		C_AuctionHouse.CancelCommoditiesPurchase()
		Fail(p, AUCTION_HOUSE_DIALOG_PRICE_UNAVAILABLE)
	end
end

function handlers.COMMODITY_PURCHASE_SUCCEEDED()
	local p = purchase
	Log("event commodity bought", p and p.state)
	if p and p.kind == "commodity" and p.state == "buying" then
		Succeed(p)
	elseif not p and Late("commodity") then
		BoughtAfterAll()
	end
end

function handlers.COMMODITY_PURCHASE_FAILED()
	local p = purchase
	Log("event commodity failed", p and p.state)
	if p and p.kind == "commodity" and p.state == "buying" then
		Fail(p, "the purchase did not go through. Nothing was bought.")
	end
end

function handlers.AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
	local p = purchase
	if p and p.confirmWhenReady then
		Confirm(p)
	elseif queued then
		Send(queued)
	end
end

function handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED()
	Log("event message dropped")
	local slot = hovered
	local offer = slot and slot.key and offers[slot.key]
	if offer and offer.state == "loading" then
		queued = offer
	end
end

-- If the client ever wants a click for the confirm, fall back to the Confirm button for good. The refused call
-- never reached the server, so the quote is still open for that click.
function handlers.ADDON_ACTION_BLOCKED(addon, action)
	if addon ~= ADDON or not tostring(action):find("ConfirmCommoditiesPurchase", 1, true) then
		return
	end
	Log("blocked", action)
	db.autoConfirm = false
	Print("the game wants a click to confirm trade goods, so the button now asks for one.")
	local p = purchase
	if p and p.kind == "commodity" and p.state == "buying" and p.auto then
		OfferQuoteForClick(p)
	end
end
handlers.ADDON_ACTION_FORBIDDEN = handlers.ADDON_ACTION_BLOCKED

function handlers.AUCTION_HOUSE_CLOSED()
	Reset()
end

function handlers.PLAYER_MONEY()
	RefreshAll()
end

events:SetScript("OnEvent", function(_, event, ...)
	handlers[event](...)
end)
for event in pairs(handlers) do
	events:RegisterEvent(event)
end

SLASH_GOINGONCE1 = "/goingonce"
SlashCmdList.GOINGONCE = OpenSettings
