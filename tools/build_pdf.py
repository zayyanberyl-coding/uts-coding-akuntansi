"""Menyusun PDF jawaban akhir dari berkas JAWABAN_SOAL*.md + bukti uji + tangkapan layar.
Pemakaian: python3 tools/build_pdf.py   (butuh pandoc & playwright/chromium)
"""
import html
import pathlib
import re
import subprocess

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "JAWABAN_UTS_Zayyan_Beryl_12030124140283.pdf"
REPO = "https://github.com/zayyanberyl-coding/uts-coding-akuntansi"
WEB = "https://zayyanberyl-coding.github.io/uts-coding-akuntansi/soal3/web/"
SHOT = ROOT / "bukti" / "screenshots"


def md_to_html(md_text: str, base: pathlib.Path) -> str:
    out = subprocess.run(["pandoc", "-f", "gfm", "-t", "html5", "--no-highlight"],
                         input=md_text, capture_output=True, text=True, check=True).stdout
    # path gambar relatif -> absolut
    return re.sub(r'src="(?!https?:|file:)([^"]+)"',
                  lambda m: f'src="file://{(base / m.group(1)).resolve()}"', out)


def figure(path: pathlib.Path, caption: str, width: str = "100%") -> str:
    return (f'<figure><img src="file://{path}" style="width:{width}"/>'
            f'<figcaption>{html.escape(caption)}</figcaption></figure>')


def figrow(items) -> str:
    cells = "".join(f'<div>{figure(p, c)}</div>' for p, c in items)
    return f'<div class="figrow">{cells}</div>'


def excerpt(path: pathlib.Path, start: str, end: str | None = None) -> str:
    text = path.read_text()
    i = text.index(start)
    j = text.index(end, i + 1) if end else len(text)
    return f'<pre class="evidence">{html.escape(text[i:j].rstrip())}</pre>'


def section(md_file: str) -> str:
    p = ROOT / md_file
    return md_to_html(p.read_text(), p.parent)


cover = f"""
<section class="cover">
  <p class="inst">DEPARTEMEN AKUNTANSI · FAKULTAS EKONOMIKA DAN BISNIS<br/>UNIVERSITAS DIPONEGORO</p>
  <h1>Lembar Jawaban<br/>Ujian Tengah Semester</h1>
  <p class="sub">Pemrograman / Coding · Semester Gasal 2026/2027</p>
  <table class="ident">
    <tr><th>Nama</th><td>Zayyan Beryl</td></tr>
    <tr><th>NIM</th><td>12030124140283</td></tr>
    <tr><th>Mata kuliah / Kelas</th><td>Pengkodean dan Pemrograman · Kelas E</td></tr>
    <tr><th>Dosen pengampu</th><td>Totok Dewayanto</td></tr>
  </table>
  <div class="links">
    <p><b>Repositori Git (seluruh artefak jawaban)</b><br/><a href="{REPO}">{REPO}</a></p>
    <p><b>Purwarupa web Voucher Kas Keluar (Soal 3)</b><br/><a href="{WEB}">{WEB}</a></p>
    <p><b>Basis data cloud</b><br/>Supabase (PostgreSQL) · project <code>uts-coding-akuntansi</code></p>
  </div>
  <div class="tools">
    <b>Alat bantu yang digunakan</b> (ujian bersifat Open Book / Open AI / Open Code Sandbox):
    PostgreSQL 16 (uji lokal), Supabase, Gemini Canvas, NotebookLM, serta asisten AI Claude
    untuk membantu penyusunan dan pengujian kode. Seluruh kode diuji dan hasil ujinya dilampirkan
    di folder <code>bukti/</code> pada repositori.
  </div>
</section>

<section class="toc">
  <h2>Daftar Isi</h2>
  <ol>
    <li>Soal 1: Desain Arsitektur Data, Normalisasi &amp; Asas Berpasangan (25%)</li>
    <li>Soal 2: Otomasi Bisnis, Stored Procedure &amp; Trigger Persediaan (40%)</li>
    <li>Soal 3: Purwarupa Web Full-Stack &amp; Orkestrasi AI Tools (35%)</li>
    <li>Lampiran: Struktur repositori, cara menjalankan, dan bukti uji</li>
  </ol>
  <h3>Ringkasan</h3>
  <table>
    <tr><th>Soal</th><th>Artefak utama</th><th>Bukti uji</th></tr>
    <tr><td>1</td><td>ERD, DDL 3 tabel (PK, FK ON DELETE RESTRICT, CHECK) + constraint trigger Debit = Kredit</td><td>8 skenario: 1 diterima, 7 pelanggaran ditolak</td></tr>
    <tr><td>2</td><td><code>trg_update_stock_and_journal()</code> + jurnal HPP/Persediaan otomatis; <code>SELECT … FOR UPDATE</code>, SERIALIZABLE</td><td>6 skenario + rekonsiliasi GL = stok fisik; simulasi 2 kasir bersamaan</td></tr>
    <tr><td>3</td><td>Formulir web (HTML+Tailwind+JS) + Supabase RPC; immutability, storno, created_by/created_at/hash SHA-256 berantai, audit log</td><td>15 skenario + uji keamanan anon + tindak lanjut NotebookLM</td></tr>
  </table>
</section>
"""

