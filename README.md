#!/usr/bin/env python3
"""Zoom Player MediaCache Builder - offline local NFO/artwork updater with source-folder cache matching.

Offline builder: creates show-named seed folders for TV before automation (or a video-named seed for Movies), then updates only uniquely matched cache entries Zoom Player creates.
It never invents Zoom Player identifiers and does not invoke online scrapers.
TV workflow: seed show cache folders, refresh TV Shows, press Backspace, refresh TV Episodes, scroll the category list, exit Zoom Player, then rescan MediaCache. Episode matching first uses a unique exact video filename, with the show token used to resolve duplicate filenames.
"""
from __future__ import annotations
import os, re, sys, shutil, threading, queue, time, traceback, ctypes, subprocess
from pathlib import Path
from datetime import datetime
import xml.etree.ElementTree as ET
import tkinter as tk
import ctypes.wintypes
from tkinter import ttk, filedialog, messagebox

APP_NAME = "Zoom Player MediaCache Builder"
DEFAULT_CACHE = Path(r"C:\ProgramData\Zoom Player\MediaCache")
VIDEO_EXTS = {'.mkv','.mp4','.avi','.m4v','.mov','.wmv','.mpg','.mpeg','.ts','.m2ts','.webm','.flv','.iso'}
ART_SUFFIXES = ('poster','fanart','landscape','discart','clearlogo','clearart','banner','thumb')
TMDB_GENRES = {
 'Action':28,'Adventure':12,'Animation':16,'Comedy':35,'Crime':80,'Documentary':99,
 'Drama':18,'Family':10751,'Fantasy':14,'History':36,'Horror':27,'Music':10402,
 'Mystery':9648,'Romance':10749,'Science Fiction':878,'TV Movie':10770,'Thriller':53,
 'War':10752,'Western':37
}


def norm(s):
    return re.sub(r'[^a-z0-9]+','', (s or '').casefold())

def child_text(node, name, default=''):
    if node is None: return default
    el = node.find(name)
    return (el.text or '').strip() if el is not None and el.text else default

def all_text(node, name):
    if node is None: return []
    return [(e.text or '').strip() for e in node.findall(name) if e.text and e.text.strip()]

def parse_nfo(path):
    try:
        root = ET.parse(path).getroot()
        data = {'_root': root, '_path': Path(path)}
        for key in ('title','originaltitle','sorttitle','plot','outline','tagline','year','premiered','releasedate','runtime','rating','mpaa','country','studio','director','credits','season','episode','showtitle','id','tmdbid','imdbid','tvdbid','tvdbslugid'):
            data[key] = child_text(root, key)
        data['genres'] = all_text(root, 'genre')
        data['countries'] = all_text(root, 'country')
        data['studios'] = all_text(root, 'studio')
        data['directors'] = all_text(root, 'director')
        data['actors'] = []
        for a in root.findall('actor'):
            name=child_text(a,'name'); role=child_text(a,'role')
            if name: data['actors'].append((name, role))
        ratings=root.find('ratings')
        if ratings is not None:
            for r in ratings.findall('rating'):
                if (r.get('name') or '').casefold() in ('themoviedb','tmdb'):
                    val=child_text(r,'value')
                    if val: data['rating']=val
                    break
        # Kodi-style unique IDs take precedence where correctly typed.
        for u in root.findall('uniqueid'):
            typ=(u.get('type') or '').casefold(); val=(u.text or '').strip()
            if val and typ=='tmdb': data['tmdbid']=val
            elif val and typ=='imdb': data['imdbid']=val
        if not data['imdbid'] and data['id'].startswith('tt'): data['imdbid']=data['id']
        return data
    except Exception as e:
        raise ValueError(f"Cannot read NFO: {path}\n{e}")

def _decode_metadata_bytes(raw):
    """Decode an existing Zoom Player metadata file without silently mixing encodings."""
    if raw.startswith(b'\xef\xbb\xbf'):
        return raw.decode('utf-8-sig'), 'utf-8-sig'
    if raw.startswith(b'\xff\xfe'):
        return raw.decode('utf-16'), 'utf-16'
    if raw.startswith(b'\xfe\xff'):
        return raw.decode('utf-16'), 'utf-16'
    # Detect BOM-less UTF-16 by its alternating NUL bytes before trying UTF-8.
    sample=raw[:256]
    if sample and sample.count(b'\x00') > len(sample)//8:
        even_nuls=sample[0::2].count(0); odd_nuls=sample[1::2].count(0)
        enc='utf-16-be' if even_nuls > odd_nuls else 'utf-16-le'
        return raw.decode(enc), enc
    try:
        return raw.decode('utf-8'), 'utf-8'
    except UnicodeDecodeError:
        return raw.decode('cp1252'), 'cp1252'

def read_metadata(path):
    """Read Zoom Player's key=value metadata without assuming its byte encoding."""
    result={}
    try:
        raw=Path(path).read_bytes()
        text, _encoding = _decode_metadata_bytes(raw)
        for line in text.splitlines():
            if '=' in line:
                k,v=line.split('=',1); result[k.strip()]=v.strip()
    except (OSError, UnicodeError):
        pass
    return result

def write_metadata(path, values):
    """Update key=value metadata while preserving the existing file's byte encoding and BOM."""
    p = Path(path)
    lines = []
    seen = set()
    raw = p.read_bytes() if p.exists() else b""
    encoding = "cp1252"
    bom = b""

    if raw:
        # Preserve the exact encoding style used by the Zoom Player-generated file.
        if raw.startswith(b"\xef\xbb\xbf"):
            encoding, bom = "utf-8", b"\xef\xbb\xbf"
            decoded = raw[3:].decode("utf-8", errors="replace")
        elif raw.startswith(b"\xff\xfe"):
            encoding, bom = "utf-16-le", b"\xff\xfe"
            decoded = raw[2:].decode("utf-16-le", errors="replace")
        elif raw.startswith(b"\xfe\xff"):
            encoding, bom = "utf-16-be", b"\xfe\xff"
            decoded = raw[2:].decode("utf-16-be", errors="replace")
        else:
            decoded, encoding = _decode_metadata_bytes(raw)

        for line in decoded.splitlines():
            if "=" not in line:
                if line.strip():
                    lines.append(line)
                continue
            k = line.split("=", 1)[0].strip()
            if k in values:
                if k not in seen and values[k] is not None:
                    val = str(values[k]).replace("\r", " ").replace("\n", " ")
                    lines.append(f"{k}={val}")
                    seen.add(k)
                # None means remove stale source metadata key.
            else:
                lines.append(line)

    for k, v in values.items():
        if k not in seen and v is not None:
            val = str(v).replace("\r", " ").replace("\n", " ")
            lines.append(f"{k}={val}")

    # Zoom Player's confirmed folder.metadata layout: keep its technical fields first,
    # then parsed_title/scrape_error, followed by TMDB fields in the exact observed order.
    # This deliberately normalizes known keys instead of appending newly populated fields
    # after the technical fields in whatever order the NFO parser happened to produce them.
    canonical_order = [
        "filesize", "duration", "width", "height", "modified", "mediaicons",
        "parsed_title", "scrape_error",
        "TheMovieDB_media_name_year", "TheMovieDB_id", "TheMovieDB_imdb_id",
        "TheMovieDB_title", "TheMovieDB_tv_show_name", "TheMovieDB_release_date",
        "TheMovieDB_runtime", "TheMovieDB_rating", "TheMovieDB_genre",
        "TheMovieDB_director", "TheMovieDB_cast", "TheMovieDB_overview",
        "TheMovieDB_mpaa_rating",
    ]
    rank = {key: index for index, key in enumerate(canonical_order)}
    known_lines, other_lines = [], []
    for line in lines:
        key = line.split("=", 1)[0].strip() if "=" in line else None
        if key in rank:
            known_lines.append((rank[key], line))
        else:
            other_lines.append(line)
    known_lines.sort(key=lambda item: item[0])
    lines = [line for _, line in known_lines] + other_lines

    content = "\r\n".join(lines).rstrip("\r\n") + "\r\n"
    if encoding == "utf-16-le":
        encoded = content.encode("utf-16-le")
    elif encoding == "utf-16-be":
        encoded = content.encode("utf-16-be")
    elif encoding == "utf-8":
        encoded = content.encode("utf-8")
    else:
        encoded = content.encode("cp1252", errors="replace")
    p.write_bytes(bom + encoded)

def safe_copy(src, dst):
    dst=Path(dst); dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src,dst)

def genres_value(genres):
    parts=[]
    for g in genres:
        gid=TMDB_GENRES.get(g.casefold().title())
        # Normalize the common spelling used by TMDB.
        if g.casefold() in ('sci-fi','science fiction'): gid=878; g='Science Fiction'
        if gid is None:
            # Do not invent numeric IDs for unknown genre labels.
            continue
        parts.append(f"{gid}|{g}")
    return ';'.join(parts) if parts else None

def cast_value(nfo_actors, old_value):
    """Reuse existing numeric person IDs only for exact actor names present in local NFO."""
    ids={}
    for entry in (old_value or '').split(';'):
        if '|' in entry:
            pid,name=entry.split('|',1); ids[norm(name)]=(pid,name)
    parts=[]
    for name,role in nfo_actors:
        found=ids.get(norm(name))
        if found and found[0].isdigit(): parts.append(f"{found[0]}|{name}")
    return ';'.join(parts) if parts else None

