import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('collector', Path(__file__).with_name('claude-speed-statusline.py'))
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)

class SpeedTests(unittest.TestCase):
    def test_response_boundaries_and_time_windows(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / 'transcript.jsonl'
            def sample(message, tokens, now):
                transcript.write_text(json.dumps(dict(type='assistant', message=dict(id=message, model='claude-opus-test')))+'\n')
                collector.observe(dict(transcript_path=str(transcript), model=dict(id='claude-opus-test'),
                    context_window=dict(current_usage=dict(output_tokens=tokens))), root/'cache', now)
            sample('one', 100, 100)
            sample('one', 120, 100.2)  # accumulates until >=0.5s
            sample('one', 160, 101)
            sample('two', 200, 102)  # do not subtract across responses
            sample('two', 250, 110)  # idle gap
            sample('two', 260, 111)
            state=json.loads(next((root/'cache').glob('*.json')).read_text())
            self.assertEqual([s['tokens'] for s in state['samples']], [60,10])
            self.assertEqual([s['seconds'] for s in state['samples']], [1,1])

    def test_missing_usage_does_not_estimate_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)/'cache'
            collector.observe(dict(transcript_path='missing',model=dict(id='claude-test')),root,100)
            self.assertFalse(root.exists())

if __name__=='__main__':
    unittest.main()
