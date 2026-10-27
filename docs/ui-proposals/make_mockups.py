#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Writes three HTML mockups of possible DuckSCP Commander redesigns (A, B, C)."""
from pathlib import Path

OUT = Path(__file__).parent
LOCAL = [("..", "", "", True), ("assets", "", "Today 09:12", True), ("css", "", "Yesterday 18:40", True),
         ("index.html", "14 KB", "Today 09:30", False), ("app.js", "212 KB", "Today 09:28", False),
         ("logo.svg", "3 KB", "12 Oct 2026", False), ("robots.txt", "68 bytes", "2 Sep 2026", False),
         ("deploy.sh", "1 KB", "21 Oct 2026", False)]
REMOTE = [("..", "", "", "", True), ("assets", "", "Today 09:10", "rwxr-xr-x", True), ("css", "", "20 Oct 2026", "rwxr-xr-x", True),
          ("uploads", "", "Today 08:02", "rwxrwxr-x", True), ("index.html", "13 KB", "Yesterday 22:11", "rw-r--r--", False),
          ("app.js", "208 KB", "Yesterday 22:11", "rw-r--r--", False), (".htaccess", "512 bytes", "3 Sep 2026", "rw-r--r--", False),
          ("robots.txt", "68 bytes", "2 Sep 2026", "rw-r--r--", False)]

BASE = """
:root{--win:#ececec;--content:#fff;--sep:#e1e1e3;--label:#1d1d1f;--sec:#6e6e73;--ter:#a1a1a6;--accent:#007aff;
--sel:#dce9ff;--up:#e2403a;--down:#2f7fe0;--duck:#f5b82e;--side:#e8e8ea}
*{box-sizing:border-box;margin:0;padding:0}
body{background:#b9bec7;font:13px/1.35 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;color:var(--label);
-webkit-font-smoothing:antialiased;padding:28px;font-variant-numeric:tabular-nums}
.window{width:1224px;height:744px;border-radius:12px;overflow:hidden;background:var(--win);
box-shadow:0 0 0 .5px rgba(0,0,0,.25),0 24px 60px rgba(0,0,0,.28);display:flex;flex-direction:column}
.lights{display:flex;gap:8px}.lights i{width:12px;height:12px;border-radius:50%;display:block}
.lights i:nth-child(1){background:#ff5f57}.lights i:nth-child(2){background:#febc2e}.lights i:nth-child(3){background:#28c840}
.sym{width:16px;height:16px;display:inline-block;vertical-align:-3px;color:var(--sec)}
table{width:100%;border-collapse:collapse}
th{font-weight:500;color:var(--sec);font-size:11.5px;text-align:left;padding:5px 10px;border-bottom:1px solid var(--sep)}
td{padding:4px 10px;white-space:nowrap}
td.num,th.num{text-align:right}
td.dim{color:var(--sec)}
.ico{width:16px;height:16px;border-radius:3px;display:inline-block;vertical-align:-3px;margin-right:7px}
.folder{background:linear-gradient(#7cc4ff,#3b9bf0)}
.file{background:#fff;box-shadow:inset 0 0 0 1px #c9c9ce}
.parent{background:none;box-shadow:none;color:var(--ter)}
"""

def icon(name, is_dir):
    if name == "..":
        return '<span class="ico parent">↰</span>'
    return f'<span class="ico {"folder" if is_dir else "file"}"></span>'

def local_rows(selected=("index.html", "app.js")):
    out = []
    for n, s, d, isdir in LOCAL:
        cls = ' class="sel"' if n in selected else ""
        out.append(f'<tr{cls}><td>{icon(n, isdir)}{n}</td><td class="num dim">{s}</td><td class="dim">{d}</td></tr>')
    return "\n".join(out)

def remote_rows(rights=True, selected=()):
    out = []
    for n, s, d, r, isdir in REMOTE:
        cls = ' class="sel"' if n in selected else ""
        extra = f'<td class="dim">{r}</td>' if rights else ""
        out.append(f'<tr{cls}><td>{icon(n, isdir)}{n}</td><td class="num dim">{s}</td><td class="dim">{d}</td>{extra}</tr>')
    return "\n".join(out)

def page(title, css, body):
    return f"<!doctype html><html><head><meta charset=utf-8><title>{title}</title><style>{BASE}{css}</style></head><body>{body}</body></html>"

