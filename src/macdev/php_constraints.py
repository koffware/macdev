"""Which installed PHP release lines satisfy a Composer `require.php` constraint.

Supports the constraint forms projects use for PHP: `^`, `~`, wildcards, hyphen
ranges, comparison operators, and `||` / `,` / whitespace combinations. An
installed version such as "8.4" stands for its whole release line, so it matches
when any 8.4.x patch release would.
"""

import re

Version = tuple[int, int, int]
Comparator = tuple[str, Version]

_VERSION = re.compile(r"^v?(\d+)(?:\.(\d+|\*|x))?(?:\.(\d+|\*|x))?(?:\.\d+)?(?:[-@+].*)?$", re.IGNORECASE)
_OPERATOR = re.compile(r"^(>=|<=|!=|<>|==|=|>|<|\^|~)?\s*(.+)$")
_LARGEST = 10**6
# major.minor.patch: a version with fewer explicit parts stands for a range of releases.
_FULL = 3


def _parse(text: str) -> tuple[list[int], bool] | None:
    """Return the explicit numeric parts and whether a wildcard ('*' or 'x') followed them."""
    text = text.strip()
    if text.lower() in {"*", "x"}:
        return [], True
    match = _VERSION.match(text)
    if not match:
        return None
    parts: list[int] = []
    for group in match.groups():
        if group is None:
            return parts, False
        if not group.isdigit():
            return parts, True
        parts.append(int(group))
    return parts, False


def _pad(parts: list[int]) -> Version:
    padded = [*parts, 0, 0, 0][:_FULL]
    return padded[0], padded[1], padded[2]


def _next(parts: list[int]) -> Version:
    """The first version after every release that starts with PARTS (8.2 → 8.3.0)."""
    if not parts:
        return (_LARGEST, 0, 0)
    return _pad([*parts[:-1], parts[-1] + 1])


def _line(parts: list[int]) -> list[Comparator]:
    """Every release that starts with PARTS ('8.2' → >=8.2.0 <8.3.0)."""
    return [(">=", _pad(parts)), ("<", _next(parts))] if parts else []


def _comparators(term: str) -> list[Comparator] | None:
    """One AND-ed term such as '^8.2', '>=8.1' or '8.2.*'."""
    match = _OPERATOR.match(term)
    parsed = _parse(match.group(2)) if match else None
    if match is None or parsed is None:
        return None
    operator = match.group(1) or ""
    parts, wildcard = parsed
    exact = operator in {"", "=", "=="}
    if wildcard:
        return _line(parts) if exact else None
    lower, partial = _pad(parts), len(parts) < _FULL
    comparators: list[Comparator]
    if operator == "^":
        significant = next((index for index, part in enumerate(parts) if part), len(parts) - 1)
        comparators = [(">=", lower), ("<", _next(parts[: significant + 1]))]
    elif operator == "~":
        comparators = [(">=", lower), ("<", _next(parts[:-1] if len(parts) > 1 else parts))]
    elif exact:
        # A partial exact version ('8.2') covers its whole line.
        comparators = _line(parts) if partial else [("==", lower)]
    elif operator in {"!=", "<>"}:
        comparators = [("!=", lower)]
    elif operator == "<=" and partial:
        comparators = [("<", _next(parts))]
    elif operator == ">" and partial:
        # '>8.2' excludes every 8.2.x release.
        comparators = [(">=", _next(parts))]
    else:
        comparators = [(operator, lower)]
    return comparators


def _alternative(text: str) -> list[Comparator] | None:
    """An AND-ed group: terms separated by commas or whitespace, or a hyphen range."""
    hyphen = re.fullmatch(r"\s*(\S+)\s+-\s+(\S+)\s*", text)
    if hyphen:
        low, high = _parse(hyphen.group(1)), _parse(hyphen.group(2))
        if low is None or high is None:
            return None
        if low[1] or high[1]:
            return None
        upper: Comparator = ("<=", _pad(high[0])) if len(high[0]) == _FULL else ("<", _next(high[0]))
        return [(">=", _pad(low[0])), upper]
    # Join operators to their versions ('>= 8.1' → '>=8.1') before splitting on whitespace.
    compact = re.sub(r"(>=|<=|!=|<>|==|=|>|<|\^|~)\s+", r"\1", text)
    comparators: list[Comparator] = []
    for term in re.split(r"[\s,]+", compact.strip()):
        if not term:
            continue
        parsed = _comparators(term)
        if parsed is None:
            return None
        comparators.extend(parsed)
    return comparators


def _satisfies(version: Version, comparators: list[Comparator]) -> bool:
    checks = {
        ">=": lambda bound: version >= bound,
        ">": lambda bound: version > bound,
        "<=": lambda bound: version <= bound,
        "<": lambda bound: version < bound,
        "==": lambda bound: version == bound,
        "!=": lambda bound: version != bound,
    }
    return all(checks[operator](bound) for operator, bound in comparators)


def _line_satisfies(major: int, minor: int, comparators: list[Comparator]) -> bool:
    """Whether some patch release of MAJOR.MINOR satisfies every comparator."""
    patches = {0, _LARGEST}
    for _, (bound_major, bound_minor, patch) in comparators:
        if (bound_major, bound_minor) == (major, minor):
            patches.update({max(patch - 1, 0), patch, patch + 1})
    return any(_satisfies((major, minor, patch), comparators) for patch in patches)


def supported_versions(constraint: str | None, versions: list[str]) -> list[str] | None:
    """Installed VERSIONS (e.g. '8.4') allowed by CONSTRAINT, or None if it cannot be read."""
    if not constraint or not constraint.strip():
        return None
    alternatives = []
    for text in re.split(r"\|\|?", constraint):
        comparators = _alternative(text)
        if comparators is None:
            return None
        alternatives.append(comparators)
    allowed = []
    for version in versions:
        match = re.fullmatch(r"(\d+)\.(\d+)", version)
        if match and any(_line_satisfies(int(match.group(1)), int(match.group(2)), group) for group in alternatives):
            allowed.append(version)
    return allowed
