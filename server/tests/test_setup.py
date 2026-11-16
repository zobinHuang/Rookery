import re
import unittest
from pathlib import Path


class SetupScriptTest(unittest.TestCase):
    """The deploy script copies the package module by module, so it must name every one."""

    SETUP_PATH = Path(__file__).resolve().parent.parent / "setup.sh"
    PACKAGE_PATH = Path(__file__).resolve().parent.parent / "rookd"
    MODULE_LOOP_PATTERN = re.compile(r"^for MODULE in (.+); do$", re.MULTILINE)

    def test_installs_every_module_of_the_package(self) -> None:
        match = self.MODULE_LOOP_PATTERN.search(self.SETUP_PATH.read_text(encoding="utf-8"))
        self.assertIsNotNone(match, "setup.sh no longer lists the modules it installs")
        set_listed = set(match.group(1).split()) if match else set()
        set_present = {path.name for path in self.PACKAGE_PATH.glob("*.py")}
        self.assertEqual(set_listed, set_present)


if __name__ == "__main__":
    unittest.main()