# ---------------------------------------------------------------- A: Native
A_CSS = """
.window{flex-direction:row}
.sidebar{width:228px;background:rgba(232,232,236,.92);border-right:1px solid var(--sep);padding:12px 10px;display:flex;flex-direction:column;gap:3px}
.sidebar .lights{margin:2px 6px 18px}
.sidebar h4{font-size:11px;font-weight:600;color:var(--ter);margin:10px 8px 4px}
.sidebar a{display:flex;align-items:center;gap:8px;padding:5px 8px;border-radius:6px;color:var(--label);text-decoration:none}
.sidebar a.on{background:rgba(0,0,0,.08);font-weight:500}
.dot{width:7px;height:7px;border-radius:50%;background:#28c840;margin-left:auto}
.main{flex:1;display:flex;flex-direction:column;background:var(--content)}
.toolbar{height:52px;display:flex;align-items:center;gap:6px;padding:0 14px;border-bottom:1px solid var(--sep);background:var(--win)}
.toolbar .title{font-weight:600;font-size:13px}.toolbar .sub{color:var(--sec);font-size:11px}
.tb{display:flex;gap:2px;margin-left:auto}
.tb button{border:0;background:none;padding:6px 9px;border-radius:6px;font:inherit;color:var(--label);display:flex;align-items:center;gap:6px}
.tb button:hover{background:rgba(0,0,0,.06)}
.tb .primary{background:var(--accent);color:#fff;padding:6px 12px}
.panes{flex:1;display:flex}
.pane{flex:1;display:flex;flex-direction:column;min-width:0}
.pane+.pane{border-left:1px solid var(--sep)}
.crumbs{display:flex;align-items:center;gap:4px;padding:8px 12px;font-size:12px;color:var(--sec);border-bottom:1px solid var(--sep)}
.crumbs b{color:var(--label);font-weight:500}
.crumbs .host{padding:1px 7px;border-radius:5px;background:#f0f0f2;color:var(--label)}
tr.sel td{background:var(--sel)}
.pane.active tr.sel td{background:var(--accent);color:#fff}.pane.active tr.sel td.dim{color:#e6efff}
.foot{display:flex;justify-content:space-between;padding:6px 12px;font-size:11px;color:var(--sec);border-top:1px solid var(--sep);background:#fafafa}
.transfer{display:flex;align-items:center;gap:10px;font-size:11px}
.bar{width:140px;height:5px;border-radius:3px;background:#e4e4e8;overflow:hidden}.bar i{display:block;height:100%;width:62%;background:var(--accent)}
"""
A_BODY = f"""<div class=window>
<nav class=sidebar><div class=lights><i></i><i></i><i></i></div>
<h4>Open</h4>
<a class=on><span class=sym>🖥</span>web-01<span class=dot></span></a>
<a><span class=sym>🖥</span>db server<span class=dot></span></a>
<h4>Sites</h4>
<a><span class=sym>📁</span>Production</a><a><span class=sym>📁</span>Staging</a><a><span class=sym>📁</span>Clients</a>
<a><span class=sym>🖥</span>localhost test</a>
<h4>Workspaces</h4><a><span class=sym>▤</span>My Workspace</a>
</nav>
<div class=main>
<div class=toolbar><div><div class=title>web-01</div><div class=sub>deploy@web01.example.com · SFTP-3 · 0:12:04</div></div>
<div class=tb><button>⇅ Synchronize</button><button>⌕ Find</button><button>◫ Queue (1)</button><button class=primary>Upload 2 items</button></div></div>
<div class=panes>
<section class="pane active"><div class=crumbs><span class=host>This Mac</span>›Projects›<b>web</b></div>
<table><tr><th>Name</th><th class=num>Size</th><th>Modified</th></tr>{local_rows()}</table>
<div style=flex:1></div><div class=foot><span>2 of 7 selected · 226 KB</span><span>Folders first</span></div></section>
<section class=pane><div class=crumbs><span class=host>web01.example.com</span>›var›www›<b>html</b></div>
<table><tr><th>Name</th><th class=num>Size</th><th>Modified</th><th>Permissions</th></tr>{remote_rows(selected=("app.js",))}</table>
<div style=flex:1></div><div class=foot><span>8 items · 222 KB</span>
<span class=transfer>Uploading app.js<span class=bar><i></i></span>2.1 MB/s</span></div></section>
</div></div></div>"""

