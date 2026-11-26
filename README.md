# Drive Tasks

Tersedia dua deployment terpisah: **Full** memakai Docker dan Chromium jarak jauh; **Lite** menjalankan aplikasi Python langsung tanpa Docker maupun Chromium. Keduanya memiliki downloader URL, autentikasi aplikasi, limit kecepatan, dan UI web bertema terang.

## Full (Docker, port 9191)

Gunakan Chromium sungguhan dari browser jarak jauh, atau masukkan URL ke downloader terkelola.

### Jalankan
```bash
cp .env.example .env
# Isi APP_USER dan APP_PASS; BIND_IP=0.0.0.0 menerima semua alamat IPv4
docker compose up -d --build
```
Buka `http://IP-SERVER:9191` untuk downloader dan `https://IP-SERVER:3001` untuk Chromium. Login memakai `APP_USER` dan `APP_PASS`; Chromium memakai sertifikat self-signed. Pastikan firewall mengizinkan TCP 9191 dan 3001 dari jaringan lokal saja.

### Instal/update di server lewat SSH
Launcher `deploy.sh` (Linux/macOS) dan `deploy.bat` (Windows) mengirim source terpilih ke `~/drive-tasks` lalu menjalankan `scripts/install-server.sh` di server. Keduanya meminta IPv4 dan username SSH; OpenSSH meminta password secara interaktif saat diperlukan dan tidak menyimpannya (bisa diminta lagi untuk koneksi SSH berikutnya). Pada koneksi pertama, verifikasi fingerprint host SSH.

Persyaratan server: Linux yang didukung installer resmi Docker, akses internet, dan akun root atau akun dengan `sudo`. Jika Docker/Compose belum tersedia, installer mencoba memasangnya. Pada pemasangan pertama, installer meminta username/password login aplikasi secara terpisah dari kredensial SSH. Username aplikasi menerima huruf, angka, titik, `_` dan `-`; password harus 6–128 karakter dan tidak boleh mengandung tanda petik tunggal atau backslash. Gunakan password yang lebih panjang bila memungkinkan. File `.env` server dibuat dengan permission terbatas dan tidak ditimpa saat update. Jika instalasi gagal, output dicatat di `~/drive-tasks-install-logs/`; log yang lebih lama dari 30 hari dibersihkan saat instalasi berikutnya.

Jalankan dari folder proyek: `bash ./deploy.sh` di Linux/macOS, atau klik/jalankan `deploy.bat` di Windows. Launcher Windows menggunakan batch langsung, tanpa PowerShell. Output deployment menunjukkan tahap [1/5]–[5/5]; jangan jalankan deployment kedua sebelum proses pertama selesai. Arsip hanya berisi source dan dokumentasi—`.env`, `config` dan `data` lokal tidak dikirim. Full mengunggah source dan membangun ulang layanan setiap kali; **Full belum memiliki pemeriksaan versi otomatis atau rollback otomatis**. Konfigurasi dan file download server dipertahankan. Setelah selesai, buka `http://IP-SERVER:9191` atau `https://IP-SERVER:3001`. Batasi port tersebut melalui firewall hanya untuk jaringan tepercaya.

Jika deployment gagal, baca output di jendela launcher atau log terbaru di `~/drive-tasks-install-logs/` pada server. Log lama dibersihkan saat installer berikutnya berjalan.

## Login Git dengan OTP
Di Windows, jalankan `git-auth.bat`. Batch membuka halaman login; selesaikan OTP sendiri di browser, lalu buat access token dengan akses baca/tulis minimum untuk repository. Setelah kembali ke jendela batch, `git ls-remote` memicu Git Credential Manager untuk menerima username dan token serta menyimpannya. Token tidak ditulis ke file proyek. URL Git saat ini memakai HTTP, jadi gunakan hanya pada LAN tepercaya—token tidak terenkripsi selama transmisi.

Downloader URL mencoba Standar, Browser, lalu TLS saat menerima 403/429. Batas global awal (default 5 MiB/s dari `.env`) dapat diubah dari UI dan disimpan di `config/settings.json`; nilai 0–1024 MiB/s, dengan `0` berarti tanpa batas. Setiap task juga dapat diberi limit sendiri; `0` mengikuti limit global, dan limit task tidak dapat melewati batas global. Batas ini tidak mencakup download yang dimulai langsung di Chromium.

File downloader disimpan di `DATA_DIR` pada host; download Chromium masuk ke `DATA_DIR/browser`. Keduanya tersedia di UI untuk diambil ke perangkat lokal dan dibersihkan setelah 30 hari.

## Lite (Python langsung, port 2121)

