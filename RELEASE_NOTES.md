# Glyph Studio 0.4.10

Arena moved into its own app, **Glyph Arena**, so Studio stays focused on your work.

- **Routed by Arena.** When a chat is on Auto, Studio follows the routing policy
  Glyph Arena writes in your vault: the recipe that won for that domain and kind of
  task on your own tasks. The route chip says "routed by Arena"; click it to open
  Glyph Arena. With no policy, Auto routes exactly as before, and a model you keep
  picking by hand still wins.
- **The Arena tab** now explains the move and opens Glyph Arena (or
  glyph.fru.dev/arena if it is not installed). Your past benchmark runs stay in
  your vault.
- The engine (Glyph Engine 1.10.9) carries Arena's logic: `prevail arena` runs
  duels, blind picks and the policy from the command line.

More at https://glyph.fru.dev/arena
