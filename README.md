# Hearts

A Hearts score sheet for 4–8 players: pick who's playing, tap + to enter each player's points, get passing reminders between hands, and see wins and moon shots over time. Players and finished games are saved in Supabase so everyone's phone sees the same list.

## What's in here

| File | What it is |
|---|---|
| `index.html` | The whole app |
| `manifest.webmanifest` | Lets Android "Install app" / "Add to Home screen" use the name and icon |
| `favicon.ico`, `icon.svg` | Browser tab icons |
| `apple-touch-icon.png` | iPhone / iPad home-screen icon |
| `android-chrome-192.png`, `android-chrome-512.png` | Android home-screen icons |
| `supabase/schema.sql` | Creates the Supabase tables, permissions and starting roster |

## 1. Set up Supabase (about 5 minutes)

1. Go to [supabase.com](https://supabase.com), sign in, and click **New project**. Pick any name (e.g. `hearts`), set a database password, choose a region near you, and create it. Wait for it to finish setting up.
2. In the left sidebar open **SQL Editor** > **New query**.
3. Open `supabase/schema.sql` from this repo, copy everything, paste it into the editor, and click **Run**. You should see "Success. No rows returned."
4. Check it worked: open **Table Editor**. You should see `people` (with Ben, Noah, James, Brodie, Kevin, Taylor, Casey, Davin) and `games` (empty).
5. Get your keys: **Project Settings** (gear icon) > **API**. Copy:
   - **Project URL** (looks like `https://abcdefghijk.supabase.co`)
   - **anon public** key (a long string starting `eyJ...`)

   Newer projects may label this the **publishable key** under **API Keys**; that works the same way.

## 2. Put your keys in the app

Open `index.html`, search for `YOUR-PROJECT`, and replace the two placeholder lines:

```js
const SUPABASE_URL = 'https://abcdefghijk.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOi...';
```

The anon key is designed to be public, so it's fine in a public GitHub repo. What it can do is limited by the policies in `schema.sql`. Never paste the **service_role** / secret key into the app.

## 2b. Set your passcode

Tapping the card asks for a 3-digit passcode: **168**. Each phone only asks once, and asks again if you change the code.

To change it, get the SHA-256 of your new code and paste it into `PASSCODE_HASH` in `index.html`. If the new code has a different number of digits, also change `PIN_LEN`:

```bash
echo -n 168 | shasum -a 256      # Mac / Linux
```

On Windows (PowerShell): `[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("168"))).Replace("-","").ToLower()`

Only the hash is in the file, so the code isn't readable from the page source. The passcode keeps casual visitors out of the sheet. It doesn't lock the Supabase tables: someone who digs into the page could still reach them with the anon key.

## 3. Put it on GitHub Pages

**In the browser (no command line):**

1. On [github.com](https://github.com) click **+** > **New repository**. Name it (e.g. `hearts`), keep it **Public** (GitHub Pages needs a public repo on free plans), and click **Create repository**.
2. Click **uploading an existing file**, drag in everything from this folder (including the `supabase` folder), and click **Commit changes**.
3. Go to **Settings** > **Pages**. Under **Build and deployment**, set **Source** to **Deploy from a branch**, **Branch** to `main` and folder `/ (root)`, then **Save**.
4. After a minute or two the page shows your link: `https://YOUR-USERNAME.github.io/hearts/`.

**Or from a terminal:**

```bash
cd hearts
git init
git add .
git commit -m "Hearts score sheet"
git branch -M main
git remote add origin https://github.com/YOUR-USERNAME/hearts.git
git push -u origin main
```

Then turn on Pages as in step 3 above.

## 4. Add it to your phone

- **iPhone (Safari):** open the link, tap **Share** > **Add to Home Screen** > **Add**. It opens full screen with the heart-and-spade icon.
- **Android (Chrome):** open the link, tap **⋮** > **Add to Home screen** (or **Install app**).

Send the same link to everyone at the table; they all share the same players and stats.

## 5. Check it's connected

Open the app, tap the card, tap **Who's playing Hearts today?**, and add a test player. Then look in Supabase > **Table Editor** > `people`: the new name should be there. After your first finished game, a row appears in `games`, and **Stats** in the app fills in.

To browse stats in Supabase, open **Table Editor** > `player_stats` (it's a view, so it's always up to date).

## Changing things later

- **Remove a player from the list:** delete their row in `people`. Their past games still count.
- **Delete a mistaken game:** delete its row in `games`; stats update automatically.
- **Edit the app:** change `index.html` on GitHub (pencil icon) and commit. Pages updates within a minute or two. On phones, pull to refresh or reopen the app.

## Troubleshooting

| What you see | Likely cause |
|---|---|
| "Saved on this device only right now" when adding a player | The URL or key in `index.html` is missing or wrong, or `schema.sql` wasn't run |
| Stats says "Stats aren't available right now" | Same as above |
| Page shows but GitHub link is 404 | Pages isn't turned on yet, or it's still building (check **Actions** tab) |
| Old version still showing on a phone | Close the app fully and reopen, or pull to refresh in the browser |

Game in progress is saved on each phone (in the browser), so one person should keep score for a given game.
