# CurseForge project page

Paste these into the project settings. The repository is the source of truth; edit here first.

The live page matches this text since 2026-11-16 (v1.1.0). CurseForge's editor keeps the description as Markdown with
its lines unwrapped, so change the sentences there rather than pasting the whole section over it.

## Summary

A Buyout button on every row of the auction house list: hover, click, bought.

## Description

Buying from the auction house takes a click on the item, a wait for its auctions, a pick, then Buyout and a
confirmation. **Going Once** adds a **Buy** column to Blizzard's browse list instead, with a button for every row:

- **Gear:** hover the row, click Buy, and the cheapest is yours at its buyout price. Gear at or above an amount you
  choose, and gear that now costs more than the list shows, asks for a second click first.
- **Trade goods:** one click buys at the listed price. Right-click or Shift-click the button to choose how many to
  buy, remembered for each item. If the price went up, the button shows the total and waits for your second click.
- **The tooltip** says what a click will do, and **a chat line** says what each purchase cost.

Settings are in Options, AddOns, Going Once, or type **/goingonce**: buying trade goods on one click, the amount from
which gear needs a second click (any amount in gold, silver and copper), and the chat line.

Every purchase still takes a click, as Blizzard requires. Going Once works in Blizzard's own auction house window,
alongside Auctionator.

## Categories

Auction & Economy.

## Avatar

`media/icon-400.png`, rendered from `media/icon.svg` with `rsvg-convert -w 400 -h 400 media/icon.svg -o media/icon-400.png`.

## Screenshots

Upload them in the Media tab (drag the files in), with these titles and descriptions:

- `docs/screenshots/buy-column.png`: **The Buy column.** A Buy button on every row of Blizzard's browse list.

Still wanted, without other players' names in view: a trade good set to buy 25 with its tooltip, the chat line
after a purchase, and the settings page.
