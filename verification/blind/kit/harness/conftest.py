"""pytest harness for the blind-agent round (given to the tester; do not edit).

The implementation under test is a single Python module loaded by path from the environment variable
VBLIND_IMPL (default: stub/vblind.py, the unimplemented stub, against which every test must fail).
Tests receive it through the `impl` fixture and call only the names in stub/vblind.py.

    VBLIND_IMPL=path/to/impl.py ./.venv/bin/python -m pytest tests -q

`raises_cited(ExcName, "KEY[,KEY]")` is pytest.raises with a citation, for tests whose requirement is a refusal.
ExcName is "DoPError" or "BurstError" (looked up on the implementation module), or an exception class.
"""
import importlib.util
import os
import sys
from pathlib import Path

import pytest

ROOM = Path(__file__).resolve().parent


def load_impl(path: str):
    p = Path(path).resolve()
    sys.path.insert(0, str(p.parent))      # lets a variant import a base module next to it
    spec = importlib.util.spec_from_file_location(f"vblind_impl_{abs(hash(str(p)))}", p)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod            # dataclasses look their module up here
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="session")
def impl():
    return load_impl(os.environ.get("VBLIND_IMPL", str(ROOM / "stub" / "vblind.py")))


@pytest.fixture(scope="session")
def raises_cited(impl):
    def _raises(exc, keys):
        if isinstance(exc, str):
            exc = getattr(impl, exc)
        return pytest.raises(exc)
    return _raises