def media_title(data): return data.get('title') or data.get('originaltitle') or ''

def cache_entries(cache_root):
    out=[]
    # Include normal metadata folders AND Zoom Player's own suffixed cache folders
    # even if folder.metadata is temporarily missing. Do not treat the old fake
    # video-filename placeholder (which has no Zoom Player identifier) as a cache entry.
    zp_suffix = re.compile(r'_[0-9a-fA-F]{8}_[0-9a-fA-F]{16}$')
    for d in cache_root.iterdir():
        if not d.is_dir() or d.name.startswith('_MediaCacheBuilder_'): continue
        mp=d/'folder.metadata'
        if mp.is_file() or zp_suffix.search(d.name):
            out.append((d,mp,read_metadata(mp)))
    return out

def find_unique_cache(nfo, data, entries, media_file=None, kind='movie'):
    tmdb=(data.get('tmdbid') or '').strip(); imdb=(data.get('imdbid') or '').strip()
    title=media_title(data); year=(data.get('year') or (data.get('premiered','')[:4])).strip()
    # Zoom Player's cache directory is based on the source video/show folder name,
    # followed by Zoom Player's own suffix/identifier. Match that human-readable
    # prefix first for movies and show-level NFOs; never synthesize or replace IDs.
    # Episode NFOs live in season folders, so this rule must not apply to episodes.
    if kind in ('movie', 'show'):
        source_folder = Path(nfo).parent.name
        source_norm = norm(source_folder)
        folder_hits = []
        for e in entries:
            dirname = e[0].name
            # Match the exact source folder text followed by Zoom Player's existing
            # two-part identifier. Preserve the suffix; never manufacture an ID.
            suffix_match = re.search(r'_[0-9a-fA-F]{8}_[0-9a-fA-F]{16}$', dirname)
            if suffix_match:
                human_name = dirname[:suffix_match.start()]
                if norm(human_name) == source_norm:
                    folder_hits.append(e)
        if len(folder_hits) == 1:
            return folder_hits[0], 'source video folder name + Zoom Player identifier'
        if len(folder_hits) > 1:
            return None, 'ambiguous source video folder name'
    # For episodes, exact source video filename is the strongest local key.
    # Episode NFOs may contain series-level IDs; do not let those override a filename match.
    if kind == 'episode' and media_file:
        stem=media_file.name
        hits=[e for e in entries if e[0].name.casefold().startswith(stem.casefold()+'_')]
        if len(hits)==1: return hits[0], 'exact episode video filename'
        if len(hits)>1: return None, 'ambiguous episode video filename'
    # Prefer a verified database ID already present in the cache if the exact
    # source-folder match was not available.
    if tmdb:
        hits=[e for e in entries if e[2].get('TheMovieDB_id','').strip()==tmdb]
        if len(hits)==1: return hits[0], 'TMDB ID'
        if len(hits)>1: return None, 'ambiguous TMDB ID'
    if imdb:
        hits=[e for e in entries if e[2].get('TheMovieDB_imdb_id','').strip().casefold()==imdb.casefold()]
        if len(hits)==1: return hits[0], 'IMDb ID'
        if len(hits)>1: return None, 'ambiguous IMDb ID'
    # Exact local filename prefix match against the cache directory's video filename portion.
    if media_file:
        stem=media_file.name
        hits=[e for e in entries if e[0].name.casefold().startswith(stem.casefold()+'_')]
        if len(hits)==1: return hits[0], 'video filename'
        if len(hits)>1: return None, 'ambiguous video filename'
    # Metadata title/year is a conservative fallback only when folder-name and
    # ID matching could not identify an existing entry uniquely.
    # Conservative metadata title/year fallback. Do not use title alone when a year is known.
    wanted=norm(title)
    hits=[]
    for e in entries:
        m=e[2]
        cache_title=m.get('TheMovieDB_title') or m.get('parsed_title','')
        cache_year=m.get('TheMovieDB_media_name_year','')
        if norm(cache_title)==wanted and (not year or not cache_year or cache_year==year): hits.append(e)
    if len(hits)==1: return hits[0], 'title/year'
    if len(hits)>1: return None, 'ambiguous title/year'
    return None, 'no matching existing cache entry'

def zoom_cache_group_id(entry):
    """Return Zoom Player's 8-hex group token from an actual suffixed cache folder."""
    match = re.search(r'_([0-9a-fA-F]{8})_[0-9a-fA-F]{16}$', entry[0].name)
    return match.group(1).upper() if match else None


def find_episode_cache_for_show(episode_nfo, video, library_root, entries):
    """Match an episode by video filename AND the owning show's Zoom Player group token.

    Zoom Player's cache metadata may contain no source path for episodes. In the observed
    cache naming scheme, the show's cache folder and its episode cache folders share the
    same 8-hex token. Use that token only after identifying the show's folder from the
    local tvshow.nfo. Never fall back to filename-only matching when duplicates exist.
    """
    root = Path(library_root).resolve()
    current = Path(episode_nfo).parent.resolve()
    show_dir = None
    while True:
        try:
            current.relative_to(root)
        except ValueError:
            break
        if (current / 'tvshow.nfo').is_file():
            show_dir = current
            break
        if current == root:
            break
        current = current.parent
    if show_dir is None:
        return None, 'no parent show folder with tvshow.nfo; cannot safely determine the show cache token'

    show_entries = []
    show_name = norm(show_dir.name)
    for entry in entries:
        token = zoom_cache_group_id(entry)
        if token and norm(entry[0].name.rsplit('_', 2)[0]) == show_name:
            show_entries.append((entry, token))
    if len(show_entries) != 1:
        if not show_entries:
            return None, f'no unique Zoom Player cache entry for show folder {show_dir.name}; cannot map its episode safely'
        return None, f'multiple Zoom Player cache entries match show folder {show_dir.name}; refusing ambiguous episode mapping'
    show_entry, group_id = show_entries[0]

    # Prefer an exact full video-filename match across the cache. Some Zoom Player
    # versions/builds appear to assign episode entries their own 8-hex token instead
    # of consistently reusing the show's token. Requiring the group token first can
    # therefore skip otherwise exact, uniquely identifiable episode entries. A unique
    # full filename (including extension) is a safe match; if duplicated, use the
    # owning show's token to disambiguate and otherwise skip conservatively.
    filename_prefix = Path(video).name.casefold() + '_'
    all_filename_hits = [
        entry for entry in entries
        if entry[0].name.casefold().startswith(filename_prefix)
        and zoom_cache_group_id(entry)
    ]
    if len(all_filename_hits) == 1:
        hit = all_filename_hits[0]
        hit_token = zoom_cache_group_id(hit)
        if hit_token == group_id:
            return hit, f'exact episode filename + owning show cache token {group_id} (show: {show_dir.name})'
        return hit, f'unique exact episode filename (Zoom Player entry token {hit_token} differs from show token {group_id}; show: {show_dir.name})'
    if len(all_filename_hits) > 1:
        episode_hits = [entry for entry in all_filename_hits if zoom_cache_group_id(entry) == group_id]
        if len(episode_hits) == 1:
            return episode_hits[0], f'exact episode filename disambiguated by owning show cache token {group_id} (show: {show_dir.name})'
        return None, f'multiple cache entries match exact episode filename; show-token disambiguation found {len(episode_hits)} candidates; refusing ambiguous match'
    return None, f'no Zoom Player cache entry matching exact video filename {Path(video).name}; confirm the TV Episodes category actually created an entry for this file'


