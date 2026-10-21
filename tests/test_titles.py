"""The title registry: which id in a file name maps to which game, and which of them this runtime can build."""
import unittest

from mng_agent import titles


class Titles(unittest.TestCase):
    def test_only_totk_is_supported(self):
        self.assertEqual(titles.supported(), {'0100F2C0115B6000'})

    def test_known_games_carry_a_reason(self):
        known = titles.all()
        self.assertEqual(known['01002B00111A2000']['name'], 'Hyrule Warriors: Age of Calamity')
        self.assertFalse(known['01002B00111A2000']['supported'])
        self.assertTrue(known['01002B00111A2000']['reason'])
        self.assertEqual(known['01007EF00011E000']['name'], 'The Legend of Zelda: Breath of the Wild')
        self.assertFalse(known['01007EF00011E000']['supported'])

    def test_identify_bracketed_and_bare_ids(self):
        self.assertEqual(titles.identify('TOTK [0100F2C0115B6000][v0].xci'), '0100F2C0115B6000')
        self.assertEqual(titles.identify('Hyrule Warriors [01002B00111A2000].xci'), '01002B00111A2000')
        self.assertEqual(titles.identify('01007EF00011E000.nsp'), '01007EF00011E000')
        self.assertIsNone(titles.identify('totk.xci'))

    def test_identify_ignores_longer_hex_runs(self):
        self.assertIsNone(titles.identify('dump-0100F2C0115B60000.xci'))

    def test_identify_ticket_names(self):
        self.assertEqual(titles.identify('01007ef00011e0000000000000000000.tik'), '01007EF00011E000')
        self.assertEqual(titles.identify('0100f2c0115b60000000000000000000.cert'), '0100F2C0115B6000')


if __name__ == '__main__':
    unittest.main()
