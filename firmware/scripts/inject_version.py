"""PlatformIO pre-build hook: inject FIRMWARE_VERSION as a -D macro.

Resolved from `git describe --tags --dirty --always`. Outcome shapes:

- Tagged release commit       → `v1.0.0`                         (clean)
- Post-tag dev commit         → `v1.0.0-12-gabc1234[-dirty]`
- Untagged commit             → `<short-sha>[-dirty]` (via --always fallback)
- Untagged commit, shallow    → `<short-sha>[-dirty]`        (CI without
                                 fetch-depth: 0; tags simply aren't visible)
- No `.git` / git not on PATH → "unknown" (with loud warning to stderr)

iOS reads this string back over BLE on connect and surfaces a warning when
the leading major component disagrees with the app's MARKETING_VERSION; an
unparseable string (a bare short-sha or "unknown") is intentionally treated
as "skip the compare" so dev builds don't fire false positives.

Project policy is fail-loud: a release build silently shipping as "unknown"
because of a misconfigured CI runner / Docker `safe.directory` rejection /
missing git binary is exactly the bug the version stamp exists to surface.
The "unknown" fallback is therefore reserved for the documented no-history
case (source tarball); every other failure mode prints a warning that names
the specific reason.
"""
import subprocess

Import("env")  # noqa: F821  (provided by PlatformIO at script time)

MAX_LEN = 31  # sanity ceiling — `git describe` output is well under this in practice


def _git_describe(repo_dir: str) -> str:
    try:
        result = subprocess.run(
            ["git", "describe", "--tags", "--dirty", "--always"],
            cwd=repo_dir,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as e:
        # `git` not on PATH — not the documented no-history case. Surface
        # so the build doesn't ship as "unknown" with no operator signal.
        print(f"WARNING: inject_version: cannot invoke git ({e}); "
              "FIRMWARE_VERSION will be 'unknown'")
        return ""
    if result.returncode != 0:
        # `not a git repository` is the legitimate "no history" path
        # (source tarball, etc.) — fall back quietly. Anything else
        # (corrupt .git, safe.directory rejection, permission error) is
        # an environment bug we want to surface.
        stderr = (result.stderr or "").strip()
        if "not a git repository" in stderr:
            return ""
        print(f"WARNING: inject_version: git describe failed "
              f"(rc={result.returncode}): {stderr or '<no stderr>'}")
        return ""
    return result.stdout.strip()


project_dir = env.subst("$PROJECT_DIR")  # noqa: F821
# `git describe` walks up to the repo root on its own; passing the
# firmware dir is fine.
version = _git_describe(project_dir) or "unknown"
if len(version) > MAX_LEN:
    version = version[:MAX_LEN]

print(f"firmware version: {version}")

# CPPDEFINES with a tuple gives a string-valued macro. StringifyMacro
# wraps the value in the `\"...\"` quoting the C preprocessor needs.
env.Append(CPPDEFINES=[("FIRMWARE_VERSION", env.StringifyMacro(version))])  # noqa: F821
