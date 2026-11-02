# say — brand assets · concept B (talking-bubble)

Colours
- Lime  #C6F432  — brand, primary buttons, the mark's tile
- Ink   #0D0E12  — the mouth, app background
- White #ECEDF1  — text on dark
- Yes   #3DDC97 / No #FF5A6E — product only, never in the logo

The mark
- Primary: lime tile, ink mouth (svg/mark.svg). On lime backgrounds use svg/mark-inverse.svg.
- One-colour: svg/mark-mono-black.svg / -white.svg (mouth is cut out, so the background shows through).
- Mouth only, no tile: svg/glyph-ink.svg / glyph-lime.svg — for stickers, motion, merch.
- Clear space: keep at least 25% of the mark's width empty on every side.
- Minimum size: 16 px on screen (favicon), 10 mm in print.
- Don't: stretch it, rotate it, outline it, add shadows or gradients, recolour the mouth, or put the lime tile on a busy photo.

Lockups (wordmark = Bricolage Grotesque ExtraBold, converted to outlines — no font needed)
- svg/lockup-on-dark.svg — default; white wordmark
- svg/lockup-on-light.svg — ink wordmark
- svg/lockup-on-lime.svg — ink tile, ink wordmark, for lime surfaces
- svg/wordmark-*.svg — the word alone. Always lowercase.

Web (favicon/)
Copy the files to your site root and paste head.html into <head>. site.webmanifest is ready for Android/PWA.
- favicon.ico (16/32/48), favicon.svg, favicon-16/32/48.png
- apple-touch-icon.png (180, full-bleed — iOS rounds it)
- android-chrome-192/512.png, maskable-512.png (mouth inside the 80% safe zone)

App stores (app/)
- ios-app-icon-1024.png — full bleed, no transparency, no rounding (Apple rounds it)
- android-adaptive-foreground-432.png + android-adaptive-background-432.png — adaptive icon layers (mouth in the 66% safe zone)
- play-store-512.png

Social (social/)
- og-image-1200x630.png — link previews (set as og:image / twitter:image)
- avatar-400.png — profile picture (survives circle crops)
- header-1500x500.png — X/Twitter header
