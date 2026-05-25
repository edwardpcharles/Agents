"""
Microsoft Learn DAX documentation search utility.

This script queries Microsoft Learn search endpoints and returns ranked DAX-related
results suitable for agent evidence packages.

Usage examples:
  python search_learn_dax_docs.py "calculate filter context"
  python search_learn_dax_docs.py "time intelligence" --top 8 --json
"""

import argparse
import json
import time
from difflib import SequenceMatcher
from typing import Dict, List
from urllib.parse import quote

import requests


LEARN_SEARCH_API = "https://learn.microsoft.com/api/search"
LEARN_DAX_TOC = "https://learn.microsoft.com/en-us/dax/toc.json"


def _safe_get(url: str, timeout: int = 20) -> Dict:
    # Network fetch block
    max_attempts = 3
    retry_statuses = {500, 502, 503, 504}

    for attempt in range(1, max_attempts + 1):
        try:
            response = requests.get(
                url,
                timeout=timeout,
                headers={
                    "User-Agent": "dax-optimize-skill/1.0 (+https://learn.microsoft.com/dax)"
                },
            )
            response.raise_for_status()
            return response.json()
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError):
            if attempt == max_attempts:
                raise
            time.sleep(0.5 * attempt)
        except requests.exceptions.HTTPError as ex:
            status_code = ex.response.status_code if ex.response is not None else None
            if status_code not in retry_statuses or attempt == max_attempts:
                raise
            time.sleep(0.5 * attempt)


def _text_score(query: str, title: str, description: str, url: str) -> float:
    # Ranking score block
    query_norm = query.lower().strip()
    haystack = f"{title} {description} {url}".lower()
    similarity = SequenceMatcher(None, query_norm, haystack).ratio() * 100.0

    keyword_bonus = 0.0
    for token in query_norm.split():
        if token in haystack:
            keyword_bonus += 5.0

    dax_bonus = 10.0 if "/dax/" in url.lower() else 0.0
    return round(similarity + keyword_bonus + dax_bonus, 2)


def _normalize_search_results(payload: Dict) -> List[Dict]:
    # Payload normalization block
    raw_results = payload.get("results") or payload.get("value") or []
    normalized: List[Dict] = []

    for item in raw_results:
        title = item.get("title") or item.get("name") or ""
        url = item.get("url") or item.get("link") or ""
        description = item.get("description") or item.get("summary") or ""

        if not url:
            continue

        normalized.append(
            {
                "title": title.strip(),
                "url": url.strip(),
                "description": description.strip(),
            }
        )

    return normalized


def _is_dax_relevant(url: str, title: str, description: str) -> bool:
    # DAX relevance filter block
    probe = f"{url} {title} {description}".lower()
    dax_patterns = [
        "/dax/",
        "dax",
        "data analysis expressions",
        "power bi measure",
        "power bi dax",
        "calculate(",
    ]
    return any(p in probe for p in dax_patterns)


def _search_learn_api(query: str, top: int) -> List[Dict]:
    # Primary API search block
    encoded = quote(query)
    url = (
        f"{LEARN_SEARCH_API}?search={encoded}&locale=en-us"
        f"&$top={max(top * 3, 15)}"
    )

    payload = _safe_get(url)
    results = _normalize_search_results(payload)

    filtered = [r for r in results if _is_dax_relevant(r["url"], r["title"], r["description"])]

    for row in filtered:
        row["score"] = _text_score(query, row["title"], row["description"], row["url"])

    filtered.sort(key=lambda r: r["score"], reverse=True)
    return filtered[:top]


def _flatten_toc(items: List[Dict], parent: str = "") -> List[Dict]:
    # TOC flattening block
    rows: List[Dict] = []
    for item in items:
        title = item.get("toc_title") or item.get("name") or ""
        path = f"{parent} > {title}" if parent else title
        href = item.get("href")
        if href:
            if href.startswith("http"):
                url = href
            else:
                url = f"https://learn.microsoft.com/en-us/dax/{href.lstrip('/')}"
            rows.append({"title": title, "url": url, "description": path})

        children = item.get("children") or []
        if children:
            rows.extend(_flatten_toc(children, path))

    return rows


def _search_dax_toc_fallback(query: str, top: int) -> List[Dict]:
    # Fallback TOC search block
    payload = _safe_get(LEARN_DAX_TOC)
    items = payload.get("items") or []
    flattened = _flatten_toc(items)

    for row in flattened:
        row["score"] = _text_score(query, row["title"], row["description"], row["url"])

    flattened.sort(key=lambda r: r["score"], reverse=True)
    return flattened[:top]


def search_learn_dax_docs(query: str, top: int = 10) -> Dict:
    # Search orchestration block
    try:
        primary = _search_learn_api(query=query, top=top)
        if primary:
            return {
                "source": "learn_search_api",
                "query": query,
                "results": primary,
            }
    except Exception as ex:
        primary_error = str(ex)
    else:
        primary_error = "No DAX-relevant results from primary API."

    try:
        fallback = _search_dax_toc_fallback(query=query, top=top)
        return {
            "source": "dax_toc_fallback",
            "query": query,
            "results": fallback,
            "warning": primary_error,
        }
    except Exception as ex:
        return {
            "source": "none",
            "query": query,
            "results": [],
            "error": f"Primary and fallback search failed. Primary: {primary_error}; Fallback: {ex}",
        }


def main() -> None:
    # CLI argument block
    parser = argparse.ArgumentParser(description="Search Microsoft Learn DAX documentation.")
    parser.add_argument("query", type=str, help="Natural-language or keyword query")
    parser.add_argument("--top", type=int, default=10, help="Maximum number of results")
    parser.add_argument("--json", action="store_true", help="Print JSON output")
    args = parser.parse_args()

    if args.top < 1:
        parser.error("--top must be >= 1")
    if args.top > 50:
        parser.error("--top must be <= 50")

    result = search_learn_dax_docs(query=args.query, top=args.top)

    # CLI render block
    if args.json:
        print(json.dumps(result, indent=2))
        return

    print(f"Source: {result.get('source', 'unknown')}")
    if "warning" in result:
        print(f"Warning: {result['warning']}")
    if "error" in result:
        print(f"Error: {result['error']}")
        return

    rows = result.get("results", [])
    if not rows:
        print("No results found.")
        return

    for idx, row in enumerate(rows, start=1):
        print(f"{idx}. {row.get('title', '')} (score: {row.get('score', 0)})")
        print(f"   URL: {row.get('url', '')}")
        if row.get("description"):
            print(f"   Note: {row['description']}")


if __name__ == "__main__":
    main()