Lite menjalankan UI statis, Flask/Waitress, dan downloader sebagai service `systemd`; **tidak memasang atau menjalankan Docker/Chromium**. Target installer adalah Debian/Ubuntu dengan `systemd`, akun root atau akses `sudo`, dan internet untuk mengunduh paket Python. Python **3.10 atau lebih baru** diperlukan; Python **3.12.3 didukung**. Dependency aplikasi tercantum di `requirements.txt`.

Jalankan `bash ./deploy_mini.sh` di Linux/macOS atau `deploy_mini.bat` di Windows. Launcher mengirim bundle Mini dan menjalankan installer remote; `.env`, `config`, serta `data` lokal tidak dikirim. Output menampilkan versi yang dibandingkan, tahap instalasi, dan heartbeat tiap 5 detik saat perintah panjang masih berjalan; output lengkap proses juga disimpan di log server. Installer membandingkan versi numerik `VERSION` dan hanya mengaktifkan source jika versinya lebih baru. Untuk merilis update, naikkan versi, misalnya `1.0.0` ke `1.0.1`. Jika service gagal melewati health check, installer memulihkan konfigurasi systemd dan release sebelumnya. Log lebih dari 30 hari dibersihkan saat instalasi berikutnya.

Installer membuat `/mnt/share` hanya bila belum ada; direktori yang sudah ada digunakan tanpa mengubahnya. Source, virtualenv, release, log installer, konfigurasi, dan unduhan berada di `/mnt/share/drive-tasks-mini/`. Pada pemasangan pertama, installer meminta username/password aplikasi secara terpisah dari login SSH; password minimal 6 karakter. Kredensial disimpan sebagai JSON privat di `/mnt/share/drive-tasks-mini/state/config/credentials.json`, dan file unduhan berada di `/mnt/share/drive-tasks-mini/state/data/`. Jika ada instalasi Lite lama, konfigurasi dan unduhan dari `/var/lib/drive-tasks-mini/` disalin tanpa menghapus sumber lama; source lama di `/opt/drive-tasks-mini/` juga dipertahankan. Pastikan filesystem `/mnt/share` dapat ditulis dan mengeksekusi virtualenv oleh user service `drive-tasks-mini`. Service otomatis mulai saat boot dan listen pada TCP 2121. Buka `http://IP-SERVER:2121` dan batasi port tersebut ke jaringan tepercaya.

Periksa service dengan `sudo systemctl status drive-tasks-mini` dan log dengan `sudo journalctl -u drive-tasks-mini`. Log aplikasi berada di `/mnt/share/drive-tasks-mini/state/config/drive-tasks.log`; log installer berada di `/mnt/share/drive-tasks-mini/install-logs/`. Mode Lite tidak menampilkan tombol **Buka Browser**, tidak menyediakan direktori atau endpoint file-browser, dan endpoint browser mengembalikan 404.

## Batas download dan retensi

Pada kedua versi, batas global awal 5 MiB/s dapat diubah dari UI dan disimpan di direktori konfigurasi; nilai 0–1024 MiB/s, dengan `0` berarti tanpa batas. Setiap task juga dapat diberi limit sendiri; `0` mengikuti limit global, dan limit task tidak dapat melewati batas global. Unduhan downloader dan riwayat task dibersihkan setelah 30 hari. Full juga menyimpan file Chromium di `DATA_DIR/browser`; Lite tidak menyediakan fitur tersebut.

## Login Git dengan OTP

Di Windows, jalankan `git-auth.bat`. Batch membuka halaman login; selesaikan OTP sendiri di browser, lalu buat access token dengan akses baca/tulis minimum untuk repository. Setelah kembali ke jendela batch, `git ls-remote` memicu Git Credential Manager untuk menerima username dan token serta menyimpannya. Token tidak ditulis ke file proyek. URL Git saat ini memakai HTTP, jadi gunakan hanya pada LAN tepercaya—token tidak terenkripsi selama transmisi.

## Perintah Full
`tail -f config/drive-tasks.log` | `docker compose logs -f --tail=100` | `docker compose restart` | `docker compose down` | update: ganti file lalu `docker compose up -d --build`

## Catatan
- Pada Full, `APP_USER` dan `APP_PASS` wajib diisi; aplikasi dan Chromium memakai Basic auth. Jangan buka port 9191 atau 3001 ke internet.
- UI Chromium menyertakan terminal di dalam container; gunakan hanya pada LAN tepercaya dan jangan mount Docker socket atau folder host lain.
- Belum ada proteksi SSRF/CSRF; Cloudflare Access dan hardening dikerjakan belakangan.
- Cookie yang diisi tersimpan di `tasks.json` pada direktori konfigurasi masing-masing deployment.
- Log JSON aplikasi dirotasi harian dan dibersihkan setelah 30 hari. Log mencatat event task, status, durasi, dan ukuran unduhan tanpa URL lengkap atau cookie.
