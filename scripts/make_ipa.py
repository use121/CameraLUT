#!/usr/bin/env python3
"""把 .app 打成 IPA。

要点：Info.plist 必须排在最前面。
部分签名工具（如全能签）只扫描 zip 的前几个本地文件头来定位主包，
如果可执行文件排在 Info.plist 前面，就会判定为「未找到可导入的主包」。
"""

import os
import sys
import zipfile


def dir_entry(name: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name)
    info.external_attr = (0o40755 << 16) | 0x10
    info.compress_type = zipfile.ZIP_STORED
    return info


def build(app_path: str, out_path: str) -> None:
    app_name = os.path.basename(app_path)
    priority = ["Info.plist", "PkgInfo"]

    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(dir_entry("Payload/"), b"")
        archive.writestr(dir_entry("Payload/%s/" % app_name), b"")

        # 先把签名工具需要的元数据写进去
        for name in priority:
            full = os.path.join(app_path, name)
            if os.path.exists(full):
                archive.write(full, "Payload/%s/%s" % (app_name, name))

        # 其余文件按稳定顺序追加
        for root, dirs, files in os.walk(app_path):
            dirs.sort()
            for filename in sorted(files):
                full = os.path.join(root, filename)
                rel = os.path.relpath(full, app_path)
                if rel in priority:
                    continue
                archive.write(full, "Payload/%s/%s" % (app_name, rel))


def main() -> int:
    if len(sys.argv) < 3:
        print("用法: make_ipa.py <App.app> <out.ipa>")
        return 2

    app_path, out_path = sys.argv[1], sys.argv[2]
    if not os.path.isdir(app_path):
        print("找不到 .app 目录: %s" % app_path)
        return 1

    build(app_path, out_path)

    print("IPA 条目顺序:")
    with zipfile.ZipFile(out_path) as archive:
        for index, name in enumerate(archive.namelist()):
            print("  %d: %s" % (index, name))

    print("大小: %d 字节" % os.path.getsize(out_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
