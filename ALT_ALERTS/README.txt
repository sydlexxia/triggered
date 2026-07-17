ALT_ALERTS — display overrides (PNG only)
=========================================
Drop files named <state>.png here to replace the plain alert color
on the alert page:

  green.png  — shown instead of green OK
  red.png    — shown instead of red ALERT
  amber.png  — shown instead of amber QUIET

Only these three PNG filenames are recognized; any other files in this
folder (like this one) are ignored. HTML files are deliberately NOT
supported — an HTML override would execute script in every viewer's
browser, so it was removed by design (2026-07-17).

Images display full-screen (scaled to fill; edges may crop).
Files are picked up live — no server restart needed.
