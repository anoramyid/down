# Drive Tasks (Docker, port 9191)

Gunakan Chromium sungguhan dari browser jarak jauh, atau masukkan URL ke downloader terkelola. Hasilnya disimpan di server dan dapat diambil ke perangkat dari web lokal.

## Jalankan
```bash
cp .env.example .env
# Isi APP_USER dan APP_PASS; BIND_IP=0.0.0.0 menerima semua alamat IPv4
docker compose up -d --build
```
Buka `http://IP-SERVER:9191` untuk downloader dan `https://IP-SERVER:3001` untuk Chromium. Login memakai `APP_USER` dan `APP_PASS`; Chromium memakai sertifikat self-signed. Pastikan firewall mengizinkan TCP 9191 dan 3001 dari jaringan lokal saja.

## Instal/update di server lewat SSH
Launcher `deploy.sh` (Linux/macOS) dan `deploy.bat` (Windows) mengirim source terpilih ke `~/drive-tasks` lalu menjalankan `scripts/install-server.sh` di server. Keduanya meminta IPv4 dan username SSH; OpenSSH meminta password secara interaktif saat diperlukan dan tidak menyimpannya (bisa diminta lagi untuk koneksi SSH berikutnya). Pada koneksi pertama, verifikasi fingerprint host SSH.

Persyaratan server: Linux yang didukung installer resmi Docker, akses internet, dan akun root atau akun dengan `sudo`. Jika Docker/Compose belum tersedia, installer mencoba memasangnya. Pada pemasangan pertama, installer meminta username/password login aplikasi secara terpisah dari kredensial SSH. Username aplikasi menerima huruf, angka, titik, `_` dan `-`; password harus 6–128 karakter dan tidak boleh mengandung tanda petik tunggal atau backslash. Gunakan password yang lebih panjang bila memungkinkan. File `.env` server dibuat dengan permission terbatas dan tidak ditimpa saat update. Jika instalasi gagal, output dicatat di `~/drive-tasks-install-logs/`; log yang lebih lama dari 30 hari dibersihkan saat instalasi berikutnya.

Jalankan dari folder proyek: `bash ./deploy.sh` di Linux/macOS, atau klik/jalankan `deploy.bat` di Windows. Launcher Windows menggunakan batch langsung, tanpa PowerShell. Arsip deployment hanya berisi source dan dokumentasi; `.env`, `config` dan `data` lokal tidak dikirim. Update berikutnya menimpa source aplikasi di server tetapi mempertahankan konfigurasi dan file download server. Setelah selesai, buka `http://IP-SERVER:9191` atau `https://IP-SERVER:3001`. Batasi port tersebut melalui firewall hanya untuk jaringan tepercaya.

## Login Git dengan OTP
Di Windows, jalankan `git-auth.bat`. Batch membuka halaman login; selesaikan OTP sendiri di browser, lalu buat access token dengan akses baca/tulis minimum untuk repository. Setelah kembali ke jendela batch, `git ls-remote` memicu Git Credential Manager untuk menerima username dan token serta menyimpannya. Token tidak ditulis ke file proyek. URL Git saat ini memakai HTTP, jadi gunakan hanya pada LAN tepercaya—token tidak terenkripsi selama transmisi.

Downloader URL mencoba Standar, Browser, lalu TLS saat menerima 403/429. Batas global awal (default 5 MiB/s) dapat diubah dari UI dan disimpan di `config/settings.json`; nilai 0–1024 MiB/s, dengan `0` berarti tanpa batas. Setiap task juga dapat diberi limit sendiri; `0` mengikuti limit global, dan limit task tidak dapat melewati batas global. Batas ini tidak mencakup download yang dimulai langsung di Chromium.

File downloader disimpan di `DATA_DIR` pada host; download Chromium masuk ke `DATA_DIR/browser`. Keduanya tersedia di UI untuk diambil ke perangkat lokal dan dibersihkan setelah 30 hari.

## Perintah
`tail -f config/drive-tasks.log` | `docker compose logs -f --tail=100` | `docker compose restart` | `docker compose down` | update: ganti file lalu `docker compose up -d --build`

## Catatan
- `APP_USER` dan `APP_PASS` wajib diisi; aplikasi dan Chromium memakai Basic auth. Jangan buka port 9191 atau 3001 ke internet.
- UI Chromium menyertakan terminal di dalam container; gunakan hanya pada LAN tepercaya dan jangan mount Docker socket atau folder host lain.
- Belum ada proteksi SSRF/CSRF; Cloudflare Access dan hardening dikerjakan belakangan.
- Cookie yang diisi tersimpan di `config/tasks.json`.
- File unduhan dan riwayat task dihapus otomatis setelah 30 hari.
- Log JSON aplikasi tersimpan di `config/drive-tasks.log`, dirotasi harian dan dibersihkan setelah 30 hari. Log mencatat event task, status, durasi, dan ukuran unduhan tanpa URL lengkap atau cookie.
