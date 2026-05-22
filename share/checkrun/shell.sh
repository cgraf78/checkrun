# shellcheck shell=bash
# checkrun shell integration.
#
# Source this file from shell startup when a host wants all dependency shell
# loaders to follow the same convention:
#   . "$(shdeps dep-file cgraf78/checkrun share/checkrun/shell.sh)"

# shellcheck disable=SC2034 # public marker for callers that verify the loader ran.
CHECKRUN_SHELL_LOADED=1

# ---------------------------------------------------------------------------
# Public API - stable shell integration surface
# ---------------------------------------------------------------------------
# checkrun currently exports no interactive shell functions. The sourceable
# loader is intentionally present as a stable no-op so integration harnesses can
# load dependency shell APIs uniformly.
