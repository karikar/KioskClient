# KioskClient

KIOSK rendszer Boltoknak – Xorg nélküli, Debian alapú böngésző-kiosk
(Wayland + cage + Firefox ESR), GitHubról vezérelt allowlisttel és
automatikus programfrissítéssel.

- Dokumentáció, telepítés: [debian-kiosk/README.md](debian-kiosk/README.md)
- Telepítés: `sudo bash debian-kiosk/install.sh`
- Új verzió kiadása: `debian-kiosk/VERSION` átírása, majd `git tag vX.Y.Z`
  és `git push origin main vX.Y.Z` – a kioskok óránként figyelik a
  [Releases](../../releases) oldalt, és maguktól frissülnek.