soal1 = section("soal1/JAWABAN_SOAL1.md")
soal1 += "<h3>Cuplikan bukti uji Soal 1 (PostgreSQL 16)</h3>" + excerpt(
    ROOT / "bukti/uji_soal1.txt", "=== UJI 2")

soal2 = section("soal2/JAWABAN_SOAL2.md")
soal2 += "<h3>Cuplikan bukti: trigger & rekonsiliasi</h3>" + excerpt(
    ROOT / "bukti/uji_soal2_trigger.txt", "=== UJI 4", "=== LOG MUTASI")
soal2 += excerpt(ROOT / "bukti/uji_soal2_trigger.txt", "=== JURNAL OTOMATIS")
soal2 += "<h3>Cuplikan bukti: simulasi dua kasir</h3>" + excerpt(
    ROOT / "bukti/uji_soal2_concurrency.txt", "# DEMO A")

soal3 = section("soal3/JAWABAN_SOAL3.md")
soal3 += "<h2>Dokumentasi tangkapan layar Soal 3</h2>"
soal3 += "<h3>3.1a Gemini Canvas</h3>" + figrow([
    (SHOT / "gemini_canvas_01_prompt.jpg", "Prompt dikirim ke Gemini (mode Canvas)"),
    (SHOT / "gemini_canvas_02_respon.jpg", "Gemini membuat file HTML di Canvas"),
]) + figrow([
    (SHOT / "gemini_canvas_04_preview_tabel.jpg", "Preview: tabel jurnal dinamis + indikator SEIMBANG"),
    (SHOT / "gemini_canvas_05_preview_indikator.jpg", "Preview: checklist aturan bisnis & tombol Submit"),
])
soal3 += "<h3>Versi final formulir (setelah code review & integrasi Supabase)</h3>" + figure(
    SHOT / "form_tidak_seimbang.png", "Tidak seimbang: indikator merah, selisih ditampilkan, Submit terkunci") + figure(
    SHOT / "form_seimbang.png", "Seimbang: semua aturan ✓, Submit aktif")
e2e = sorted(SHOT.glob("e2e_*"))
if e2e:
    soal3 += "<h3>Uji end-to-end dengan Supabase (pengguna login)</h3>" + "".join(
        figure(p, p.stem.replace("e2e_", "").replace("_", " ")) for p in e2e)
else:
    soal3 += figure(SHOT / "form_setelah_submit.png",
                    "Setelah submit: jurnal POSTED dengan created_by & hash, storno, audit log, verifikasi hash")
soal3 += "<h3>3.1b NotebookLM</h3>" + figrow([
    (SHOT / "notebooklm_01_sumber.jpg", "Enam sumber: PSAK 2/207, setara kas, IAS 7, penomoran IAI, spesifikasi & kode"),
    (SHOT / "notebooklm_03_memo_audit.jpg", "Jawaban NotebookLM: memo audit internal"),
]) + figure(SHOT / "notebooklm_04_temuan_A.jpg", "Temuan A: setara kas & cerukan bank belum dimodelkan", "60%")
soal3 += "<h3>Tindak lanjut temuan NotebookLM (bukti uji)</h3>" + excerpt(
    ROOT / "bukti/uji_soal3_perbaikan_notebooklm.txt", "=== UJI 1")
soal3 += "<h3>3.2 Bukti uji audit trail</h3>" + excerpt(
    ROOT / "bukti/uji_soal3_audit_trail.txt", "=== UJI 5", "=== UJI 9") + excerpt(
    ROOT / "bukti/uji_soal3_audit_trail.txt", "=== UJI 13", "=== UJI 15")
soal3 += figure(SHOT / "supabase_verifikasi_hash.jpg",
                "Verifikasi hash dijalankan di Supabase SQL Editor (project cloud)", "55%")
soal3 += "<h3>Uji keamanan Supabase dari browser (tanpa login)</h3>" + excerpt(
    ROOT / "bukti/uji_soal3_keamanan_supabase_anon.txt", "1)")

lampiran = md_to_html((ROOT / "README.md").read_text(), ROOT)
lampiran = re.sub(r"<h1[^>]*>.*?</h1>", "", lampiran, count=1, flags=re.S)

