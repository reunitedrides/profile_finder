"""
Roof Profile Finder - Tile Image Downloader
Run this from: C:\apps\ios apps\profile finder\
It will download images for all 192 tile profiles and update the JSON.

Requirements - run first:
  pip install requests beautifulsoup4 Pillow ddgs
"""

import json
import os
import time
import re
import requests
from pathlib import Path
from PIL import Image
from io import BytesIO

# ── Config ──────────────────────────────────────────────────────
SCRIPT_DIR   = Path(__file__).parent
JSON_PATH    = SCRIPT_DIR / 'assets' / 'data' / 'tile_profiles_uk_phase2.json'
IMAGES_DIR   = SCRIPT_DIR / 'assets' / 'images'
LOG_PATH     = SCRIPT_DIR / 'tile_image_download_log.txt'

HEADERS = {
    'User-Agent': (
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/124.0 Safari/537.36'
    )
}
MAX_SIZE_PX  = 800   # resize if larger
MIN_SIZE_PX  = 100   # skip if smaller (likely icon/logo)
DELAY_SECS   = 2.0   # polite delay between searches
# ────────────────────────────────────────────────────────────────


def log(msg, fp):
    print(msg)
    fp.write(msg + '\n')
    fp.flush()


def download_image(url, save_path):
    """Download image, resize if needed, save as PNG. Returns True on success."""
    try:
        r = requests.get(url, headers=HEADERS, timeout=10, stream=True)
        r.raise_for_status()
        img = Image.open(BytesIO(r.content)).convert('RGB')
        w, h = img.size
        if w < MIN_SIZE_PX or h < MIN_SIZE_PX:
            return False  # too small
        if w > MAX_SIZE_PX or h > MAX_SIZE_PX:
            img.thumbnail((MAX_SIZE_PX, MAX_SIZE_PX), Image.LANCZOS)
        img.save(save_path, 'PNG', optimize=True)
        return True
    except Exception as e:
        return False


def search_ddgs(query):
    """Search DuckDuckGo images, return list of image URLs."""
    try:
        from ddgs import DDGS
        with DDGS() as ddgs:
            results = list(ddgs.images(query, max_results=5))
            return [r['image'] for r in results if r.get('image')]
    except Exception as e:
        return []


def search_bing(query):
    """Fallback: scrape Bing image search."""
    try:
        from bs4 import BeautifulSoup
        url = f"https://www.bing.com/images/search?q={requests.utils.quote(query)}&form=HDRSC2"
        r = requests.get(url, headers=HEADERS, timeout=10)
        soup = BeautifulSoup(r.text, 'html.parser')
        urls = []
        for tag in soup.find_all('a', {'class': 'iusc'}):
            try:
                import json as _json
                m = tag.get('m', '{}')
                data = _json.loads(m)
                if data.get('murl'):
                    urls.append(data['murl'])
            except:
                pass
        return urls[:5]
    except:
        return []


def get_image_urls(manufacturer, profile_name):
    """Try multiple search strategies to find an image."""
    queries = [
        f'{manufacturer} {profile_name} roof tile',
        f'{profile_name} roof tile UK',
        f'{manufacturer} {profile_name} roofing',
    ]
    for q in queries:
        urls = search_ddgs(q)
        if urls:
            return urls
        time.sleep(1)
        urls = search_bing(q)
        if urls:
            return urls
        time.sleep(1)
    return []


def main():
    IMAGES_DIR.mkdir(parents=True, exist_ok=True)

    with open(JSON_PATH, encoding='utf-8') as f:
        tiles = json.load(f)

    total     = len(tiles)
    success   = 0
    skipped   = 0
    failed    = []

    with open(LOG_PATH, 'w', encoding='utf-8') as logf:
        log(f'Starting download for {total} tile profiles...\n', logf)

        for i, tile in enumerate(tiles):
            tile_id      = tile['id']
            manufacturer = tile['manufacturer']
            profile_name = tile['profileName']
            save_path    = IMAGES_DIR / f'{tile_id}.png'
            image_key    = f'assets/images/{tile_id}.png'

            # Skip if already downloaded
            if save_path.exists():
                tile['image_file'] = image_key
                skipped += 1
                log(f'[{i+1}/{total}] SKIP (exists): {tile_id}', logf)
                continue

            log(f'[{i+1}/{total}] Searching: {manufacturer} - {profile_name}', logf)

            urls = get_image_urls(manufacturer, profile_name)

            downloaded = False
            for url in urls:
                if download_image(url, save_path):
                    tile['image_file'] = image_key
                    success += 1
                    log(f'  ✓ Downloaded: {url[:80]}', logf)
                    downloaded = True
                    break

            if not downloaded:
                failed.append(tile_id)
                log(f'  ✗ FAILED: {manufacturer} - {profile_name}', logf)

            time.sleep(DELAY_SECS)

        # Save updated JSON
        with open(JSON_PATH, 'w', encoding='utf-8') as f:
            json.dump(tiles, f, indent=2, ensure_ascii=False)

        log(f'\n═══ Complete ═══', logf)
        log(f'Downloaded: {success}', logf)
        log(f'Skipped (existed): {skipped}', logf)
        log(f'Failed: {len(failed)}', logf)
        if failed:
            log(f'Failed tiles:', logf)
            for fid in failed:
                log(f'  - {fid}', logf)
        log(f'\nJSON updated: {JSON_PATH}', logf)
        log(f'Log saved: {LOG_PATH}', logf)


if __name__ == '__main__':
    main()
