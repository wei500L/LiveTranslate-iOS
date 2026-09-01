import json
m = json.load(open("Resources/ModelManifest.json"))
assert m["schemaVersion"] == 2
assert set(m["backends"]) == {"coreml-fp16", "sherpa-onnx-int8"}
assert m["backends"]["coreml-fp16"]["kind"] == "coreMLFP16"
assert m["backends"]["sherpa-onnx-int8"]["kind"] == "sherpaONNXInt8"
for key, b in m["backends"].items():
    assert len(b["revision"]) == 40
    total = sum(f["bytes"] for f in b["files"])
    assert b["totalDownloadBytes"] == total, key
    for f in b["files"]:
        assert len(f["sha256"]) == 64
        assert f"/resolve/{b['revision']}/" in f["url"], f["path"]
        assert ".." not in f["path"] and not f["path"].startswith("/")
assert m["runtime"]["sherpaOnnxVersion"] == "1.13.7"
print("JSON OK")
print("coreml keys:", sorted(m["backends"]["coreml-fp16"].keys()))
