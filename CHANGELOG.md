# Changelog

## v1.2.1

- The red "Internal auction error" no longer flashes when you buy gear whose price has copper in it. The auction
  house sends it for every such buyout and sells the item anyway, so the message meant nothing. A purchase that
  really fails still says why.

## v1.2.0

- The list no longer stutters when you run the mouse over many rows or scroll with the mouse on it. A row is read
  when the mouse rests on it, not while it passes over, and a read no longer makes the game draw the whole list
  again.
- A row keeps the price the list showed until your next search or purchase. If the cheapest one costs more by the
  time you get to it, the Buy button turns orange and asks for a second click, as before.
- A read that was still waiting its turn is dropped when the mouse leaves its row, so fewer searches count against
  the auction house's limit.

## v1.1.1

- Now also on [Wago Addons](https://addons.wago.io/addons/going-once). Nothing changes in game.

## v1.1.0

- Shift-click a trade good's Buy button to choose how many to buy, as at a vendor; right-click still works. The
  tooltip says so near the top, and the first time you buy a single trade good a chat line says how to buy more.
- The settings page lines its options up, and the chat option is now called "Chat line after buying".

## v1.0.0

First release.

- A Buy column at the right of the auction house browse list, with a button for every row. Hovering a row reads its
  auctions; one click buys the cheapest gear at its buyout price, or a trade good at the listed price.
- Gear asks for a second click when it costs more than the list shows, or at least the amount set in Options,
  AddOns, Going Once (any amount in gold, silver and copper; 50 gold to start with, 0 for never).
- Trade goods buy as many as you set with a right-click, remembered for each item. A price above the list shows
  the total and waits for a second click.
- A chat line after each purchase with the item and what you paid. When the auction house flashes "Internal auction
  error" for a purchase that goes through anyway, the line says so.
- A log of the last 200 auction house steps in the saved variables, for bug reports.