def find_season_cache_for_show(season_num, show_data, entries, show_dir=None):
    """Find a real Zoom Player season entry using metadata or its episode-cache token link.

    Zoom Player season entries may have empty or generic metadata. First use an explicit
    show title when present. Otherwise, use the season's existing local episode filenames
    to find Zoom Player episode entries, then correlate the season folder's 8-hex token
    with those episode tokens. Exact token links win; a one-step token offset is accepted
    only when it uniquely identifies one season entry and one episode, matching the observed
    Charmed cache layout. No cache IDs are ever created.
    """
    show_title = media_title(show_data)
    wanted = norm(show_title)
    pattern = re.compile(r'^(\d+)_([0-9a-fA-F]{8})_([0-9a-fA-F]{16})$')
    season_entries = []
    for entry in entries:
        m = pattern.match(entry[0].name)
        if m and int(m.group(1)) == int(season_num):
            season_entries.append((entry, m.group(2).upper()))

    # Preferred route: explicit show identity in the season entry metadata.
    named_hits = []
    for entry, token in season_entries:
        meta = entry[2]
        possible_names = (meta.get('TheMovieDB_tv_show_name', ''),
                          meta.get('TheMovieDB_title', ''),
                          meta.get('parsed_title', ''),
                          meta.get('TheMovieDB_series_title', ''))
        if wanted and any(norm(value) == wanted for value in possible_names if value):
            named_hits.append((entry, token))
    if len(named_hits) == 1:
        return named_hits[0][0], f'season number {int(season_num)} + matching show title {show_title!r}'
    if len(named_hits) > 1:
        return None, f'multiple season {int(season_num)} cache entries identify show {show_title!r}; refusing ambiguous match'

    # Some Zoom Player season entries have no show title. Correlate with episode entries
    # from this exact local show and season using the existing filename-derived cache IDs.
    episode_tokens = []
    if show_dir is not None:
        show_dir = Path(show_dir)
        for video in show_dir.rglob('*'):
            if not video.is_file() or video.suffix.lower() not in VIDEO_EXTS:
                continue
            # Season folder number is the fallback for MediaElch NFOs that omit <season>.
            season_folder = video.parent.name
            folder_season = int(season_folder) if season_folder.isdigit() else None
            if folder_season is not None and folder_season != int(season_num):
                continue
            nfo = video.with_suffix('.nfo')
            nfo_season = None
            if nfo.is_file():
                try:
                    nfo_data = parse_nfo(nfo)
                    raw_season = (nfo_data.get('season') or '').strip()
                    if raw_season.isdigit():
                        nfo_season = int(raw_season)
                except Exception:
                    pass
            filename_match = re.search(r'(?i)S(\d{1,2})E\d{1,3}', video.name)
            inferred_season = nfo_season if nfo_season is not None else (int(filename_match.group(1)) if filename_match else folder_season)
            if inferred_season != int(season_num):
                continue
            prefix = video.name.casefold() + '_'
            hits = [e for e in entries if e[0].name.casefold().startswith(prefix) and zoom_cache_group_id(e)]
            if len(hits) == 1:
                episode_tokens.append((zoom_cache_group_id(hits[0]), video.name))

    if season_entries and episode_tokens:
        # Rank each season candidate by its closest episode token. Exact matches are
        # definitive; a distance of one is allowed only as a unique, explicit tie-break.
        ranked = []
        for entry, season_token in season_entries:
            token_value = int(season_token, 16)
            distance = min(abs(token_value - int(tok, 16)) for tok, _ in episode_tokens)
            nearest = [(tok, name) for tok, name in episode_tokens if abs(token_value - int(tok, 16)) == distance]
            ranked.append((distance, entry, season_token, nearest))
        best_distance = min(item[0] for item in ranked)
        best = [item for item in ranked if item[0] == best_distance]
        if best_distance == 0 and len(best) == 1:
            _, entry, token, nearest = best[0]
            return entry, f'season {int(season_num)} cache token {token} matches local episode cache token ({nearest[0][1]}) for show {show_title!r}'
        if best_distance == 1 and len(best) == 1 and len(best[0][3]) == 1:
            _, entry, token, nearest = best[0]
            # Ensure this token is not equally close to an unrelated season's episode
            # cache entry represented by the same local show/season candidate set.
            return entry, f'season {int(season_num)} cache token {token} uniquely correlates to {nearest[0][1]} (one-token offset; show {show_title!r})'

    if not season_entries:
        return None, f'no existing Zoom Player season {int(season_num)} cache folder was found'
    return None, f'could not safely associate a season {int(season_num)} cache folder with show {show_title!r} using its metadata or local episode cache IDs'


def season_poster_files(library_root):
    """Yield (show folder, show NFO, season number, season poster) for local seasonNN-poster images."""
    root = Path(library_root)
    for show_dir, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith('_MediaCacheBuilder_')]
        base = Path(show_dir)
        nfo = base / 'tvshow.nfo'
        if not nfo.is_file():
            continue
        for filename in files:
            match = re.match(r'^season(\d+)-poster\.(jpg|jpeg|png|webp)$', filename, re.I)
            if match:
                yield base, nfo, int(match.group(1)), base / filename


def local_artwork(folder, video=None, nfo=None):
    """Return artwork role -> local file, preferring MediaElch video-basename suffix files."""
    folder=Path(folder); found={}
    stems=[]
    if video: stems.append(video.stem)
    if nfo: stems.append(Path(nfo).stem)
    # NFO <art> paths may be absolute but only accept files inside the scanned library.
    if nfo:
        try:
            root=ET.parse(nfo).getroot()
            art=root.find('art')
            if art is not None:
                for role in ('poster','fanart','landscape','clearlogo','clearart','banner','discart','thumb'):
                    for el in art.findall(role):
                        raw=(el.text or '').strip()
                        if raw:
                            p=Path(raw)
                            if p.is_file(): found.setdefault(role,p)
                            break
        except Exception: pass
    for role in ART_SUFFIXES:
        if role in found: continue
        for stem in stems:
            for ext in ('.jpg','.jpeg','.png','.webp'):
                p=folder/f'{stem}-{role}{ext}'
                if p.is_file(): found[role]=p; break
            if role in found: break
    # Standard show artwork names.
    for role, names in {
        'poster':('poster.jpg','poster.png','poster.jpeg'),
        'fanart':('fanart.jpg','fanart.png','fanart.jpeg'),
        'landscape':('landscape.jpg','landscape.png'),
        'clearlogo':('clearlogo.png','clearlogo.jpg'),
        'clearart':('clearart.png','clearart.jpg'),
        'banner':('banner.jpg','banner.png'),
        'thumb':('thumb.jpg','thumb.png')}.items():
        if role not in found:
            for name in names:
                p=folder/name
                if p.is_file(): found[role]=p; break
    return found

def metadata_updates(data, old, kind='movie'):
    title=media_title(data)
    # Keep TV episode titles visibly sortable in Zoom Player's category list.
    # MediaElch NFOs normally store a bare episode title, while the user's
    # preferred display convention is SxxExx - Episode Title.
    display_title = title
    if kind == 'episode' and title:
        season_text = (data.get('season') or '').strip()
        episode_text = (data.get('episode') or '').strip()
        try:
            season_num = int(season_text)
            episode_num = int(episode_text)
        except (TypeError, ValueError):
            season_num = episode_num = None
        if season_num is not None and episode_num is not None and season_num >= 0 and episode_num >= 0:
            display_title = f'S{season_num:02d}E{episode_num:02d} - {title}'
    overview=data.get('plot') or data.get('outline')
    date=data.get('premiered') or data.get('releasedate')
    rating=data.get('rating')
    runtime=data.get('runtime')
    vals={
        # Preserve Zoom Player's own parsed title when present; populate it from the
        # local NFO title only if a newly created cache entry has no parsed_title yet.
        'parsed_title': display_title if kind == 'episode' else (old.get('parsed_title') or title or None),
        'TheMovieDB_title': display_title or None,
        'TheMovieDB_media_name_year': data.get('year') or (date[:4] if date else '') or None,
        'TheMovieDB_id': data.get('tmdbid') or None,
        'TheMovieDB_imdb_id': data.get('imdbid') or None,
        'TheMovieDB_tv_show_name': (data.get('showtitle') or '') if kind=='episode' else '',
        'TheMovieDB_release_date': date or None,
        'TheMovieDB_runtime': runtime or None,
        'TheMovieDB_rating': rating or None,
        'TheMovieDB_genre': genres_value(data.get('genres',[])),
        'TheMovieDB_overview': overview or None,
        'TheMovieDB_mpaa_rating': data.get('mpaa') or None,
    }
    # Keep cache technical data, parsed title, personal fields and playback history unchanged.
    if data.get('directors') or data.get('director'):
        d=data.get('directors') or [data.get('director')]
        olddir=old.get('TheMovieDB_director','')
        # IDs are retained only when the existing ID/name pair matches a local director name.
        ids={}
        for x in olddir.split(';'):
            if '|' in x:
                i,n=x.split('|',1); ids[norm(n)]=(i,n)
        parts=[]
        for name in d:
            if name and norm(name) in ids and ids[norm(name)][0].isdigit(): parts.append(f"{ids[norm(name)][0]}|{name}")
        vals['TheMovieDB_director']=';'.join(parts) if parts else None
    else:
        vals['TheMovieDB_director']=None
    vals['TheMovieDB_cast']=cast_value(data.get('actors',[]), old.get('TheMovieDB_cast',''))
    return vals

