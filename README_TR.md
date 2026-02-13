# 🌐 WireGuard Client Gateway

<div align="center">

![WireGuard Client Gateway Installer](docs/screenshot.png)

**Raspberry Pi veya herhangi bir Debian cihazı, tüm ağ trafiğinizi VPN üzerinden yönlendiren bir ağ geçidine dönüştürün.**

[English](README.md) | [Türkçe](README_TR.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](install.sh)

</div>

---

## 📖 Bu Nedir?

Bir bash script ile **Raspberry Pi**'yi (veya herhangi bir Debian tabanlı cihazı) yerel ağınız için **VPN ağ geçidine** dönüştürür. Kurulumdan sonra, ağınızdaki herhangi bir cihaz sadece varsayılan ağ geçidini değiştirerek tüm trafiğini VPN üzerinden yönlendirebilir.

> **Önce sunucu mu lazım?** Bu script WireGuard sunucusundan alınmış bir `client.conf` gerektirir. Sunucu kurmak için 👉 [wg-secure-gateway](https://github.com/sinezty/wg-secure-gateway)

## 🧭 Nasıl Çalışır?

```
┌──────────────────┐       ┌───────────────────┐       ┌──────────────┐
│  Cihazlarınız    │       │   Raspberry Pi    │       │  VPN Sunucu  │
│                  │       │   (bu script)     │       │              │
│  Telefon, PC,    │──────▸│                   │══════▸│  Sunucu      │──▸ İnternet
│  Smart TV vb.    │  LAN  │  Ağ Geçidi IP:    │  WG   │  Public IP   │
│                  │       │  192.168.1.x      │ Tünel │              │
│ GW: 192.168.1.x  │       │                   │       │              │
└──────────────────┘       └───────────────────┘       └──────────────┘
```

1. Bu scripti Raspberry Pi'ye **kurun**
2. VPN sunucusundan aldığınız `client.conf` dosyasını **içe aktarın**
3. Herhangi bir cihazın varsayılan ağ geçidini RPi IP'sine **yönlendirin**
4. ✅ Tüm trafik artık şifreli VPN tünelinden geçer

## ✨ Özellikler

- 🌐 **Tam Ağ Geçidi** — Ağdaki herhangi bir cihaz VPN'i kullanabilir, client'a yazılım gerekmez
- 📡 **Statik IP Kurulumu** — DHCP IP'yi otomatik algılar, statik'e dönüştürür (dhcpcd / netplan / interfaces)
- 📂 **Config İçe Aktarma** — İçeriği yapıştırın veya dosya yolu belirtin, format doğrulaması ile
- 🔀 **Otomatik NAT** — IP yönlendirme + MASQUERADE kuralları otomatik yapılandırılır
- 💾 **Kalıcı Kurallar** — iptables kuralları yeniden başlatmalarda korunur
- ✅ **Bağlantı Doğrulama** — Kurulum sonrası tünel ve public IP otomatik kontrol
- 🔄 **Tekrar Çalıştırılabilir** — Bir şeyler ters giderse tekrar çalıştırın, önceki ayarları temizler
- 🖥️ **Çoklu Platform** — Raspbian, DietPi, Debian 11+, Ubuntu 20.04+

## 🚀 Hızlı Başlangıç

> ⏱️ Kurulum yaklaşık **2–3 dakika** sürer.

### Adım 1: VPN Sunucu Kurun

Henüz kurmadıysanız, WireGuard sunucu kurun ve `client.conf` alın:

```bash
# Uzak VPS/sunucunuzda:
curl -fsSL https://raw.githubusercontent.com/sinezty/wg-secure-gateway/main/install.sh | sudo bash
```

### Adım 2: `client.conf` Dosyasını RPi'ye Kopyalayın

```bash
# Sunucudan RPi'ye:
scp /etc/wireguard/client.conf pi@<RPI_IP>:~/client.conf
```

### Adım 3: Bu Scripti RPi'de Çalıştırın

```bash
curl -fsSL https://raw.githubusercontent.com/sinezty/wg-client-gateway/main/install.sh | sudo bash
```

## 📦 Alternatif Kurulum

```bash
# İndirip çalıştırma
wget https://raw.githubusercontent.com/sinezty/wg-client-gateway/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

## ⚙️ Yapılandırma

Script interaktif olarak yapılandırır:

| Ayar | Varsayılan | Açıklama |
|------|-----------|----------|
| Statik IP | Mevcut DHCP IP | Mevcut IP'yi koruyabilir veya yenisini girebilirsiniz |
| Subnet | Otomatik algılanır | CIDR gösterimi (ör: /24) |
| Gateway | Otomatik algılanır | Routerınızın IP adresi |
| Cihaz DNS | 1.1.1.1 | Gateway cihazının kendi DNS'i |
| client.conf | — | WireGuard client yapılandırma dosya yolu |

## 📋 Kurulum Süreci

```
1. Sistem Kontrolleri   → Root yetki, mevcut config
2. Ağ Algılama          → Arayüz, IP, subnet, gateway
3. Statik IP Kurulumu   → DHCP → Statik (dhcpcd / netplan / interfaces)
4. Config İçe Aktarma   → [Interface] + [Peer] + PrivateKey doğrulama
5. Paket Kurulumu       → wireguard, iptables, iptables-persistent
6. IP Yönlendirme       → net.ipv4.ip_forward = 1
7. NAT Kuralları        → PostUp/PostDown ile MASQUERADE
8. Servis Başlatma      → wg-quick@wg0 etkinleştirme
9. Doğrulama            → Tünel durumu + public IP kontrolü
```

## 📱 Gateway Kullanımı

Kurulumdan sonra herhangi bir cihazın **varsayılan ağ geçidini** değiştirmeniz yeterli:

### 🖥️ Windows
`Ayarlar` → `Ağ` → `IPv4` → `Ağ Geçidi`: **RPi IP adresi**

### 🐧 Linux
```bash
sudo ip route replace default via <RPi_IP>
```

### 🍎 macOS
`Sistem Tercihleri` → `Ağ` → `Gelişmiş` → `TCP/IP` → `Yönlendirici`: **RPi IP adresi**

### 📱 iPhone / Android
`Wi-Fi Ayarları` → `IP Yapılandır` → `Manuel` → `Yönlendirici/Ağ Geçidi`: **RPi IP adresi**

### 🌐 Router (En İyi Yöntem)
Router DHCP ayarlarında RPi IP'sini **varsayılan ağ geçidi** olarak ayarlayın → **tüm cihazlar** otomatik olarak VPN üzerinden yönlendirilir. Cihaz başına ayar gerekmez!

## 📁 Oluşturulan Dosyalar

| Dosya | Ne işe yarar |
|-------|-------------|
| `/etc/wireguard/wg0.conf` | Gateway NAT kuralları ile client config |
| `/var/log/wg_client_setup.log` | Tam kurulum logu |
| `/root/gateway_notes.txt` | Kurulum özeti ve kullanım talimatları |
| `/etc/sysctl.d/99-wg-gateway.conf` | IP yönlendirme yapılandırması |

## 🧰 Perde Arkası

Script, sunucudaki `client.conf` dosyasını alıp gateway yapılandırmasına dönüştürür:

```
Sunucu (wg-secure-gateway)           Client (wg-client-gateway)
┌─────────────────────┐              ┌─────────────────────────┐
│ /etc/wireguard/     │   kopyala    │ /etc/wireguard/         │
│   client.conf       │ ──────────▸  │   wg0.conf              │
│                     │              │   + PostUp/PostDown     │
│                     │              │   + NAT MASQUERADE      │
│                     │              │   + AllowedIPs kontrol  │
└─────────────────────┘              └─────────────────────────┘
```

- Sunucudaki `client.conf` → client cihazda `/etc/wireguard/wg0.conf` olur
- Script **PostUp/PostDown** gateway NAT kurallarını `[Interface]` bölümüne ekler
- **AllowedIPs = 0.0.0.0/0** kontrolü yapar (tüm trafik VPN'den geçmesi için gerekli)
- config'de mevcut PostUp/PostDown varsa, gateway kuralları ile değiştirilir

> 💡 **Tekrar çalıştırılabilir**: Hata yaptıysanız veya yeniden yapılandırmak istiyorsanız, scripti tekrar çalıştırın. Mevcut servisi durduracak, eski iptables kurallarını temizleyecek ve sıfırdan yapılandıracaktır.

## 💻 Gereksinimler

- **Cihazlar**: Raspberry Pi, herhangi bir Debian tabanlı SBC veya mini PC
- **İşletim Sistemi**: Raspbian, DietPi, Ubuntu 20.04+ veya Debian 11+
- **Erişim**: Root veya sudo yetkisi
- **Ağ**: Aktif internet + LAN bağlantısı
- **VPN Sunucu**: WireGuard sunucusundan alınmış `client.conf`

## 🔗 İlgili Projeler

| Proje | Açıklama |
|-------|----------|
| 👉 **[wg-secure-gateway](https://github.com/sinezty/wg-secure-gateway)** | Bu gateway'in bağlandığı WireGuard VPN sunucusunu kurun |

## 🤝 Katkıda Bulunma

Pull request'ler memnuniyetle karşılanır. Büyük değişiklikler için lütfen önce issue açarak tartışalım.

## 📝 Lisans

MIT

## 👤 Yazar

BarışY
