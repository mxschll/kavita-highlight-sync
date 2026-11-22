# Kavita highlight sync for KOReader

Two-way sync of EPUB **highlights and notes** between KOReader and Kavita (0.8.8+, the first release with annotations).

- Highlights you make in KOReader show up in Kavita's web reader and annotation list.
- Highlights you make in Kavita's web reader appear in KOReader.
- Edits to a note or colour, and deletions, carry over in both directions.

There's nothing to install on the server. The plugin uses Kavita's existing REST API and the same API key as your Kavita progress sync.

## Install

1. Copy the `kavitahl.koplugin` folder into KOReader's `plugins/` folder (e.g. `koreader/plugins/` on Kobo, or `.adds/koreader/plugins/` on some setups).
2. Restart KOReader.

## Set up

If KOReader's **Progress sync** already points at Kavita (custom server `https://your-kavita/api/koreader/<key>`), there's nothing to set up: the plugin reads the server and key from there.

If it doesn't, open a book, then go to **Tools ▸ Kavita highlight sync ▸ Server settings** and enter:

- **Server URL**: `https://kavita.example.com`
- **API / auth key**: in Kavita, open User settings. On 0.9+ it's under *Manage auth keys*; on 0.8 it's under *3rd party clients*.

## Use

- **Tools ▸ Kavita highlight sync ▸ Sync highlights now** syncs the open book.
- **Sync automatically on open and close** syncs when you open a book and pushes your local changes when you close it. It only runs if Wi-Fi is already on, so you won't get Wi-Fi prompts.

## How it works

- **Finding the book.** Kavita stores KOReader's partial-MD5 hash for every file (it uses it for progress sync). The plugin searches Kavita by the book's title and filename, then picks the file whose hash matches. The link is cached per book, so the search only runs once.
- **KOReader → Kavita.** The highlight's xpointer (`/body/DocFragment[5]/body/div/p[3]/text().12`) becomes Kavita's page number (4) and block XPath (`//body/div[1]/p[3]`). The text, note and colour go with it. Kavita finds the exact characters by matching the text inside that block, the same way it does for Kobo highlights.
- **Kavita → KOReader.** The plugin searches the open book for the highlighted text, limited to the right spine item (and the right paragraph when Kavita gives a plain XPath). Long or multi-paragraph highlights are found by their start and end.
- **Two-way merge.** A per-book snapshot of the last sync, stored in the book's sidecar, tells apart "deleted here" from "new there". If a highlight was changed on both sides, the KOReader version wins.
- **No duplicates.** If the sync history is missing (a second device, or after *Re-match this book*), highlights with identical text are linked rather than duplicated.
- **Safety check.** If one sync would delete more than half of the synced highlights (more than 3), it asks first. Automatic syncs skip those deletions instead.

### Colours

| Kavita slot (default colour) | KOReader colour        |
|------------------------------|------------------------|
| 0 cyan                       | cyan (also blue)       |
| 1 green                      | green (also olive)     |
| 2 yellow                     | yellow (also gray)     |
| 3 orange                     | orange (also red)      |
| 4 magenta                    | purple                 |

If you've changed your Kavita highlight slot colours, edit `COLOR_TO_SLOT` and `SLOT_TO_COLOR` in `kavitahl_mapping.lua`.

## Limitations

- EPUB only. Kavita has no annotations for PDFs or comics.
- The file on your device must be byte-identical to the one in Kavita. Downloading it through Kavita's OPDS feed guarantees that. A converted or re-saved copy won't match.
- Only your own Kavita annotations sync. Highlights other users share with you are ignored.
- Spoiler flags and likes stay Kavita-only. Comments are synced as plain text.
- A Kavita highlight whose text can't be found in the book (e.g. one made in an older version of the file) is skipped and counted as *couldn't be placed*. It's retried on every sync.
- Kavita has no "changed since" API, so each sync fetches the annotations for the open book only. That's fast, but books you don't open aren't synced.

## Development

`tests/` holds tests that run outside KOReader with any Lua 5.1+ (`cd tests && lua test_mapping.lua`, or `texlua`):

- `test_mapping.lua`: xpointer/XPath conversion, colours, notes and the sync planner.
- `test_sync.lua`: whole sync runs against a fake KOReader document and a fake Kavita server.
