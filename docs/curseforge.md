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

---

### Buy me a coffee?

<a href="https://ko-fi.com/ram01"><img src="https://storage.ko-fi.com/cdn/brandasset/v2/support_me_on_kofi_beige.png" alt="Support me on Ko-fi" width="254" height="51"></a>

## Categories

Auction & Economy.

## Donation

General tab, Donation Method: Ko-fi, username `ram01` (set 2026-11-16): a Donate link on the project page. The
description also ends with the Ko-fi badge above, as the Nexus pages do (saved 2026-11-16).

The badge is HTML because only HTML keeps its size: the image is 980 by 198. The editor shows a saved description
back as Markdown and turns the badge into `[![Support me on Ko-fi](...)](https://ko-fi.com/ram01)` without the size,
so before saving any later edit, put the HTML line back in its place, or the badge goes up at full width.

## Avatar

`media/icon-400.png`, rendered from `media/icon.svg` with `rsvg-convert -w 400 -h 400 media/icon.svg -o media/icon-400.png`.

## Screenshots

Upload them in the Media tab (drag the files in), with these titles and descriptions:

- `docs/screenshots/buy-column.png`: **The Buy column.** A Buy button on every row of Blizzard's browse list.
  On the page since 2026-11-16, featured.

Still wanted, without other players' names in view: a trade good set to buy 25 with its tooltip, the chat line
after a purchase, and the settings page.
