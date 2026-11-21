#!/usr/bin/env python3
"""把新文案加进 app/Yilan/Resources/Localizable.xcstrings。
用法：scripts/add-strings.py 文件.json
文件内容：{"中文原文（即代码里的键）": "English"} 或 {"键": {"en": "…", "comment": "…"}}，
带单复数的写 {"键": {"one": "%lld item", "other": "%lld items"}}。已有的键会被覆盖。"""
import json, sys

PATH = "app/Yilan/Resources/Localizable.xcstrings"
catalog = json.load(open(PATH, encoding="utf-8"))
new = json.load(open(sys.argv[1], encoding="utf-8"))
unit = lambda v: {"stringUnit": {"state": "translated", "value": v}}
for key, value in new.items():
    entry = {}
    if isinstance(value, str):
        entry["localizations"] = {"en": unit(value)}
    elif "other" in value:
        entry["localizations"] = {"en": {"variations": {"plural": {"one": unit(value["one"]), "other": unit(value["other"])}}}}
    else:
        if value.get("comment"):
            entry["comment"] = value["comment"]
        entry["localizations"] = {"en": unit(value["en"])}
    catalog["strings"][key] = entry
catalog["strings"] = dict(sorted(catalog["strings"].items()))
text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))
open(PATH, "w", encoding="utf-8").write(text + "\n")
print(f"共 {len(catalog['strings'])} 条，新增或更新 {len(new)} 条")
