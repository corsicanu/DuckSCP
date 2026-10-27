# Third-party notices

DuckSCP is licensed under the GNU General Public License v3.0 or later (see [LICENSE](LICENSE)).
It includes or links the following components. The full license texts are in [`licenses/`](licenses/), and they ship inside the app at `DuckSCP.app/Contents/Resources/licenses`.

| Component | How it is used | License |
|---|---|---|
| [libssh2](https://libssh2.org) | Statically linked (SSH, SFTP, SCP). Its headers are vendored in `Sources/CLibSSH2/include`. | BSD-3-Clause, [`licenses/libssh2-COPYING.txt`](licenses/libssh2-COPYING.txt) |
| [OpenSSL](https://www.openssl.org) libcrypto | Statically linked (cryptography for libssh2) | Apache-2.0, [`licenses/OpenSSL-LICENSE.txt`](licenses/OpenSSL-LICENSE.txt) |
| libcurl | macOS system library, dynamically linked, not redistributed | curl license (MIT/X-style) |
| zlib | macOS system library, dynamically linked, not redistributed | zlib license |

Apache-2.0 is compatible with GPL-3.0, but not with GPL-2.0. That is why DuckSCP is GPL-3.0-or-later.

The test helpers in `tools/` and `scripts/` install pyftpdlib, pyOpenSSL, WsgiDAV, cheroot, moto and Pillow into a private virtual environment. They are used only to run tests and generate icons, and are not shipped with the app.

"WinSCP" is a trademark of its authors. DuckSCP is not affiliated with or endorsed by the WinSCP project and contains no WinSCP source code. File formats (WinSCP.ini, PuTTY .ppk) are implemented from their observable structure for interoperability.
