"""Build-time patch: a per-engine cap on SearXNG's suspension time.

SearXNG suspends an engine after an access-denied / CAPTCHA / too-many-requests
answer for a GLOBAL time (search.suspended_times). That is right for engines
that leave from our single Railway IP (retrying a blocked IP only prolongs the
block), and wrong for engines on the Tor exit pool: those rotate the exit per
request (isolated circuits), so one bad exit says nothing about the next one.

Engines may now set `suspend_cap: <seconds>` in settings.yml; SearXNG copies
every engine setting onto the engine module (engines/__init__.py setattr), and
the patched handler caps the suspension at that value.

The image is pinned (Dockerfile), and this script FAILS THE BUILD if the code
it patches is not found verbatim — a silent no-op patch would be worse than
none.
"""
import sys
from pathlib import Path

TARGET = Path("/usr/local/searxng/searx/search/processors/abstract.py")
OLD = """            if isinstance(exception_or_message, SearxEngineAccessDeniedException):
                suspended_time = exception_or_message.suspended_time
            self.suspended_status.suspend(suspended_time, error_message)  # pylint: disable=no-member
"""
NEW = """            if isinstance(exception_or_message, SearxEngineAccessDeniedException):
                suspended_time = exception_or_message.suspended_time
            # ECHOLOT (container/patch_suspend_cap.py): per-engine cap
            _cap = getattr(self.engine, "suspend_cap", None)
            if _cap is not None and suspended_time is not None:
                suspended_time = min(int(_cap), int(suspended_time))
            self.suspended_status.suspend(suspended_time, error_message)  # pylint: disable=no-member
"""

src = TARGET.read_text(encoding="utf-8")
if src.count(OLD) != 1:
    sys.exit(f"patch_suspend_cap: expected block not found exactly once in {TARGET} "
             f"(found {src.count(OLD)}) — the pinned image changed; update the patch")
TARGET.write_text(src.replace(OLD, NEW, 1), encoding="utf-8")
print("patch_suspend_cap: applied")
