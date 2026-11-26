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

Lite menjalankan UI statis, Flask/Waitress, dan downloader sebagai service `systemd`; **tidak memasang atau menjalankan Docker/Chromium**. Target installer adalah Debian/Ubuntu dengan `systemd`, akun root atau akses `sudo`, dan akses internet untuk mengunduh paket Python. Python **3.10 atau lebih baru** diperlukan; Python **3.12.3 didukung**.

### Instalasi

Jalankan launcher dari folder proyek: `deploy_mini.bat` di Windows atau `bash ./deploy_mini.sh` di Linux/macOS. Sediakan OpenSSH (`ssh`/`scp`) dan `tar` pada komputer yang menjalankan launcher. Masukkan IPv4 server dan username SSH, lalu verifikasi fingerprint SSH jika diminta. Di server, berikan akses `sudo`/root dan buat username serta password aplikasi saat installer memintanya; password aplikasi minimal 6 karakter dan terpisah dari password SSH.

Launcher mengirim bundle Mini ke server dan menjalankan installer. `.env`, `config`, serta `data` lokal tidak dikirim. Installer menampilkan versi, tahap instalasi, dan heartbeat tiap 5 detik selama proses panjang; output lengkap disimpan di log server. Installer membuat `/mnt/share` **hanya jika belum ada**; jika direktori itu sudah ada, installer menggunakannya tanpa mengubah direktori tersebut. Source, virtualenv, release, log installer, konfigurasi, dan unduhan berada di `/mnt/share/drive-tasks-mini/`. Pastikan filesystem tersebut dapat ditulis dan menjalankan virtualenv oleh user service `drive-tasks-mini`.

Pada instalasi pertama, konfigurasi dan unduhan lama dari `/var/lib/drive-tasks-mini/` disalin tanpa menghapus sumber lama; source lama di `/opt/drive-tasks-mini/` juga dipertahankan. Setelah health check berhasil, service berjalan langsung dan otomatis aktif saat server boot. Buka `http://IP-SERVER:2121`; batasi akses TCP 2121 ke jaringan tepercaya.

### Penggunaan

Login menggunakan kredensial aplikasi. Pilih **+ Download**, masukkan URL file langsung, lalu tekan **Mulai**. Batas kecepatan task bersifat opsional; nilai `0` memakai batas global. Opsi lanjutan menyediakan referer, cookie, dan nama file. Dari kartu task, pantau progres, batalkan task yang berjalan, ulangi task gagal, hapus riwayat task, atau ambil file setelah selesai. Batas global dapat diubah dari halaman utama; nilai `0` berarti tanpa batas, dan limit task tidak dapat melewati limit global.

Lite tidak menampilkan tombol **Buka Browser** dan tidak menyediakan direktori atau endpoint file-browser; endpoint browser mengembalikan 404. Lite hanya mengelola unduhan yang dimulai melalui URL di aplikasinya.

### Update

Naikkan nomor patch `VERSION` di source lokal, misalnya dari `1.0.0` menjadi `1.0.1`, lalu jalankan launcher yang sama: `deploy_mini.bat` atau `bash ./deploy_mini.sh`. Installer hanya memasang versi yang lebih baru; versi sama atau lebih lama dilewati. Update membangun release dan virtualenv baru, lalu me-restart service dan menjalankan health check. Jika health check gagal, installer memulihkan release dan konfigurasi service sebelumnya. Data unduhan dan konfigurasi tetap berada di direktori state.

### Cek status dan pemecahan masalah

Jalankan perintah berikut di server:

```bash
sudo systemctl is-active drive-tasks-mini
sudo systemctl is-enabled drive-tasks-mini
sudo systemctl status drive-tasks-mini --no-pager
```

Kondisi normal adalah `active` dan `enabled`. `inactive` atau `failed` berarti service tidak sedang berjalan; `disabled` berarti service tidak diatur untuk mulai otomatis setelah reboot. Untuk melihat log terbaru atau mengikuti log langsung:

```bash
sudo journalctl -u drive-tasks-mini -n 100 --no-pager
sudo journalctl -u drive-tasks-mini -f
```

Log aplikasi tersimpan di `/mnt/share/drive-tasks-mini/state/config/drive-tasks.log`. Log lengkap installer—baik sukses maupun gagal—tersimpan di `/mnt/share/drive-tasks-mini/install-logs/`. Lihat nama log terbaru dengan `sudo ls -lt /mnt/share/drive-tasks-mini/install-logs/`, lalu baca dengan `sudo tail -n 100 /mnt/share/drive-tasks-mini/install-logs/NAMA_LOG`.

Untuk memeriksa apakah aplikasi merespons di server (tanpa autentikasi, kode `401` diharapkan), jalankan:

```bash
python3 - <<'PY'
import urllib.error
import urllib.request

try:
    with urllib.request.urlopen("http://127.0.0.1:2121/api/settings", timeout=3) as response:
        print(response.status)
except urllib.error.HTTPError as error:
    print(error.code)
PY
```

Respons `401` berarti service merespons dan meminta autentikasi; `200` menunjukkan endpoint berhasil merespons jika autentikasi sudah diberikan. Jika status service `failed`, baca `journalctl` untuk penyebabnya. Setelah memperbaiki masalah konfigurasi, service dapat dijalankan ulang dengan `sudo systemctl restart drive-tasks-mini`. Pastikan `/mnt/share` dapat ditulis/dieksekusi, TCP 2121 diizinkan dari jaringan lokal, dan server memiliki akses internet untuk proses update.

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
