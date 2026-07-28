# assets

Source artwork that generated files elsewhere in this repo are derived from.
Listed in `.chezmoiignore`, so nothing here is copied into `$HOME` — it exists
so a generated file can be regenerated rather than reverse-engineered.

## lokilabslogo.png

The Loki Labs wordmark, source for Omarchy's screensaver branding
(`dot_config/omarchy/branding/screensaver.txt`).

Omarchy's screensaver is not an image viewer: it runs `tte` over a *text* file
and animates it with random effects. The PNG is transcoded to braille-character
art with:

```sh
omarchy transcode ascii assets/lokilabslogo.png \
  dot_config/omarchy/branding/screensaver.txt --width 80
```

Two things worth keeping if you regenerate it:

- **No `--invert`.** That flag treats light pixels as the logo, which on this
  transparent PNG renders a solid filled block. The default (dark pixels) is
  the legible one.
- **`--width 80`.** A 1:1 pixel mapping would be 127 columns (the image is
  254px wide, two pixels per braille cell) and is visibly sharper, but 80
  matches the stock Omarchy logo and fits any terminal the screensaver lands
  in. The current 1920x1080 display has room for 127; a smaller one would wrap.

`omarchy branding screensaver <image|text|reset>` writes to that same target,
so running it will be undone by the next `chezmoi apply`. Change the art here
and re-run the command above instead.
