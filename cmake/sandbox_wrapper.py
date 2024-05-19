import sys
from typing import Iterable, List
from . import landlock
import os

from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent

# These are paths that any compilation process can always touch, if you have strict sandboxing
# you can limit this more.
READONLY_GLOBAL_PATHS = {
    Path("/usr"),
    Path("/bin"),
    Path("/var"),
    Path("/lib"),
    Path("/lib32"),
    Path("/lib64"),
}

# These are paths that any compilation process can always read and write to fully
READWRITE_GLOBAL_PATHS = {
    Path("/tmp"),
}

def read_paths_envvar(name: str) -> List[Path]:
    """
    Read a colon delimited environment variable as a list of Path
    """
    env_var = os.environ.get(name, default="")
    if not env_var:
        return []
    paths = env_var.split(":")
    return [Path(p) for p in paths]

def add_rules(rules: landlock.Ruleset, paths: Iterable[Path], access: landlock.FSAccess, debug: bool = False):
    """
    Add rules to a landlock ruleset, with optional debug statements
    """
    for path in paths:
        if not path.exists():
            print(f"skipping access {str(access)} to {path}: does not exist", file=sys.stderr) if debug else None
            continue
        print(f"allowing access to {path}: {str(access)}", file=sys.stderr) if debug else None
        rules.allow(path, rules=access)


if __name__ == "__main__":
    debug = os.environ.get("LANDLOCK_SANDBOX_DEBUG", default="false")
    debug = debug.lower() in ['true', '1', 't', 'y', 'yes']

    rules = landlock.Ruleset()

    add_rules(rules, READONLY_GLOBAL_PATHS, landlock.FSAccess.readonly(), debug=debug)
    add_rules(rules, READWRITE_GLOBAL_PATHS, landlock.FSAccess.all(), debug=debug)
    add_rules(rules, read_paths_envvar("LANDLOCK_SANDBOX_RO_DIRS"), landlock.FSAccess.readonly() & landlock.FSAccess.all_dir(), debug=debug)
    add_rules(rules, read_paths_envvar("LANDLOCK_SANDBOX_RO_PATHS"), landlock.FSAccess.readonly(), debug=debug)
    add_rules(rules, read_paths_envvar("LANDLOCK_SANDBOX_RW_PATHS"), landlock.FSAccess.all(), debug=debug)

    rules.apply()

    if len(sys.argv) < 2:
        print("missing delegate executable invocation", file=sys.stderr)
        sys.exit(1)

    print(f"executing: {' '.join(sys.argv[1:])}", file=sys.stderr) if debug else None
    os.execvp(sys.argv[1], sys.argv[1:])