class BuilderApp:
    def __init__(self, root):
        self.root=root; root.title(APP_NAME); root.geometry('850x640'); root.minsize(760,560)
        self.q=queue.Queue(); self.stop_event=threading.Event(); self.worker=None; self.running=False
        self.library=tk.StringVar(value=''); self.cache=tk.StringVar(value=str(DEFAULT_CACHE)); self.mode=tk.StringVar(value='Movies only')
        self.run_refresh=tk.BooleanVar(value=True); self.zoom_exe=tk.StringVar(value=r'C:\Users\jason\Desktop\Launch-ZoomPlayer-reWASD.bat'); self.refresh_x=tk.StringVar(value='88.36'); self.refresh_y=tk.StringVar(value='98.33')
        self.status=tk.StringVar(value='Idle'); self.progress=tk.DoubleVar(value=0); self.eta=tk.StringVar(value='ETA: —')
        self._ui(); self.root.after(150,self._poll)
    @staticmethod
    def _detect_zoom_player():
        # Find common install locations without requiring the user to guess the path.
        candidates = [
            Path(os.environ.get('ProgramFiles', r'C:\Program Files')) / 'Zoom Player' / 'zplayer.exe',
            Path(os.environ.get('ProgramFiles', r'C:\Program Files')) / 'Inmatrix' / 'Zoom Player' / 'zplayer.exe',
            Path(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)')) / 'Zoom Player' / 'zplayer.exe',
            Path(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)')) / 'Inmatrix' / 'Zoom Player' / 'zplayer.exe',
            Path(os.environ.get('ProgramFiles', r'C:\Program Files')) / 'Zoom Player MAX' / 'zplayer.exe',
            Path(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)')) / 'Zoom Player MAX' / 'zplayer.exe',
        ]
        for candidate in candidates:
            if candidate.is_file(): return str(candidate)
        found = shutil.which('zplayer.exe') or shutil.which('zplayer')
        return str(Path(found).resolve()) if found else ''

    def browse_zoom_player(self):
        p = filedialog.askopenfilename(title='Select your Zoom Player launcher batch file', filetypes=[('Windows batch files', '*.bat;*.cmd'), ('All files', '*.*')])
        if p: self.zoom_exe.set(p)

    def _ui(self):
        pad={'padx':10,'pady':5}
        main=ttk.Frame(self.root,padding=12); main.pack(fill='both',expand=True)
        ttk.Label(main,text='Zoom Player MediaCache Builder',font=('Segoe UI',16,'bold')).pack(anchor='w')
        ttk.Label(main,text='Offline updater for local MediaElch NFO metadata and artwork. Updates real Zoom Player cache entries only; ambiguous matches are skipped.',wraplength=810).pack(anchor='w',pady=(3,10))
        f=ttk.Frame(main); f.pack(fill='x',**pad)
        ttk.Label(f,text='Library root (Movies or TV Shows):',width=29).pack(side='left')
        ttk.Entry(f,textvariable=self.library).pack(side='left',fill='x',expand=True,padx=5)
        ttk.Button(f,text='Browse…',command=self.browse_library).pack(side='left')
        f=ttk.Frame(main); f.pack(fill='x',**pad)
        ttk.Label(f,text='Zoom Player MediaCache:',width=29).pack(side='left')
        ttk.Entry(f,textvariable=self.cache).pack(side='left',fill='x',expand=True,padx=5)
        ttk.Button(f,text='Browse…',command=self.browse_cache).pack(side='left')
        f=ttk.Frame(main); f.pack(fill='x',**pad)
        ttk.Label(f,text='Library type:',width=29).pack(side='left')
        ttk.Combobox(f,textvariable=self.mode,state='readonly',values=['Auto-detect Movies and TV Shows','Movies only','TV Shows only'],width=36).pack(side='left')
        auto=ttk.LabelFrame(main,text='Zoom Player refresh sequence (Windows only)',padding=8); auto.pack(fill='x',padx=10,pady=5)
        ttk.Checkbutton(auto,text='Before rebuilding: create show-named MediaCache seed folder(s) first for TV (video-named seed for Movies), lock input, launch Zoom Player; refresh TV Shows, press Backspace, open TV Episodes, refresh, scroll 57 items in each TV category (115 for Movies), exit Zoom Player, then rescan and populate cache entries',variable=self.run_refresh).grid(row=0,column=0,columnspan=4,sticky='w')
        ttk.Label(auto,text='Refresh icon position (% of Zoom Player client area): X').grid(row=1,column=0,sticky='w',pady=3)
        ttk.Entry(auto,textvariable=self.refresh_x,width=5).grid(row=1,column=1,sticky='w')
        ttk.Label(auto,text='Y').grid(row=1,column=2,sticky='e')
        ttk.Entry(auto,textvariable=self.refresh_y,width=5).grid(row=1,column=3,sticky='w')
        ttk.Label(auto,text='Fullscreen 1280×720 client coordinates: Movies (133,134), TV Shows (374,128), TV Episodes (855,126), Refresh (1131,708). Physical mouse/keyboard input is locked only after the seed folder is prepared and is released when automation ends.',wraplength=780).grid(row=2,column=0,columnspan=4,sticky='w')
        ttk.Label(auto,text='Zoom Player launcher (.bat):').grid(row=3,column=0,sticky='w',pady=3)
        ttk.Entry(auto,textvariable=self.zoom_exe,width=58).grid(row=3,column=1,columnspan=2,sticky='ew',padx=(0,5))
        ttk.Button(auto,text='Browse…',command=self.browse_zoom_player).grid(row=3,column=3,sticky='w')
        auto.columnconfigure(1,weight=1)
        status=ttk.Frame(main); status.pack(fill='x',pady=(12,4))
        ttk.Label(status,text='Status:').pack(side='left')
        self.status_label=ttk.Label(status,textvariable=self.status,foreground='red',font=('Segoe UI',10,'bold')); self.status_label.pack(side='left',padx=5)
        ttk.Label(status,textvariable=self.eta).pack(side='right')
        self.bar=ttk.Progressbar(main,variable=self.progress,maximum=100,mode='determinate'); self.bar.pack(fill='x',pady=5)
        self.pct=ttk.Label(main,text='0%'); self.pct.pack(anchor='e')
        buttons=ttk.Frame(main); buttons.pack(fill='x',pady=8)
        self.start_btn=ttk.Button(buttons,text='Start',command=self.start); self.start_btn.pack(side='left')
        self.stop_btn=ttk.Button(buttons,text='Stop',command=self.stop,state='disabled'); self.stop_btn.pack(side='left',padx=8)
        ttk.Button(buttons,text='Open Cache Folder',command=self.open_cache).pack(side='right')
        ttk.Label(main,text='Activity / report preview').pack(anchor='w',pady=(8,2))
        self.log=tk.Text(main,height=18,wrap='word',state='disabled',font=('Consolas',9)); self.log.pack(fill='both',expand=True)
        self._log('Ready. Choose a library root and verify the MediaCache path before starting.')
    def _log(self,msg):
        self.log.configure(state='normal'); self.log.insert('end',msg+'\n'); self.log.see('end'); self.log.configure(state='disabled')
    def browse_library(self):
        p=filedialog.askdirectory(title='Choose Movies or TV Shows root')
        if p: self.library.set(p)
    def browse_cache(self):
        p=filedialog.askdirectory(title='Choose Zoom Player MediaCache folder',initialdir=self.cache.get() if Path(self.cache.get()).exists() else str(Path.home()))
        if p: self.cache.set(p)
    def open_cache(self):
        p=Path(self.cache.get())
        if p.exists() and sys.platform=='win32': os.startfile(str(p))
        elif not p.exists(): messagebox.showerror(APP_NAME,'The cache folder does not exist.')
    def start(self):
        lib=Path(self.library.get()); cache=Path(self.cache.get())
        if not lib.is_dir(): messagebox.showerror(APP_NAME,'Choose a valid library root folder.'); return
        if not cache.is_dir(): messagebox.showerror(APP_NAME,'The MediaCache folder does not exist. Check the path.'); return
        if lib.resolve()==cache.resolve() or cache.resolve() in lib.resolve().parents:
            messagebox.showerror(APP_NAME,'The library root and cache folder overlap. Choose the correct library root.'); return
        if self.run_refresh.get() and sys.platform!='win32': messagebox.showerror(APP_NAME,'The Zoom Player automation requires Windows.'); return
        if not messagebox.askyesno(APP_NAME,'Start the workflow?\n\nThe refresh sequence will run first (if enabled), then local MediaElch metadata/artwork will populate uniquely matched cache entries. Existing files are backed up. No online scraping is used.\n\nMouse/keyboard input is blocked only during the automation and always released on error.'):
            return
        self.stop_event.clear(); self.running=True; self.progress.set(0); self.pct.configure(text='0%'); self.status.set('Running'); self.status_label.configure(foreground='green'); self.eta.set('ETA: calculating…')
        self.start_btn.configure(state='disabled'); self.stop_btn.configure(state='normal'); self._log('\n--- Run started: '+datetime.now().strftime('%Y-%m-%d %H:%M:%S')+' ---')
        self.worker=threading.Thread(target=self._run,args=(lib,cache,self.mode.get(),self.run_refresh.get(),self.refresh_x.get(),self.refresh_y.get()),daemon=True); self.worker.start()
    def stop(self):
        self.stop_event.set(); self.status.set('Stopping…'); self._log('Stop requested; finishing current safe operation…')
    def _send(self,kind,*args): self.q.put((kind,args))
    def _poll(self):
        try:
            while True:
                kind,args=self.q.get_nowait()
                if kind=='log': self._log(args[0])
                elif kind=='progress':
                    # Accept both supported queue shapes: ('progress', (pct, eta))
                    # and ('progress', pct, eta). Older worker calls packed the pair
                    # into one argument, which caused the Tkinter callback ValueError.
                    if len(args) == 1 and isinstance(args[0], (tuple, list)) and len(args[0]) >= 2:
                        pct, eta = args[0][0], args[0][1]
                    elif len(args) >= 2:
                        pct, eta = args[0], args[1]
                    else:
                        self._log(f'Ignoring malformed progress update: {args!r}')
                        continue
                    pct = max(0.0, min(100.0, float(pct)))
                    eta = str(eta)
                    self.progress.set(pct)
                    self.pct.configure(text=f'{pct:.0f}%')
                    self.eta.set('ETA: ' + eta)
                elif kind=='done':
                    # New worker shape includes a state; accept older two-field messages too.
                    if len(args) == 3:
                        final_state, summary, report = args
                    else:
                        summary, report = args; final_state = 'Failed' if str(summary).lower().startswith(('failed:', 'run failed:')) else 'Completed'
                    self.running=False; self.start_btn.configure(state='normal'); self.stop_btn.configure(state='disabled')
                    self.status.set(final_state); self.eta.set('ETA: —'); self._log(summary); self._log('Report: '+str(report))
                    color = 'green' if final_state == 'Completed successfully' else ('#b36b00' if final_state in ('Completed with errors',) else ('#666666' if final_state == 'Stopped' else 'red'))
                    self.status_label.configure(foreground=color)
                    try:
                        if sys.platform == 'win32':
                            import winsound
                            winsound.MessageBeep(winsound.MB_ICONASTERISK if final_state == 'Completed successfully' else winsound.MB_ICONEXCLAMATION)
                    except Exception:
                        pass
                    if final_state == 'Completed successfully': messagebox.showinfo(APP_NAME,summary+'\n\nReport saved to:\n'+str(report))
                    elif final_state == 'Stopped': messagebox.showwarning(APP_NAME,summary+'\n\nReport saved to:\n'+str(report))
                    else: messagebox.showwarning(APP_NAME,summary+'\n\nReview the report for skipped or failed items:\n'+str(report))
        except queue.Empty: pass
        self.root.after(150,self._poll)
    def _run(self,lib,cache,mode,run_refresh=False,refresh_x='95',refresh_y='8'):
        started=time.time(); stamp=datetime.now().strftime('%Y%m%d_%H%M%S'); backup_root=cache/'_MediaCacheBuilder_Backups'/stamp
        report_path=cache/f'_MediaCacheBuilder_Report_{stamp}.txt'
        logs=[]; counts={'updated':0,'skipped':0,'failed':0,'backed':0}; total=0; done=0
        try:
            is_tv = mode == 'TV Shows only'
            if mode == 'Auto-detect Movies and TV Shows':
                is_tv = (lib/'tvshow.nfo').is_file() or any(lib.rglob('tvshow.nfo'))
            if run_refresh:
                category = 'TV Shows' if is_tv else 'Movies'
                self._send('log',f'Step 1/2: preparing seed and running the Zoom Player {category} refresh sequence…')
                self._prepare_and_refresh(lib, cache, float(refresh_x), float(refresh_y), is_tv=is_tv)
                self._send('log',f'Zoom Player {category} refresh sequence completed; rescanning MediaCache and starting local metadata/artwork repopulation.')
            # Important: this scan happens AFTER the refresh automation so it can see
            # the cache entries Zoom Player created during that refresh. The seed folder
            # is ignored unless Zoom Player has turned it into a real cache entry.
            entries=cache_entries(cache)
            if not entries: raise RuntimeError('No Zoom Player cache entries were found after the refresh. The seed folder alone is not a valid entry.')
            # Candidate NFOs are gathered locally. Prefer standard movie.nfo; use basename NFO fallback.
            candidates=[]
            is_tv=(mode=='TV Shows only')
            if mode=='Auto-detect Movies and TV Shows':
                is_tv=(lib/'tvshow.nfo').is_file() or any(lib.rglob('tvshow.nfo'))
            if mode=='Movies only': is_tv=False
            if is_tv:
                for showdir, dirs, files in os.walk(lib):
                    dirs[:]=[d for d in dirs if not d.startswith('_MediaCacheBuilder_')]
                    base=Path(showdir)
                    if 'tvshow.nfo' in files: candidates.append(('show',base,base/'tvshow.nfo',None))
                    for fn in files:
                        p=base/fn
                        if p.suffix.lower() in VIDEO_EXTS:
                            nfo=p.with_suffix('.nfo')
                            if nfo.is_file() and nfo.name.casefold()!='tvshow.nfo': candidates.append(('episode',base,nfo,p))
            else:
                for folder, dirs, files in os.walk(lib):
                    dirs[:]=[d for d in dirs if not d.startswith('_MediaCacheBuilder_')]
                    base=Path(folder); videos=[base/f for f in files if Path(f).suffix.lower() in VIDEO_EXTS]
                    if not videos: continue
                    # A folder represents one movie; only update once, using standard movie.nfo first.
                    nfo=None
                    for v in videos:
                        candidate=v.with_suffix('.nfo')
                        if candidate.is_file(): nfo=candidate; break
                    if nfo is None and (base/'movie.nfo').is_file(): nfo=base/'movie.nfo'
                    if nfo: candidates.append(('movie',base,nfo,videos[0]))
            # Deduplicate NFO processing paths.
            uniq=[]; seen=set()
            for x in candidates:
                k=(x[0],str(x[2]).casefold())
                if k not in seen: seen.add(k); uniq.append(x)
            candidates=uniq; total=max(1,len(candidates))
            self._send('log',f'Found {len(candidates)} local metadata item(s); {len(entries)} existing cache entries.')
            if not candidates:
                raise RuntimeError('No local NFO files matching the selected library type were found. Check the library root and that MediaElch NFO files are present.')
            for kind,folder,nfo,video in candidates:
                if self.stop_event.is_set(): break
                try:
                    data=parse_nfo(nfo)
                    if kind=='show':
                        # Show ID is best identity; video argument is absent.
                        match,why=find_unique_cache(nfo,data,entries,None,'show')
                    elif kind=='episode':
                        # First identify the owning show from the local folder/tvshow.nfo,
                        # then match the episode's exact filename AND the 8-hex Zoom Player
                        # cache token shared by that show's cache entry and its episodes.
                        # Do not fall back to filename-only matching: different shows can
                        # legitimately contain identically named episodes.
                        match,why=find_episode_cache_for_show(nfo,video,lib,entries)
                    else:
                        match,why=find_unique_cache(nfo,data,entries,video,'movie')
                    if not match:
                        counts['skipped']+=1; logs.append(f'SKIP [{kind}] {nfo}: {why}'); self._send('log',logs[-1])
                        done+=1
                        elapsed=time.time()-started; rate=elapsed/max(1,done); remaining=max(0,total-done); eta=remaining*rate
                        self._send('progress',min(100,done/total*100),self._fmt_eta(eta))
                        continue
                    cdir,metapath,old=match
                    # A show NFO should only target a show cache, not a media-file cache.
                    if kind=='show' and re.match(r'^\d+x\d+',cdir.name,re.I):
                        counts['skipped']+=1; logs.append(f'SKIP [show] {nfo}: matched an episode-like cache folder; refusing unsafe update.'); self._send('log',logs[-1])
                        done+=1
                        self._send('progress',min(100,done/total*100),self._fmt_eta(max(0,total-done)*(time.time()-started)/max(1,done)))
                        continue
                    updates=metadata_updates(data,old,'episode' if kind=='episode' else kind)
                    arts=local_artwork(folder,video,nfo)
                    changes=[]
                    for key,val in updates.items():
                        if val is not None and old.get(key)!=val: changes.append(key)
                    # Source has no value for stale online metadata: remove only known source fields, not technical/personal data.
                    for key in ('TheMovieDB_title','TheMovieDB_media_name_year','TheMovieDB_id','TheMovieDB_imdb_id','TheMovieDB_tv_show_name','TheMovieDB_release_date','TheMovieDB_runtime','TheMovieDB_rating','TheMovieDB_genre','TheMovieDB_overview','TheMovieDB_mpaa_rating','TheMovieDB_director','TheMovieDB_cast'):
                        if key not in updates: updates[key]=None
                    # Don't remove a value if source is absent for core identifiers? Stale source values must not survive.
                    art_targets=[]
                    if 'poster' in arts:
                        art_targets += [(arts['poster'],cdir/'folder.jpg'),(arts['poster'],cdir/'poster_src.jpg')]
                    if 'fanart' in arts: art_targets.append((arts['fanart'],cdir/'backdrop_src.jpg'))
                    # Also preserve optional local artwork roles when present. Keep their
                    # original extension instead of pretending PNG/WebP data is JPEG.
                    for role, target_stem in (('landscape','landscape_src'),('clearlogo','clearlogo_src'),('clearart','clearart_src'),('banner','banner_src'),('discart','discart_src')):
                        if role in arts:
                            art_targets.append((arts[role], cdir / f'{target_stem}{arts[role].suffix.lower()}'))
                    # Episode stills are optional; never substitute poster art for an episode frame.
                    if kind=='episode' and 'thumb' in arts: art_targets.append((arts['thumb'],cdir/f'still_src{arts['thumb'].suffix.lower()}'))
                    targets=[metapath]+[dst for src,dst in art_targets if not (src.resolve()==dst.resolve())]
                    # Backup all targets before writing/copying; no unrelated cache files are touched.
                    for target in targets:
                        if target.exists():
                            rel=target.relative_to(cache)
                            dest=backup_root/rel
                            safe_copy(target,dest); counts['backed']+=1
                    write_metadata(metapath,updates)
                    for src,dst in art_targets:
                        if src.resolve()==dst.resolve(): continue
                        safe_copy(src,dst)
                    counts['updated']+=1
                    art_summary = f'{len(art_targets)} artwork file(s) copied' if art_targets else 'no local artwork found; existing artwork left unchanged'
                    msg=f'UPDATED [{kind}] {nfo} -> {cdir.name} (match: {why}; {art_summary})'
                    logs.append(msg); self._send('log',msg)
                except Exception as e:
                    counts['failed']+=1; msg=f'FAIL [{kind}] {nfo}: {e}'; logs.append(msg); self._send('log',msg)
                done+=1
                elapsed=time.time()-started; rate=elapsed/max(1,done); remaining=max(0,total-done); eta=remaining*rate
                self._send('progress',min(100,done/total*100),self._fmt_eta(eta))
            # Season posters are separate from show/episode NFO processing. Copy them only
            # to a uniquely identified real Zoom Player season cache entry; never create IDs.
            if is_tv and not self.stop_event.is_set():
                season_items = list(season_poster_files(lib))
                if season_items:
                    self._send('log', f'Found {len(season_items)} local season poster(s) matching seasonNN-poster.jpg/png/webp.')
                for show_dir, show_nfo, season_num, poster in season_items:
                    if self.stop_event.is_set():
                        break
                    try:
                        show_data = parse_nfo(show_nfo)
                        match, why = find_season_cache_for_show(season_num, show_data, entries, show_dir)
                        if not match:
                            counts['skipped'] += 1
                            msg = f'SKIP [season artwork] {poster}: {why}'
                            logs.append(msg); self._send('log', msg)
                            continue
                        cdir, metapath, old = match
                        targets = [cdir / 'folder.jpg', cdir / 'poster_src.jpg']
                        for target in targets:
                            if target.exists():
                                rel = target.relative_to(cache)
                                safe_copy(target, backup_root / rel)
                                counts['backed'] += 1
                        for target in targets:
                            if poster.resolve() != target.resolve():
                                safe_copy(poster, target)
                        counts['updated'] += 1
                        msg = (f'UPDATED [season artwork] {poster} -> {cdir.name} '
                               f'(season {season_num}; {why}; wrote folder.jpg and poster_src.jpg)')
                        logs.append(msg); self._send('log', msg)
                    except Exception as e:
                        counts['failed'] += 1
                        msg = f'FAIL [season artwork] {poster}: {e}'
                        logs.append(msg); self._send('log', msg)
            stopped = self.stop_event.is_set()
            if stopped:
                logs.append('Run stopped by user; unprocessed items were not attempted.')
                final_state = 'Stopped'
            elif counts['failed']:
                final_state = 'Completed with errors'
            elif counts['skipped']:
                final_state = 'Completed with errors'
            else:
                final_state = 'Completed successfully'
            summary=f"{final_state}: {counts['updated']} updated, {counts['skipped']} skipped, {counts['failed']} failed; {counts['backed']} backup file(s) created."
            report_path.write_text(APP_NAME+' report\nCreated: '+datetime.now().isoformat(timespec='seconds')+'\nStatus: '+final_state+'\nLibrary: '+str(lib)+'\nCache: '+str(cache)+'\n\n'+summary+'\n\n'+'\n'.join(logs)+'\n',encoding='utf-8')
            if not stopped:
                self._send('progress',100,'—')
            self._send('done',final_state,summary,report_path)
        except Exception as e:
            msg=f'Failed: {e}'
            try: report_path.write_text(APP_NAME+' report\nStatus: Failed\n\n'+msg+'\n\n'+traceback.format_exc(),encoding='utf-8')
            except Exception: pass
            self._send('log',msg); self._send('done','Failed',msg,report_path)
    def _prepare_and_refresh(self, lib, cache, refresh_x, refresh_y, is_tv=False):
        """Prepare TV show-named seed folders (or a movie video-named seed), then let Zoom Player create real cache entries.

        Zoom Player must create its own suffixed cache entry. The builder only updates
        those real entries after the full refresh and after Zoom Player exits; it never
        synthesizes Zoom Player identifiers. Input is blocked using BlockInput; injected
        SendInput events remain available to this process.
        """
        if sys.platform != 'win32': raise RuntimeError('Zoom Player automation is Windows-only.')
        if not (0 <= refresh_x <= 100 and 0 <= refresh_y <= 100): raise RuntimeError('Refresh X/Y must be between 0 and 100 percent.')
        # The selected path is the library root. Movies normally sit one folder
        # below it; TV episodes sit in season subfolders, so choose an episode NFO
        # recursively and prefer a video with a matching local NFO.
        def choose_video(folder):
            videos = sorted((p for p in folder.iterdir() if p.is_file() and p.suffix.casefold() in VIDEO_EXTS), key=lambda p: p.name.casefold())
            matched = [v for v in videos if v.with_suffix('.nfo').is_file()]
            if len(matched) == 1: return matched[0]
            if len(videos) == 1: return videos[0]
            return None

        movie_file = None
        tv_seed_folders = []
        if is_tv:
            # TV cache seeding is show-level, not episode-level: create the show-named
            # seed folder(s) before launching Zoom Player so the show pass runs first.
            show_dirs = []
            if (lib / 'tvshow.nfo').is_file():
                show_dirs.append(lib)
            else:
                for candidate in sorted(lib.rglob('tvshow.nfo'), key=lambda p: str(p).casefold()):
                    if candidate.is_file():
                        show_dirs.append(candidate.parent)
            # Ignore builder backup/report folders and de-duplicate resolved show paths.
            unique_show_dirs = []
            seen_show_dirs = set()
            for show_dir in show_dirs:
                if any(part.startswith('_MediaCacheBuilder_') for part in show_dir.parts):
                    continue
                key = str(show_dir.resolve()).casefold()
                if key not in seen_show_dirs:
                    seen_show_dirs.add(key); unique_show_dirs.append(show_dir)
            if not unique_show_dirs:
                raise RuntimeError(f'Cannot find any show folders containing tvshow.nfo under {lib}. No MediaCache seed was created.')
            for show_dir in unique_show_dirs:
                seed = cache / show_dir.name
                if seed.exists() and not seed.is_dir():
                    raise RuntimeError(f'Cannot create the show MediaCache seed because a file exists at: {seed}')
                seed.mkdir(parents=True, exist_ok=True)
                tv_seed_folders.append(seed)
                self._send('log', f'TV show seed prepared before Zoom Player launch: {seed}')
            self._send('log', f'Step 0 complete: prepared {len(tv_seed_folders)} show-named MediaCache seed folder(s) before opening Zoom Player.')
        else:
            movie_file = choose_video(lib)
            if movie_file is None:
                child_candidates = []
                for child in sorted((p for p in lib.iterdir() if p.is_dir() and not p.name.startswith('_MediaCacheBuilder_')), key=lambda p: p.name.casefold()):
                    chosen = choose_video(child)
                    if chosen is not None:
                        child_candidates.append((child, chosen))
                if not child_candidates:
                    raise RuntimeError(
                        f'Cannot find a safe sample movie video in {lib} or its immediate movie subfolders. Keep each movie in its own folder with a local NFO beside its video, then try again.'
                    )
                sample_folder, movie_file = child_candidates[0]
                self._send('log', f'Library root detected: {lib}')
                self._send('log', f'Using sample movie folder for refresh seed: {sample_folder}')
        if not is_tv:
            self._send('log', f'Selected source video: {movie_file.name}')
            # Create/confirm the movie video-named seed BEFORE locking physical input
            # and launching Zoom Player. It is not treated as a real cache entry unless
            # Zoom Player adds its own suffix or metadata.
            movie_cache_folder = cache / movie_file.name
            if movie_cache_folder.exists() and not movie_cache_folder.is_dir():
                raise RuntimeError(f'Cannot create the seed folder because a file already exists at: {movie_cache_folder}')
            movie_cache_folder.mkdir(parents=True, exist_ok=True)
            self._send('log', f'Step 0 complete: created/confirmed video-named movie seed folder before automation: {movie_cache_folder}')
        self._send('log', 'Next: lock physical input, launch Zoom Player, run the required category refresh sequence, exit Zoom Player, then rescan MediaCache and populate Zoom Player-created entries.')
        user32 = ctypes.windll.user32
        # Declare pointer-sized HWND signatures explicitly. Without argtypes,
        # ctypes may treat HWND values as 32-bit integers on 64-bit Windows,
        # causing GetClientRect/GetWindowRect/ClientToScreen to fail.
        user32.GetClientRect.argtypes = [ctypes.wintypes.HWND, ctypes.POINTER(ctypes.wintypes.RECT)]
        user32.GetClientRect.restype = ctypes.wintypes.BOOL
        user32.GetWindowRect.argtypes = [ctypes.wintypes.HWND, ctypes.POINTER(ctypes.wintypes.RECT)]
        user32.GetWindowRect.restype = ctypes.wintypes.BOOL
        user32.ClientToScreen.argtypes = [ctypes.wintypes.HWND, ctypes.POINTER(ctypes.wintypes.POINT)]
        user32.ClientToScreen.restype = ctypes.wintypes.BOOL
        user32.IsZoomed.argtypes = [ctypes.wintypes.HWND]
        user32.IsZoomed.restype = ctypes.wintypes.BOOL
        user32.GetWindowThreadProcessId.argtypes = [ctypes.wintypes.HWND, ctypes.POINTER(ctypes.wintypes.DWORD)]
        user32.GetWindowThreadProcessId.restype = ctypes.wintypes.DWORD

        def zoom_client_size(hwnd):
            # Prefer the real client area. Explicit pointer-sized API signatures
            # above avoid HWND truncation on 64-bit Windows.
            rect = ctypes.wintypes.RECT()
            try:
                if user32.GetClientRect(hwnd, ctypes.byref(rect)):
                    width, height = rect.right - rect.left, rect.bottom - rect.top
                    if width >= 200 and height >= 150:
                        return width, height
            except Exception:
                pass
            # The measured windowed client area is 418x241. Use the known
            # fullscreen reference only when Windows says the window is zoomed.
            try:
                if user32.IsZoomed(hwnd):
                    return 1280, 720
            except Exception:
                pass
            # A valid window rectangle is a useful fallback for a normal window.
            win = ctypes.wintypes.RECT()
            try:
                if user32.GetWindowRect(hwnd, ctypes.byref(win)):
                    width, height = win.right - win.left, win.bottom - win.top
                    if width >= 200 and height >= 150:
                        # The Window Spy client area was 418x241 while its
                        # outer window was 419x241; clamp the measured border.
                        return min(width, 418), min(height, 241) if height <= 241 else height
            except Exception:
                pass
            # Last-resort windowed reference, based on the user's Window Spy
            # measurement. Foreground-process verification remains mandatory.
            return 418, 241

        kernel32 = ctypes.windll.kernel32
        kernel32.OpenProcess.argtypes = [ctypes.wintypes.DWORD, ctypes.wintypes.BOOL, ctypes.wintypes.DWORD]
        kernel32.OpenProcess.restype = ctypes.wintypes.HANDLE
        kernel32.QueryFullProcessImageNameW.argtypes = [ctypes.wintypes.HANDLE, ctypes.wintypes.DWORD, ctypes.wintypes.LPWSTR, ctypes.POINTER(ctypes.wintypes.DWORD)]
        kernel32.QueryFullProcessImageNameW.restype = ctypes.wintypes.BOOL
        kernel32.CloseHandle.argtypes = [ctypes.wintypes.HANDLE]
        kernel32.CloseHandle.restype = ctypes.wintypes.BOOL
        kernel32.WaitForSingleObject.argtypes = [ctypes.wintypes.HANDLE, ctypes.wintypes.DWORD]
        kernel32.WaitForSingleObject.restype = ctypes.wintypes.DWORD
        INPUT_MOUSE, INPUT_KEYBOARD = 0, 1
        KEYEVENTF_KEYUP, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP = 0x0002, 0x0002, 0x0004
        VK_RETURN, VK_DOWN, VK_MENU, VK_X, VK_ESCAPE, VK_BACK = 0x0D, 0x28, 0x12, 0x58, 0x1B, 0x08
        ULONG_PTR = ctypes.c_ulonglong if ctypes.sizeof(ctypes.c_void_p)==8 else ctypes.c_ulong
        class MOUSEINPUT(ctypes.Structure): _fields_=[('dx',ctypes.c_long),('dy',ctypes.c_long),('mouseData',ctypes.c_ulong),('dwFlags',ctypes.c_ulong),('time',ctypes.c_ulong),('dwExtraInfo',ULONG_PTR)]
        class KEYBDINPUT(ctypes.Structure): _fields_=[('wVk',ctypes.c_ushort),('wScan',ctypes.c_ushort),('dwFlags',ctypes.c_ulong),('time',ctypes.c_ulong),('dwExtraInfo',ULONG_PTR)]
        class INPUT_UNION(ctypes.Union): _fields_=[('mi',MOUSEINPUT),('ki',KEYBDINPUT)]
        class INPUT(ctypes.Structure): _fields_=[('type',ctypes.c_ulong),('union',INPUT_UNION)]
        def key(vk, up=False):
            i=INPUT(); i.type=INPUT_KEYBOARD; i.union.ki=KEYBDINPUT(vk,0,KEYEVENTF_KEYUP if up else 0,0,0); user32.SendInput(1,ctypes.byref(i),ctypes.sizeof(i))
        def click(x,y):
            user32.SetCursorPos(int(x),int(y)); time.sleep(.15)
            for flags in (MOUSEEVENTF_LEFTDOWN,MOUSEEVENTF_LEFTUP):
                i=INPUT(); i.type=INPUT_MOUSE; i.union.mi=MOUSEINPUT(0,0,0,flags,0,0); user32.SendInput(1,ctypes.byref(i),ctypes.sizeof(i))
        blocked=False
        try:
            if not user32.BlockInput(True): raise RuntimeError('Windows could not lock physical input. Try running the app as administrator.')
            blocked=True; self._send('log','Physical mouse/keyboard input locked.')
            launcher=self.zoom_exe.get().strip() if hasattr(self,'zoom_exe') else r'C:\Users\jason\Desktop\Launch-ZoomPlayer-reWASD.bat'
            launcher_path=Path(launcher).expanduser()
            if not launcher_path.is_file():
                raise FileNotFoundError(f'Zoom Player launcher batch file was not found: {launcher_path}\nCheck the “Zoom Player launcher (.bat)” field. The refresh sequence stopped before launching Zoom Player.')
            launcher=str(launcher_path.resolve())
            self._send('log',f'Launching Zoom Player using your reWASD batch file: {launcher}')
            # Batch files must be invoked through cmd.exe; this preserves the user's existing reWASD launch workflow.
            subprocess.Popen(['cmd.exe', '/c', launcher], shell=False, cwd=str(Path(launcher).parent))

            # Identify Zoom Player by owning process, then choose its LARGEST visible
            # top-level window. EnumWindows order is not guaranteed: choosing the first
            # zplayer.exe window selected a 418x241 auxiliary/windowed surface even while
            # the actual fullscreen UI was 1280x720. Never use title-only matching.
            found_windows = []
            enum_proc_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.wintypes.HWND, ctypes.wintypes.LPARAM)
            PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
            def window_process_image(hwnd):
                pid = ctypes.wintypes.DWORD()
                user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
                if not pid.value:
                    return ''
                hp = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid.value)
                if not hp:
                    return ''
                try:
                    size = ctypes.wintypes.DWORD(32768)
                    buf = ctypes.create_unicode_buffer(size.value)
                    if kernel32.QueryFullProcessImageNameW(hp, 0, buf, ctypes.byref(size)):
                        return buf.value
                    return ''
                finally:
                    kernel32.CloseHandle(hp)
            def find_zoom_windows(hwnd, lparam):
                if not user32.IsWindowVisible(hwnd):
                    return True
                image_path = window_process_image(hwnd)
                if image_path and Path(image_path).name.casefold() == 'zplayer.exe':
                    r = ctypes.wintypes.RECT()
                    if user32.GetClientRect(hwnd, ctypes.byref(r)):
                        w, h = r.right-r.left, r.bottom-r.top
                    else:
                        w, h = 0, 0
                    found_windows.append((w*h, w, h, hwnd))
                return True
            enum_proc = enum_proc_type(find_zoom_windows)
            hwnd = 0
            deadline = time.monotonic() + 30.0
            while time.monotonic() < deadline:
                found_windows.clear()
                user32.EnumWindows(enum_proc, 0)
                if found_windows:
                    # Prefer a real fullscreen-sized client area when one exists;
                    # otherwise choose the largest candidate and fail safely below.
                    found_windows.sort(key=lambda item: (item[1] >= 900 and item[2] >= 500, item[0]), reverse=True)
                    _, selected_w, selected_h, hwnd = found_windows[0]
                    if selected_w >= 200 and selected_h >= 150:
                        break
                    hwnd = 0
                time.sleep(.25)
            if not hwnd:
                raise RuntimeError('Could not find a usable visible window owned by zplayer.exe within 30 seconds. No mouse clicks or keyboard presses were sent.')
            self._send('log', f'Found {len(found_windows)} visible Zoom Player window(s); selected largest client area {selected_w}×{selected_h}.')
            zoom_pid = ctypes.wintypes.DWORD(0)
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(zoom_pid))
            if not zoom_pid.value:
                raise RuntimeError('Could not identify the selected Zoom Player process; stopping before automation.')
            # The batch launcher can also open a browser, which may steal focus.
            # Re-activate the real zplayer.exe window whenever needed. Enter is
            # posted directly to this HWND so it cannot be delivered to a browser.
            def foreground_is_zoom_player():
                # Zoom Player can activate a separate top-level library/dialog
                # window in the same process. Comparing HWNDs alone falsely
                # reports lost focus in that case; compare owning process IDs.
                fg = user32.GetForegroundWindow()
                if not fg:
                    return False
                fg_pid = ctypes.wintypes.DWORD(0)
                user32.GetWindowThreadProcessId(fg, ctypes.byref(fg_pid))
                zoom_pid = ctypes.wintypes.DWORD(0)
                user32.GetWindowThreadProcessId(hwnd, ctypes.byref(zoom_pid))
                return fg_pid.value != 0 and fg_pid.value == zoom_pid.value

            def focus_zoom_window():
                # IMPORTANT: SW_RESTORE unmaximizes a maximized Zoom Player window.
                # That was causing the reported 418x241 client area even though the
                # user launched Zoom Player fullscreen. Only restore if minimized;
                # otherwise leave the existing fullscreen/maximized state untouched.
                if user32.IsIconic(hwnd):
                    user32.ShowWindow(hwnd, 9)  # SW_RESTORE only when minimized
                current_tid = kernel32.GetCurrentThreadId()
                zoom_tid = user32.GetWindowThreadProcessId(hwnd, None)
                fg_hwnd = user32.GetForegroundWindow()
                fg_tid = user32.GetWindowThreadProcessId(fg_hwnd, None) if fg_hwnd else 0
                attached_tids = []
                try:
                    # Attach to both the target and current foreground input
                    # queues while activating. This is more reliable when the
                    # launcher batch/browser was the previous foreground app.
                    for tid in (zoom_tid, fg_tid):
                        if tid and tid != current_tid and tid not in attached_tids:
                            if user32.AttachThreadInput(current_tid, tid, True):
                                attached_tids.append(tid)
                    user32.BringWindowToTop(hwnd)
                    user32.SetForegroundWindow(hwnd)
                    user32.SetActiveWindow(hwnd)
                    user32.SetFocus(hwnd)
                    deadline = time.monotonic() + 2.0
                    while time.monotonic() < deadline:
                        if foreground_is_zoom_player():
                            return True
                        user32.BringWindowToTop(hwnd)
                        user32.SetForegroundWindow(hwnd)
                        time.sleep(.15)
                    return foreground_is_zoom_player()
                finally:
                    for tid in reversed(attached_tids):
                        user32.AttachThreadInput(current_tid, tid, False)

            if not focus_zoom_window():
                raise RuntimeError('Could not activate the Zoom Player window after launching your batch file. No keys or clicks were sent to the browser.')

            # All category coordinates below are confirmed by the user's Window Spy at 1280×720.
            # TV workflow uses two categories: TV Shows first to create show cache entries,
            # then TV Episodes to create the individual episode cache entries.
            def refresh_category(category_name, category_x, category_y, down_presses):
                if not focus_zoom_window():
                    raise RuntimeError(f'Could not activate Zoom Player before clicking {category_name}. No mouse click was sent.')
                measured_width, measured_height = zoom_client_size(hwnd)
                self._send('log', f'Zoom Player reported client area: {measured_width}×{measured_height}; using confirmed fullscreen 1280×720 coordinates.')
                category_pt=ctypes.wintypes.POINT(category_x,category_y)
                if not user32.ClientToScreen(hwnd,ctypes.byref(category_pt)):
                    raise RuntimeError(f'Could not translate {category_name} category coordinates to screen coordinates.')
                if not foreground_is_zoom_player():
                    raise RuntimeError(f'Zoom Player is not the foreground application. Stopping before the {category_name} click to protect the browser.')
                self._send('log',f'Selecting {category_name} at confirmed client ({category_x},{category_y}); measured client area {measured_width}×{measured_height}.')
                click(category_pt.x,category_pt.y)
                self._send('log',f'{category_name} tile selected; waiting 0.6 seconds before the second click to open it…')
                time.sleep(0.6)
                if not focus_zoom_window():
                    raise RuntimeError(f'Zoom Player lost foreground focus after selecting {category_name}. Stopping before the opening click.')
                click(category_pt.x,category_pt.y)
                self._send('log',f'Opened {category_name}; waiting 2.5 seconds before clicking refresh…')
                time.sleep(2.5)
                if not focus_zoom_window():
                    raise RuntimeError(f'Zoom Player could not be brought back to the foreground after opening {category_name}. Stopping before refresh and Down presses to protect the browser.')
                width, height = zoom_client_size(hwnd)
                # Convert the configured percentage to the current client dimensions.
                # Defaults 88.36% / 98.33% yield the user's confirmed fullscreen
                # refresh location (1131, 708) at 1280×720.
                refresh_client_x = round(width * refresh_x / 100.0)
                refresh_client_y = round(height * refresh_y / 100.0)
                pt=ctypes.wintypes.POINT(refresh_client_x, refresh_client_y)
                if not user32.ClientToScreen(hwnd,ctypes.byref(pt)):
                    raise RuntimeError('Could not translate forced fullscreen refresh coordinates to screen coordinates.')
                if not foreground_is_zoom_player():
                    raise RuntimeError(f'Zoom Player is not the foreground application. Stopping before clicking refresh in {category_name}.')
                self._send('log',f'Clicking refresh in {category_name} at confirmed fullscreen client ({refresh_client_x}, {refresh_client_y}); reported client area is {width}×{height}.')
                click(pt.x,pt.y)
                self._send('log',f'Waiting 5 seconds for {category_name} refresh to finish before scrolling…')
                time.sleep(5.0)
                if not foreground_is_zoom_player():
                    raise RuntimeError(f'Zoom Player lost foreground application focus after refreshing {category_name}. Stopping before Down presses so they cannot go to the browser.')
                press_interval=0.125
                self._send('log',f'Scrolling through {down_presses} {category_name} items: one Down press every {press_interval * 1000:.0f} milliseconds (about {down_presses * press_interval:.1f} seconds total).')
                for i in range(down_presses):
                    key(VK_DOWN)
                    time.sleep(0.025)
                    key(VK_DOWN, True)
                    if (i + 1) % 10 == 0 or i + 1 == down_presses:
                        self._send('log', f'{category_name} displayed-item scan: {i + 1}/{down_presses} Down presses completed.')
                    time.sleep(press_interval)
                self._send('log',f'All {down_presses} Down presses complete in {category_name}; waiting 3 seconds for the final displayed item to finish processing…')
                time.sleep(3.0)

            if is_tv:
                # First pass: Zoom Player's show category creates the show-level cache entries.
                refresh_category('TV Shows', 374, 128, 57)
                if not focus_zoom_window():
                    raise RuntimeError('Zoom Player lost foreground focus after the TV Shows scan; cannot safely return to categories.')
                self._send('log','TV Shows show-level scan complete. Pressing Backspace once to return from the TV Shows page to the category tiles before opening TV Episodes…')
                key(VK_BACK); key(VK_BACK, True)
                time.sleep(1.5)
                if not focus_zoom_window():
                    raise RuntimeError('Could not reactivate Zoom Player after returning from TV Shows; stopping before the TV Episodes click.')
                # Second pass: flat TV Episodes category creates individual episode cache entries.
                refresh_category('TV Episodes', 855, 126, 57)
                self._send('log','TV Episodes scan complete. Exiting Zoom Player with Alt+X before rescanning MediaCache…')
                if not focus_zoom_window():
                    raise RuntimeError('Could not reactivate Zoom Player to exit after the TV Episodes scan; refusing to start cache writes while Zoom Player is open.')
                key(VK_MENU); key(VK_X); key(VK_X, True); key(VK_MENU, True)
                # Wait for the actual zplayer.exe process to exit before touching cache files.
                SYNCHRONIZE = 0x00100000
                process_handle = kernel32.OpenProcess(SYNCHRONIZE, False, zoom_pid.value)
                if process_handle:
                    try:
                        wait_result = kernel32.WaitForSingleObject(process_handle, 15000)
                    finally:
                        kernel32.CloseHandle(process_handle)
                    if wait_result != 0:
                        raise RuntimeError('Zoom Player did not exit within 15 seconds after Alt+X. Cache writes were stopped to avoid changing files while Zoom Player may still be using them.')
                else:
                    # If Windows does not grant a wait handle, use the selected window as a safe fallback.
                    deadline = time.monotonic() + 15.0
                    while user32.IsWindow(hwnd) and time.monotonic() < deadline:
                        time.sleep(0.25)
                    if user32.IsWindow(hwnd):
                        raise RuntimeError('Zoom Player window is still present 15 seconds after Alt+X. Cache writes were stopped.')
                self._send('log','Zoom Player process exited. The builder will now rescan MediaCache and populate matching local NFOs/artwork.')
            else:
                refresh_category('Movies', 133, 134, 115)
                key(VK_MENU); key(VK_X); key(VK_X,True); key(VK_MENU,True)
                time.sleep(1.2)
        finally:
            if blocked:
                user32.BlockInput(False)
                self._send('log','Physical mouse/keyboard input unlocked.')

    @staticmethod
    def _fmt_eta(seconds):
        if seconds<60: return f'{int(seconds)} sec'
        if seconds<3600: return f'{int(seconds//60)} min {int(seconds%60)} sec'
        return f'{int(seconds//3600)} hr {int((seconds%3600)//60)} min'

