# Glyph Bot 0.4.11

One typeface and one accent, so every Glyph app reads as the same software.

- **The system sans everywhere**, headings included. The serif display face is gone.
- **Office green is the only hue.** The "AI" colour was a fixed teal in every palette; it now follows whichever accent your palette uses, and the dead cyan logo tokens are gone. Grey carries everything that is not the accent; amber and red stay for warnings and errors.
- **Dependency advisories cleared**: twelve in the JavaScript tree (two high, three critical) and thirteen in the Rust tree. The build tooling moved with them (vitest 3 to 5, @sentry/vite-plugin 5 to 11); nothing a user runs changed.
- A test holds the look in place now: no serif heading, nothing painted cyan or purple.
