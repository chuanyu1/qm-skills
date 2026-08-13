import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "mineru.py"
SPEC = importlib.util.spec_from_file_location("mineru_skill", MODULE_PATH)
assert SPEC and SPEC.loader
mineru = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mineru)


class MineruImageBundleTests(unittest.TestCase):
    def test_materializes_images_and_builds_bundle(self):
        image_bytes = b"\x89PNG\r\n\x1a\nsynthetic"
        item = {
            "md_content": "![示例](images/example.png)",
            "images": {"example.png": "data:image/png;base64," + base64.b64encode(image_bytes).decode("ascii")},
        }
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            (output / "parsed.md").write_text(item["md_content"], encoding="utf-8")
            manifest = mineru.materialize_images(item, output)
            refs = mineru.markdown_image_refs(item["md_content"])
            bundle = mineru.build_bundle(output, manifest)

            self.assertEqual({"images/example.png"}, refs)
            self.assertEqual(image_bytes, (output / "images" / "example.png").read_bytes())
            self.assertEqual("images/example.png", item["images"]["example.png"]["saved_to"])
            with zipfile.ZipFile(bundle) as archive:
                self.assertEqual(["images/example.png", "parsed.md"], sorted(archive.namelist()))

    def test_rejects_traversal_image_name(self):
        with self.assertRaises(mineru.MineruError):
            mineru.safe_image_relative_path("../secret.png")

    def test_collect_fails_when_markdown_image_is_missing(self):
        result = {
            "backend": "pipeline",
            "version": "3.0.4",
            "results": {"input": {"md_content": "![](images/missing.jpg)", "images": {}}},
        }
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            mineru.write_json(output / "request.json", {"parseMethod": "ocr"})
            mineru.write_json(output / "task.json", {"status": "completed"})
            original = mineru.curl_json
            mineru.curl_json = lambda *_args, **_kwargs: (200, json.loads(json.dumps(result)))
            try:
                with self.assertRaisesRegex(mineru.MineruError, "未返回的图片"):
                    mineru.collect_result("http://example.invalid", 1, output, "task")
            finally:
                mineru.curl_json = original


if __name__ == "__main__":
    unittest.main()