def ensure_admin():
    """Relaunch elevated when needed so Windows can allow BlockInput."""
    if os.name != 'nt':
        return
    try:
        if ctypes.windll.shell32.IsUserAnAdmin():
            return
    except Exception:
        pass
    script = str(Path(__file__).resolve())
    params = subprocess.list2cmdline([script, *sys.argv[1:]])
    try:
        result = ctypes.windll.shell32.ShellExecuteW(None, 'runas', sys.executable, params, str(Path(script).parent), 1)
    except Exception as exc:
        messagebox.showerror(APP_NAME, f'This app needs administrator permission to lock physical input.\n\nWindows could not request elevation: {exc}')
        raise SystemExit(1)
    if result <= 32:
        try:
            messagebox.showerror(APP_NAME, 'Windows did not start the elevated copy. Right-click the app launcher and choose Run as administrator.')
        except Exception:
            pass
    raise SystemExit(0)


def main():
    # Physical input locking requires elevation on many Windows configurations.
    # Request it automatically so users do not need a Compatibility tab.
    if os.name == 'nt':
        # Create a temporary hidden Tk root only if an elevation error needs to be shown.
        ensure_admin()
    root=tk.Tk();
    try:
        style=ttk.Style(root)
        if 'vista' in style.theme_names(): style.theme_use('vista')
    except Exception: pass
    BuilderApp(root); root.mainloop()

if __name__=='__main__': main()
