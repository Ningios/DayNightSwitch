#!/usr/bin/env python3
"""跨平台 deb 打包：自己写 ar 头，绕开 macOS ar 会丢掉非 Mach-O 成员的问题
用法：python3 tools/mkdeb.py <暂存目录> <输出.deb>
暂存目录需要含 DEBIAN/control，（可选 DEBIAN/postinst 等脚本）以及要安装的文件树。
"""
import os, sys, tarfile, io, time, gzip

def add_ar_member(out, name, data, mode=0o100644, mtime=None):
    mtime = int(mtime or time.time())
    hdr = "{:<16}{:<12}{:<6}{:<6}{:<8}{:<10}`\n".format(
        name + '/', mtime, '0', '0', mode, len(data)).encode()
    assert len(hdr) == 60, hdr
    out.write(hdr)
    out.write(data)
    if len(data) % 2:
        out.write(b'\n')

def tar_bytes(root, members, gz=True):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as tf:
        for arc, src, mode in members:
            ti = tf.gettarinfo(src, arcname=arc)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = 'root'
            ti.mode = mode
            if ti.isdir():
                tf.addfile(ti)
            else:
                with open(src, 'rb') as f:
                    tf.addfile(ti, f)
    raw = buf.getvalue()
    if not gz:
        return raw
    zbuf = io.BytesIO()
    with gzip.GzipFile(fileobj=zbuf, mode='wb', mtime=0) as g:
        g.write(raw)
    return zbuf.getvalue()

def main():
    stage, outpath = sys.argv[1], sys.argv[2]
    stage = os.path.abspath(stage)

    # --- control.tar.gz ---
    ctl = [('./control', os.path.join(stage, 'DEBIAN/control'), 0o644)]
    for extra in ('postinst', 'preinst', 'postrm', 'prerm'):
        p = os.path.join(stage, 'DEBIAN', extra)
        if os.path.exists(p):
            ctl.append(('./' + extra, p, 0o755))
    control_tar = tar_bytes(stage, ctl)

    # --- data.tar.gz ---
    data = []
    for base, dirs, files in os.walk(stage):
        if base.startswith(os.path.join(stage, 'DEBIAN')):
            continue
        rel = './' + os.path.relpath(base, stage).replace(os.sep, '/')
        if rel == './':
            continue
        data.append((rel, base, 0o755))
        for f in files:
            full = os.path.join(base, f)
            mode = 0o755 if os.access(full, os.X_OK) else 0o644
            data.append((rel + '/' + f, full, mode))
    data.sort(key=lambda x: x[0])
    data_tar = tar_bytes(stage, data)

    with open(outpath, 'wb') as f:
        f.write(b'!<arch>\n')
        add_ar_member(f, 'debian-binary', b'2.0\n')
        add_ar_member(f, 'control.tar.gz', control_tar)
        add_ar_member(f, 'data.tar.gz', data_tar)
    print('built', outpath, os.path.getsize(outpath), 'bytes')

if __name__ == '__main__':
    main()
