"""PlatformIO pre-build hook: inject FIRMWARE_VERSION as a -D macro.

Resolved from `git describe --tags --dirty --always`, run from the repo
root so a tagged release commit becomes `v1.0.0`, an untagged dev commit
becomes `<short-sha>` (or `<short-sha>-dirty` with uncommitted changes),
and a checkout without git history (CI without fetch-depth: 0, source
tarball, etc.) falls back to "unknown" rather than failing the build.

iOS reads this string back over BLE on connect and surfaces a warning
when the major component disagrees with the app's MARKETING_VERSION.
"""
import os
import subprocess

Import("env")  # noqa: F821  (provided by PlatformIO at script time)

MAX_LEN = 31  # keep within a single ATT read on default-MTU iOS connections


def _git_describe(repo_dir: str) -> str:
    try:
        out = subprocess.check_output(
            ["git", "describe", "--tags", "--dirty", "--always"],
            cwd=repo_dir,
            stderr=subprocess.DEVNULL,
        )
        return out.decode("ascii", errors="replace").strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


project_dir = env.subst("$PROJECT_DIR")  # noqa: F821
# git describe walks up to the repo root on its own; passing the firmware
# dir is fine.
version = _git_describe(project_dir) or "unknown"
if len(version) > MAX_LEN:
    version = version[:MAX_LEN]

print(f"firmware version: {version}")

# CPPDEFINES with a tuple gives a string-valued macro. StringifyMacro
# wraps it in the `\"...\"` quoting the C preprocessor needs.
env.Append(CPPDEFINES=[("FIRMWARE_VERSION", env.StringifyMacro(version))])  # noqa: F821
