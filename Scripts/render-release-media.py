#!/usr/bin/env python3
"""Frame current app captures for the README and GitHub social preview.

Requires Playwright's Python package and Chromium. No foreground browser,
external requests, app profile access, or modifications to screenshot pixels.
"""

import base64
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
MEDIA = ROOT / "docs" / "media"


def image(name):
    return "data:image/png;base64," + base64.b64encode((MEDIA / name).read_bytes()).decode()


def main():
    home = image("home-light.png")
    icon = image("icon.png")
    compositions = {
        "hero.png": (1280, 880, f"""
            <style>
            body {{margin:0;background:#eae5db;font-family:-apple-system,BlinkMacSystemFont,sans-serif}}
            .caption {{display:flex;justify-content:space-between;margin:31px 48px 24px;color:#5c6157;font-size:13px;letter-spacing:1.5px}}
            img {{display:block;width:1184px;height:auto;margin:0 48px;border-radius:12px;box-shadow:0 18px 34px #172a3133}}
            </style>
            <div class="caption"><span>KEEL FOR MAC</span><span>HOME · ONE PAGE AT A TIME</span></div>
            <img src="{home}" alt="Current Keel Home view">
            """),
        "social-preview.png": (1280, 640, f"""
            <style>
            body {{margin:0;background:#10283d;color:#faf7ef;font-family:-apple-system,BlinkMacSystemFont,sans-serif}}
            main {{padding:72px 80px}}
            .brand {{display:flex;align-items:center;gap:20px;font-size:28px;font-weight:600}}
            .brand img {{width:80px;height:80px;border-radius:18px}}
            h1 {{font-family:Georgia,serif;font-weight:400;font-size:84px;line-height:1.08;letter-spacing:-2px;margin:42px 0 24px}}
            p {{font-size:25px;line-height:1.5;color:#d1d9dc;margin:0}}
            footer {{position:absolute;bottom:48px;left:80px;right:80px;border-top:1px solid #ffffff30;padding-top:22px;display:flex;justify-content:space-between;font-size:17px;color:#c0cbce}}
            </style>
            <main><div class="brand"><img src="{icon}" alt="">Keel</div>
            <h1>One page.<br>Then the next.</h1>
            <p>A native macOS browser. Queue links. Finish the page you're on.</p></main>
            <footer><span>github.com/rowesk/Keel</span><span>Created by Chris Rowe</span></footer>
            """),
    }
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        try:
            for name, (width, height, content) in compositions.items():
                page = browser.new_page(viewport={"width": width, "height": height}, device_scale_factor=1)
                page.route("http://**/*", lambda route: route.abort())
                page.route("https://**/*", lambda route: route.abort())
                page.set_content(content, wait_until="load")
                page.evaluate("document.fonts.ready")
                page.screenshot(path=str(MEDIA / name))
                page.close()
                print(name)
        finally:
            browser.close()


if __name__ == "__main__":
    main()