CSS = """
@page { size: A4; margin: 18mm 16mm 20mm 16mm; }
* { box-sizing: border-box; }
body { font-family: Inter, 'DejaVu Sans', sans-serif; font-size: 9.6pt; line-height: 1.5; color: #1c2430; }
h1, h2, h3 { line-height: 1.25; color: #0f3d36; }
h1 { font-size: 17pt; margin: 0 0 8pt; padding-bottom: 6pt; border-bottom: 2px solid #0f5c4d; }
h2 { font-size: 12.5pt; margin: 16pt 0 6pt; }
h3 { font-size: 10.5pt; margin: 12pt 0 4pt; }
p { margin: 4pt 0 6pt; }
a { color: #0f5c4d; }
code { font-family: 'DejaVu Sans Mono', monospace; font-size: 8.3pt; background: #f1efe8; padding: 0 2px; border-radius: 2px; }
pre { font-family: 'DejaVu Sans Mono', monospace; font-size: 7.4pt; line-height: 1.35; background: #f6f4ef;
      border: 1px solid #ddd8ca; border-radius: 4px; padding: 7pt 8pt; white-space: pre-wrap; word-break: break-word; }
pre code { background: none; padding: 0; font-size: inherit; }
pre.evidence { background: #10201d; color: #d8efe8; border-color: #10201d; }
table { border-collapse: collapse; width: 100%; margin: 6pt 0 10pt; font-size: 8.6pt; page-break-inside: auto; }
th, td { border: 1px solid #d9d4c7; padding: 3.5pt 5pt; vertical-align: top; text-align: left; }
th { background: #eef3f1; }
tr { page-break-inside: avoid; }
img { max-width: 100%; height: auto; }
figure { margin: 8pt 0; text-align: center; page-break-inside: avoid; }
figure img { border: 1px solid #d9d4c7; border-radius: 4px; max-height: 120mm; object-fit: contain; }
figcaption { font-size: 8pt; color: #5b6470; margin-top: 3pt; }
.figrow { display: flex; gap: 10pt; } .figrow > div { flex: 1; }
.part { page-break-before: always; }
blockquote { margin: 6pt 0; padding: 4pt 10pt; border-left: 3px solid #0f5c4d; background: #f3f8f6; }
.cover { height: 250mm; display: flex; flex-direction: column; justify-content: center; }
.cover .inst { letter-spacing: .08em; font-size: 9pt; color: #0f5c4d; font-weight: 600; }
.cover h1 { font-size: 30pt; border: 0; margin: 10pt 0 4pt; }
.cover .sub { font-size: 12pt; color: #5b6470; margin-bottom: 18pt; }
.cover .ident { width: auto; font-size: 10.5pt; } .cover .ident th { background: none; border: 0; padding-right: 18pt; color: #5b6470; font-weight: 500; }
.cover .ident td { border: 0; font-weight: 600; }
.cover .links { margin-top: 18pt; padding: 10pt 12pt; border: 1.5px solid #0f5c4d; border-radius: 6px; font-size: 9.5pt; }
.cover .links p { margin: 3pt 0 7pt; } .cover .links a { word-break: break-all; }
.cover .tools { margin-top: 12pt; font-size: 8.5pt; color: #5b6470; }
.toc { page-break-before: always; }
"""

doc = f"""<!DOCTYPE html><html lang="id"><head><meta charset="utf-8"/>
<title>Jawaban UTS Coding - Zayyan Beryl</title><style>{CSS}</style></head><body>
{cover}
<div class="part">{soal1}</div>
<div class="part">{soal2}</div>
<div class="part">{soal3}</div>
<div class="part"><h1>Lampiran: Struktur Repositori &amp; Cara Menjalankan</h1>{lampiran}</div>
</body></html>"""

html_path = ROOT / "tools" / "_jawaban.html"
html_path.write_text(doc)

footer = ('<div style="font-family:Inter,sans-serif;font-size:7.5pt;color:#7a8290;width:100%;'
          'padding:0 16mm;display:flex;justify-content:space-between;">'
          '<span>UTS Pemrograman/Coding · Zayyan Beryl · 12030124140283 · Kelas E</span>'
          '<span>Hal. <span class="pageNumber"></span> / <span class="totalPages"></span></span></div>')

with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page()
    page.goto(f"file://{html_path}")
    page.wait_for_load_state("networkidle")
    page.pdf(path=str(OUT), format="A4", print_background=True, display_header_footer=True,
             header_template="<div></div>", footer_template=footer,
             margin={"top": "18mm", "bottom": "20mm", "left": "16mm", "right": "16mm"})
    browser.close()
html_path.unlink()
print("PDF:", OUT)
