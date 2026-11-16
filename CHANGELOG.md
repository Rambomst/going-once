# Changelog

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
