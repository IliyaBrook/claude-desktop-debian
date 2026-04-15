#!/usr/bin/env python3
# @patch-target: app.asar.contents/.vite/build/index.js
# @patch-type: python
"""
Remove the 30-minute TTL on Computer Use / Dispatch grants.

Background:
  Claude Desktop reads the `dispatchCuGrantTtlMs` GrowthBook flag (defaults
  to 1 800 000 ms = 30 min) and uses it to expire granted apps in the
  `cuAllowedApps` list. When a grant expires, the user has to confirm
  permission again — which defeats the purpose of Dispatch (using the
  desktop remotely from a phone while you're not at the computer).

  The minified upstream code looks like:

    function HPe(){
      return xs(tD,"dispatchCuGrantTtlMs",RIn,Pr().int().positive())
    }

  And is used like:

    const o = wgt(n, Date.now(), HPe())           // filter out expired
    e.cuAllowedApps = wgt(e.cuAllowedApps, Date.now(), HPe())

Fix:
  Replace the body of the TTL accessor with a very large constant
  (`Number.MAX_SAFE_INTEGER`) so `Date.now() - grantedAt < TTL` is always
  true. Grants become effectively permanent for the session.

  The function name (`HPe`) is minified and changes between releases — we
  anchor on the unique `"dispatchCuGrantTtlMs"` string literal and rewrite
  only that single function body.

Usage: python3 fix_dispatch_grant_ttl.py <path_to_index.js>
"""

import sys
import os
import re


def patch_grant_ttl(filepath):
    """Force dispatchCuGrantTtlMs accessor to return Number.MAX_SAFE_INTEGER."""

    print("=== Patch: fix_dispatch_grant_ttl ===")
    print(f"  Target: {filepath}")

    if not os.path.exists(filepath):
        print(f"  [FAIL] File not found: {filepath}")
        return False

    with open(filepath, "rb") as f:
        content = f.read()

    original_content = content

    # Match the minified accessor:
    #   function HPe(){return xs(tD,"dispatchCuGrantTtlMs",RIn,Pr().int().positive())}
    # Capture the function head (with minified name) and replace the body.
    ttl_pattern = rb'(function [\w$]+\(\)\{)return [\w$]+\([\w$]+,"dispatchCuGrantTtlMs"[^}]+\}'
    ttl_replacement = rb'\1return Number.MAX_SAFE_INTEGER}'

    already = rb'function [\w$]+\(\)\{return Number\.MAX_SAFE_INTEGER\}'
    if re.search(already, content) and b'"dispatchCuGrantTtlMs"' not in re.search(
        rb'function [\w$]+\(\)\{return Number\.MAX_SAFE_INTEGER\}', content
    ).group(0):
        # Hard to distinguish — just try the replacement, it's idempotent below.
        pass

    content, count = re.subn(ttl_pattern, ttl_replacement, content, count=1)
    if count >= 1:
        print(f"  [OK] dispatchCuGrantTtlMs accessor: forced to MAX_SAFE_INTEGER ({count} match)")
    else:
        print("  [WARN] dispatchCuGrantTtlMs accessor: pattern not found (flag may be absent in this version)")
        return True  # non-fatal

    if content != original_content:
        with open(filepath, "wb") as f:
            f.write(content)
        print("  [PASS] Grant TTL patched — CU/Dispatch grants are now permanent")
        return True
    else:
        print("  [OK] Already patched")
        return True


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_index.js>")
        sys.exit(1)

    success = patch_grant_ttl(sys.argv[1])
    sys.exit(0 if success else 1)
