# TrueLink

iOS tweak that cleans links as you copy them, so you paste (and clipboard managers record) only the real destination.

## Background

Inspired by [CleanCopy](https://b4db1r3r3p0.yourepo.com/pack/cleancopy) by b4db1r3. Google now wraps search result links as `google.com/goto?url=<token>`, where the destination is encrypted inside the token. CleanCopy can't decode it, so copied Google links stay wrapped. TrueLink keeps the same idea of cleaning links on copy, and adds support for these new Google links (plus Reddit `/s/` and `amzn.to` short links) by resolving them through the server.

## Features

- **Resolves short links**: Google `/goto?url=…`, Reddit `/s/…` and `amzn.to/…` hide the destination on the server. TrueLink asks the server for it, without opening the page, and copies the real URL instead.
- **Unwraps redirects**: `google.com/url?q=`, `googleadservices ?adurl=`, `l.facebook.com/l.php?u=`, `lnkd.in/redirect?url=`.
- **Strips tracking**: `utm_*`, `fbclid`, `gclid`, `msclkid`, `srsltid`, … everywhere, plus share junk from Google, YouTube, Facebook, Instagram, Threads, X, Reddit, LinkedIn and Spotify.
- **Shortens Amazon links** to the clean `/dp/<ASIN>` form.
- **Works system-wide**: in any app, including links inside copied text.

## Examples

```
https://youtu.be/abc123?si=XYZ&t=42                        →  https://youtu.be/abc123?t=42
https://example.com/a?id=5&utm_source=fb&fbclid=abc        →  https://example.com/a?id=5
https://www.google.com/url?q=https://shop.vn/p&sa=U        →  https://shop.vn/p
https://x.com/u/status/1?s=20&t=abc                        →  https://x.com/u/status/1
https://www.amazon.com/Some-Product/dp/B09ABC1234/ref=sxin  →  https://www.amazon.com/dp/B09ABC1234
https://www.google.com/goto?url=CAES…                      →  https://example.com/article
```

## Notes

- For short links, the copy waits for the server's answer, usually about 0.2 s. If the request fails or takes longer than 4 s, the original link is copied unchanged.
- Images, files and other non-text content are never modified.
