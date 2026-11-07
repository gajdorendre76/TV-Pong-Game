# Windows és Linux kiadások – TV Pong Game 1.8

1. Töltsd fel a projekt összes fájlját (a `.github/workflows/build.yml` fájlt is) GitHubra.
2. GitHubon nyisd meg **Actions → Build Windows and Linux downloads → Run workflow**.
3. A futás végén a **Artifacts** részen két ZIP lesz: Windows és Linux, 64 bites.
4. Ha nyilvános Releases kiadást szeretnél, a GitHub felületén hozz létre egy `v1.8.0` taget (vagy pushold a taget); a workflow ezután a ZIP-eket a Release-hez is hozzáadja.

A Windows csomagban az `.exe` mellett a `.pck` fájlt is tartsd meg, ha külön exportálja a Godot. Linuxon az `.x86_64` mellett szintén szükséges lehet a `.pck`. A telefonos vezérléshez mindkét gépen azonos helyi Wi-Fi kell, és a tűzfalban a játék portját engedélyezni kell.

**Fontos:** a jelenlegi QR-kódgenerátor a külső `qrencode` programot hívja. Windowson ez nélküle nem működik, de a játék által jelzett helyi URL manuálisan megnyitható a mobil böngészőben. Linuxon telepíthető: `sudo pacman -S qrencode`.

A zenék, grafikák, intró publikálásához szükséges terjesztési jogokat ellenőrizd.