# ---------------------------------------------------------------- B: Classic, refined
B_CSS = """
.titlebar{height:38px;display:flex;align-items:center;padding:0 12px;gap:14px}
.titlebar .t{flex:1;text-align:center;font-weight:600;font-size:13px;margin-right:52px}
.tools{display:flex;gap:4px;padding:0 10px 8px;align-items:center}
.tools button{border:0;background:none;font:inherit;padding:5px 9px;border-radius:6px;display:flex;flex-direction:column;align-items:center;gap:1px;font-size:11px;color:var(--label)}
.tools button span{font-size:15px}
.tools .gap{flex:1}
.tabs{display:flex;gap:1px;padding:0 10px;background:var(--win);border-bottom:1px solid var(--sep)}
.tabs div{padding:6px 16px;border-radius:7px 7px 0 0;color:var(--sec);display:flex;gap:8px;align-items:center}
.tabs .on{background:var(--content);color:var(--label);box-shadow:0 -1px 0 var(--sep) inset}
.tabs .sw{width:8px;height:8px;border-radius:2px}
.panes{flex:1;display:flex;gap:1px;background:var(--sep);min-height:0}
.pane{flex:1;background:var(--content);display:flex;flex-direction:column;position:relative}
.pane.active::before{content:"";position:absolute;left:0;top:0;bottom:0;width:3px;background:var(--accent)}
.path{display:flex;align-items:center;gap:6px;padding:7px 12px;border-bottom:1px solid var(--sep)}
.path .field{flex:1;background:#f4f4f6;border-radius:6px;padding:4px 9px;color:var(--label);font-size:12px}
.path .field em{font-style:normal;color:var(--sec)}
.nav{color:var(--sec);letter-spacing:6px}
tr:nth-child(even) td{background:#fafafb}
tr.sel td{background:var(--sel)!important}
.pane.active tr.sel td{background:var(--accent)!important;color:#fff}.pane.active tr.sel td.dim{color:#e6efff}
.queue{height:96px;background:var(--content);border-top:1px solid var(--sep)}
.q{display:grid;grid-template-columns:22px 1fr 1fr 150px 70px;align-items:center;gap:10px;padding:6px 12px;font-size:12px;border-bottom:1px solid #f1f1f3}
.q .bar{height:5px;border-radius:3px;background:#e8e8ec;overflow:hidden}.q .bar i{display:block;height:100%;background:var(--accent)}
.fkeys{display:flex;gap:6px;padding:7px 10px;background:var(--win);border-top:1px solid var(--sep)}
.fkeys span{display:flex;align-items:center;gap:6px;font-size:12px;color:var(--label);padding:3px 8px 3px 4px;border-radius:6px}
.fkeys kbd{font:600 10.5px -apple-system;background:#fff;border-radius:4px;padding:2px 5px;box-shadow:0 1px 0 #c7c7cc,0 0 0 .5px #c7c7cc;color:var(--sec)}
.status{display:flex;gap:14px;padding:4px 12px 6px;font-size:11px;color:var(--sec);background:var(--win)}
.status .pill{background:#e3f6e7;color:#1c7c35;border-radius:9px;padding:0 8px}
.status .r{margin-left:auto}
"""
B_BODY = f"""<div class=window>
<div class=titlebar><div class=lights><i></i><i></i><i></i></div><div class=t>html — deploy@web01.example.com</div></div>
<div class=tools><button><span>＋</span>New Session</button><button><span>☰</span>Sites</button><button><span>⏏</span>Disconnect</button>
<button><span>⇅</span>Synchronize</button><button><span>◉</span>Keep Up to Date</button><button><span>⌕</span>Find</button><div class=gap></div>
<button><span>↻</span>Refresh</button><button><span>≡</span>Queue</button></div>
<div class=tabs><div class=on><i class=sw style="background:#ff8a00"></i>web-01</div><div><i class=sw style="background:#8e8e93"></i>db server</div><div>＋</div></div>
<div class=panes>
<section class="pane active"><div class=path><span class=nav>‹ › ↑</span><div class=field><em>~ / Projects /</em> web</div></div>
<table><tr><th>Name</th><th class=num>Size</th><th>Modified</th></tr>{local_rows()}</table></section>
<section class=pane><div class=path><span class=nav>‹ › ↑</span><div class=field><em>/ var / www /</em> html</div></div>
<table><tr><th>Name</th><th class=num>Size</th><th>Modified</th><th>Rights</th></tr>{remote_rows()}</table></section>
</div>
<div class=queue>
<div class=q><span style="color:var(--accent)">↑</span><span>~/Projects/web/app.js</span><span class=dim style="color:var(--sec)">/var/www/html</span><span class=bar><i style="width:62%"></i></span><span>2.1 MB/s</span></div>
<div class=q><span style="color:var(--sec)">↓</span><span>/var/www/html/uploads</span><span style="color:var(--sec)">~/Downloads</span><span class=bar><i style="width:0"></i></span><span style="color:var(--sec)">Waiting</span></div>
</div>
<div class=fkeys><span><kbd>F2</kbd>Rename</span><span><kbd>F4</kbd>Edit</span><span><kbd>F5</kbd>Copy</span><span><kbd>F6</kbd>Move</span>
<span><kbd>F7</kbd>New Folder</span><span><kbd>F8</kbd>Delete</span><span><kbd>F9</kbd>Properties</span></div>
<div class=status><span>2 of 7 selected · 226 KB</span><span class=r><span class=pill>🔒 SFTP-3</span></span><span>0:12:04</span></div>
</div>"""

