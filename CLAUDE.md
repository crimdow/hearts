# Hearts (hearts.jermins.com) — notes for Claude

A Hearts card-game score sheet. It is one file, `index.html`, with no build step. Login and live sync go through PocketBase on bkweb using the Home Board login; `hearts_role` on users sets editor or viewer. The server side lives in the **home-board** repo.

## Keep as-is
Ben likes the play style and the scorecard: hands, the pass directions, the kitty for 5+ players, moon shots, and the winner celebration. Only the look follows Home Board.

## Layout and settings
- **Header:** trash (start fresh) on the left, trophy (stats) and ☰ (menu) on the right. There is no theme button in the header.
- **Menu (`config` pop, `vset` for viewers):**
  - Players
  - **Appearance:** Light / Dark / Auto. Saved as `hearts-theme`; an empty value means Auto, which follows the phone live.
  - **Score colours:** red, ember, ocean, violet or teal. Each has a light and a dark ramp, and one choice covers both modes (`hearts-colours` = `{all:name}`).
  - Pop-up switches
  - Sign out
- **Heat colours:** each ramp starts at the sheet colour and deepens to 100 points. `flip` is where the number text switches colour.
- **Sign-in:** the opening screen is a sign-in matching the other apps. The old card-back splash was removed.
- **Zoom:** locked.

## Gotchas
- Redraw open menus with `drawPop()`, not `drawPopNow()`. It keeps the scroll position and adds `.still`, so the sheet doesn't replay its slide-up animation (Ben noticed this as a "glitch").
- Theme and colour changes go through `repaintLook()`. It re-renders the sheet, because cell colours are worked out per mode, and redraws the open menu in place.
- A head script sets `data-theme` before first paint, and `meta#tc` follows the app's theme.

## Look
- Same as Home Board: light background `#e4e5e8` with sheet `#eeeff1`, dark background `#1d1e22` with sheet `#25262b`, accent red `#d45b6c`.
- System font in ALL CAPS, round grey icon buttons, solid pills.
- The icon is a red card back with a white card showing a red heart.

## Testing
- Serve it as PocketBase's `--publicDir` with the home-board hooks and migrations, and sign in as a throwaway test user.
- Seed `localStorage['hearts-tally-v2']` with a game, then check light, dark, every colour ramp, and that menus don't jump.
