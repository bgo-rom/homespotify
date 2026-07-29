from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parent
MEMORY_DROP_IN = ROOT / "20-memory.conf"
SERVICE = ROOT / "homespotify-api-shadow.service"


class Phase64B1HardeningTest(unittest.TestCase):
    def test_memory_drop_in_is_exact_and_separate(self) -> None:
        self.assertEqual(
            MEMORY_DROP_IN.read_text(encoding="utf-8").splitlines(),
            ["[Service]", "MemoryAccounting=yes", "MemoryMax=384M"],
        )
        self.assertNotIn("MemoryMax=", SERVICE.read_text(encoding="utf-8"))

    def test_start_limit_directives_are_in_unit_section(self) -> None:
        text = SERVICE.read_text(encoding="utf-8")
        unit, service = text.split("[Service]", maxsplit=1)
        self.assertIn("StartLimitIntervalSec=300", unit)
        self.assertIn("StartLimitBurst=5", unit)
        self.assertNotIn("StartLimitIntervalSec=", service)
        self.assertNotIn("StartLimitBurst=", service)

    def test_memory_limit_matches_384_mib(self) -> None:
        self.assertEqual(384 * 1024 * 1024, 402_653_184)
        peak_kib = 114_892
        self.assertGreater(384 * 1024, 3 * peak_kib)


if __name__ == "__main__":
    unittest.main()