# ---------------------------------------------------------------- C: Duck
C_CSS = """
.titlebar{height:46px;display:flex;align-items:center;padding:0 14px;gap:16px;border-bottom:1px solid var(--sep)}
.sess{display:flex;gap:6px}
.sess div{padding:4px 12px;border-radius:7px;color:var(--sec);display:flex;gap:7px;align-items:center}
.sess .on{background:#fff;color:var(--label);box-shadow:0 0 0 .5px #d0d0d4,0 1px 2px rgba(0,0,0,.06)}
.sess .on b{font-weight:600}
.titlebar .right{margin-left:auto;display:flex;gap:4px;color:var(--sec);font-size:12px}
.titlebar .right span{padding:4px 8px;border-radius:6px}
.panes{flex:1;display:grid;grid-template-columns:1fr 64px 1fr;min-height:0;padding:10px;gap:0}
.pane{background:var(--content);border-radius:10px;display:flex;flex-direction:column;overflow:hidden;box-shadow:0 0 0 .5px #d3d3d8}
.pane.active{box-shadow:0 0 0 2px var(--duck),0 0 0 5px rgba(245,184,46,.18)}
.head{display:flex;align-items:baseline;gap:8px;padding:10px 14px 8px}
.head .where{font-size:11px;color:var(--sec)}
.head .dir{font-size:17px;font-weight:600;letter-spacing:-.2px}
.head .trail{font-size:12px;color:var(--ter)}
tr.sel td{background:#fff4d8}
.gutter{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px}
.go{width:44px;height:44px;border-radius:50%;display:grid;place-items:center;color:#fff;font-size:20px;font-weight:600;
box-shadow:0 2px 6px rgba(0,0,0,.18)}
.go.up{background:var(--up)}.go.down{background:var(--down)}
.go small{display:block}
.gutter .lbl{font-size:10.5px;color:var(--sec);text-align:center;margin-top:-8px}
.queue{margin:0 10px 10px;background:var(--content);border-radius:10px;box-shadow:0 0 0 .5px #d3d3d8;overflow:hidden}
.q{display:grid;grid-template-columns:auto 1fr 200px 80px;gap:12px;align-items:center;padding:8px 14px;font-size:12px}
.q+.q{border-top:1px solid #f1f1f3}
.dir-up{color:var(--up);font-weight:600}.dir-down{color:var(--down);font-weight:600}
.bar{height:6px;border-radius:3px;background:#efeff2;overflow:hidden}.bar i{display:block;height:100%}
.status{display:flex;gap:16px;padding:0 16px 10px;font-size:11px;color:var(--sec)}
.status .r{margin-left:auto}
.status kbd{font:600 10px -apple-system;border-radius:4px;padding:1px 4px;box-shadow:0 0 0 .5px #c7c7cc;background:#fff}
"""
C_BODY = f"""<div class=window>
<div class=titlebar><div class=lights><i></i><i></i><i></i></div>
<div class=sess><div class=on><b>web-01</b><span style="color:var(--sec)">SFTP</span></div><div>db server</div><div>＋</div></div>
<div class=right><span>⇅ Sync</span><span>◉ Watch</span><span>⌕ Find</span><span>⚙︎</span></div></div>
<div class=panes>
<section class="pane active"><div class=head><span class=dir>web</span><span class=trail>~/Projects</span><span class=where style="margin-left:auto">This Mac</span></div>
<table><tr><th>Name</th><th class=num>Size</th><th>Modified</th></tr>{local_rows()}</table></section>
<div class=gutter><div class="go up">→</div><div class=lbl>Upload<br>F5</div><div class="go down">←</div><div class=lbl>Download</div></div>
<section class=pane><div class=head><span class=dir>html</span><span class=trail>/var/www</span><span class=where style="margin-left:auto">web01.example.com</span></div>
<table><tr><th>Name</th><th class=num>Size</th><th>Modified</th><th>Rights</th></tr>{remote_rows()}</table></section>
</div>
<div class=queue>
<div class=q><span class=dir-up>↑ Uploading</span><span>app.js → /var/www/html</span><span class=bar><i style="width:62%;background:var(--up)"></i></span><span>2.1 MB/s</span></div>
<div class=q><span class=dir-down>↓ Queued</span><span>uploads/ → ~/Downloads</span><span class=bar><i style="width:0"></i></span><span style="color:var(--sec)">Waiting</span></div>
</div>
<div class=status><span>2 of 7 selected · 226 KB</span><span><kbd>F2</kbd> Rename <kbd>F4</kbd> Edit <kbd>F7</kbd> New Folder <kbd>F8</kbd> Delete</span><span class=r>🔒 SFTP-3 · 0:12:04</span></div>
</div>"""

for name, css, body, title in [("A-native", A_CSS, A_BODY, "A · Native"), ("B-classic-refined", B_CSS, B_BODY, "B · Classic refined"),
                               ("C-duck", C_CSS, C_BODY, "C · Duck")]:
    (OUT / f"{name}.html").write_text(page(title, css, body))
print("written")
