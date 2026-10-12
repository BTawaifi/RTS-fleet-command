"""The syntax gate must reject broken source and Lua syntax newer than FSO's."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class ParseCheckTests(unittest.TestCase):
    def test_invalid_sources_produce_a_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            (root/'tools').mkdir()
            scripts=root/'data/scripts'
            scripts.mkdir(parents=True)
            checker=root/'tools/parse_check.py'
            shutil.copy2(Path(__file__).with_name('parse_check.py'),checker)
            for name,source in {'valid':'return {ok=true}', 'broken':'return {',
                                'too_new':'goto finish\n::finish::\nreturn true'}.items():
                (scripts/(name+'.lua')).write_text(source,encoding='utf-8')
            run=subprocess.run([sys.executable,str(checker)],capture_output=True,text=True)
            self.assertEqual(run.returncode,1,run.stdout+run.stderr)
            self.assertIn('SYNTAXERR broken.lua',run.stdout)
            self.assertIn('SYNTAXERR too_new.lua',run.stdout)
            self.assertIn('ok       valid.lua',run.stdout)
            self.assertIn('bad = 2',run.stdout)


if __name__=='__main__':
    unittest.main()
