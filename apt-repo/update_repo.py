#!/usr/bin/env python3
import os, re, time, subprocess, hashlib, requests, sys, urllib.parse
from pathlib import Path
from functools import cmp_to_key

# =========================
#  Configuración general
# =========================
DISCORD_LATEST = "https://discord.com/api/download?platform=linux&format=deb"
REPO_DIR = Path("/var/www/debian-redroot")
DIST = "stable"
COMP = "main"
GPG_KEY_ID = "Pablo M. Duval <pabloduval@proton.me>"
CHECK_INTERVAL_SECS = 900  # 15 minutos

# Arquitecturas: amd64 real; i386/arm64/armhf índices vacíos (para evitar avisos)
PRIMARY_ARCH = "amd64"
ARCHES = ["amd64", "i386", "arm64", "armhf"]

# =========================
#  GitHub Desktop (GitHub)
# =========================
GH_DESKTOP_REPO = "shiftkey/desktop"
GH_DESKTOP_SUBDIR = "github-desktop"

# =========================
#  FreeTube (GitHub)
# =========================
FREETUBE_REPO = "FreeTubeApp/FreeTube"
FREETUBE_SUBDIR = "freetube"
FREETUBE_ALLOW_PRERELEASE = True
GITHUB_API = "https://api.github.com"

# =========================
#  Redroot Kernels (Debian-RedRoot)
# =========================
REDROOT_REPO = "RedrootDEV/Debian-RedRoot"   # <-- ajusta si cambia
KERNEL_SUBDIR = "redroot-kernels"            # subcarpeta en pool/main
CPU_PROFILES = ["znver3", "tigerlake", "x86-64-v3", "x86-64"]

# regex para nombres de assets (image/headers) - excluye dbg/libc
KIMG_RE = re.compile(r"^linux-image-(?P<ver>[^_]+)-tkg-redroot-(?P<cpu>[^_]+)_.*amd64\.deb$")
KHDR_RE = re.compile(r"^linux-headers-(?P<ver>[^_]+)-tkg-redroot-(?P<cpu>[^_]+)_.*amd64\.deb$")

# =========================
#  Utilidades / log
# =========================
def log(msg): print(f"[INFO] {msg}", flush=True)
def warn(msg): print(f"[WARN] {msg}", flush=True)
def err(msg): print(f"[ERROR] {msg}", file=sys.stderr, flush=True)

def sh(cmd, **kw):
    kw.setdefault("check", True)
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        err(f"cmd failed: {' '.join(cmd)}\nstdout:\n{r.stdout}\nstderr:\n{r.stderr}")
        raise subprocess.CalledProcessError(r.returncode, cmd, r.stdout, r.stderr)
    return r

# Comparación de versiones usando dpkg
def deb_cmp(a: str, b: str) -> int:
    r = subprocess.run(["dpkg", "--compare-versions", a, "lt", b])
    if r.returncode == 0: return -1
    r = subprocess.run(["dpkg", "--compare-versions", a, "gt", b])
    if r.returncode == 0: return 1
    return 0

def sort_versions_debian(versions):
    return sorted(set(versions), key=cmp_to_key(deb_cmp))

# =========================
#  Infra repo
# =========================
def ensure_layout():
    for arch in ARCHES:
        (REPO_DIR / "dists" / DIST / COMP / f"binary-{arch}").mkdir(parents=True, exist_ok=True)
    (REPO_DIR / "pool" / "main" / "discord").mkdir(parents=True, exist_ok=True)
    (REPO_DIR / "pool" / "main" / FREETUBE_SUBDIR).mkdir(parents=True, exist_ok=True)
    (REPO_DIR / "pool" / "main" / GH_DESKTOP_SUBDIR).mkdir(parents=True, exist_ok=True)
    (REPO_DIR / "pool" / "main" / KERNEL_SUBDIR).mkdir(parents=True, exist_ok=True)

# =========================
#  Discord
# =========================
def latest_deb_url_and_version():
    log(f"Resolviendo URL final desde {DISCORD_LATEST}")
    r = requests.get(DISCORD_LATEST, allow_redirects=True, timeout=30)
    r.raise_for_status()
    final = r.url
    log(f"URL final: {final}")
    m = re.search(r"([0-9]+\.[0-9]+(?:\.[0-9]+)*)", final)
    if not m:
        raise RuntimeError(f"No pude extraer versión de: {final}")
    version = m.group(1)
    log(f"Versión detectada: {version}")
    return final, version

# =========================
#  FreeTube (GitHub releases)
# =========================
def github_latest_asset(repo: str, allow_prerelease: bool = True):
    url = f"{GITHUB_API}/repos/{repo}/releases?per_page=10"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "apt-repo-bot/1.0",
    }
    tok = os.getenv("GITHUB_TOKEN")
    if tok:
        headers["Authorization"] = f"Bearer {tok}"

    r = requests.get(url, headers=headers, timeout=30)
    r.raise_for_status()
    releases = r.json()
    for rel in releases:
        if rel.get("draft"):
            continue
        if (not allow_prerelease) and rel.get("prerelease"):
            continue
        for a in rel.get("assets") or []:
            name = a.get("name","")
            if name.endswith("amd64.deb"):
                dl = a.get("browser_download_url")
                tag = (rel.get("tag_name") or "").lstrip("v")
                if not tag:
                    m = re.search(r"([0-9]+\.[0-9]+(?:\.[0-9]+)*)", name)
                    tag = m.group(1) if m else "0"
                return dl, tag, name
    raise RuntimeError("No encontré asset amd64.deb en releases de GitHub")

def freetube_latest_deb_url_and_version():
    url, version, fname = github_latest_asset(FREETUBE_REPO, FREETUBE_ALLOW_PRERELEASE)
    return url, version, fname

# =========================
#  GitHub Desktop (GitHub releases)
# =========================
def github_desktop_latest_deb_url_and_version():
    url = f"{GITHUB_API}/repos/{GH_DESKTOP_REPO}/releases?per_page=10"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "apt-repo-bot/1.0",
    }
    tok = os.getenv("GITHUB_TOKEN")
    if tok:
        headers["Authorization"] = f"Bearer {tok}"

    r = requests.get(url, headers=headers, timeout=30)
    r.raise_for_status()
    for rel in r.json():
        if rel.get("draft"):
            continue
        # Tomar el primer asset .deb amd64
        for a in rel.get("assets") or []:
            name = a.get("name", "")
            if name.endswith(".deb") and "amd64" in name:
                dl = a.get("browser_download_url")
                tag = (rel.get("tag_name") or "").lstrip("v")
                if not tag:
                    m = re.search(r"([0-9]+\.[0-9]+(?:\.[0-9]+)*)", name)
                    tag = m.group(1) if m else "0"
                return dl, tag, name
    raise RuntimeError("No encontré .deb amd64 para GitHub Desktop")

# =========================
#  Redroot Kernels helpers
# =========================
def github_latest_release_assets(repo: str):
    """Devuelve la lista de assets del release más reciente (no draft)."""
    url = f"{GITHUB_API}/repos/{repo}/releases?per_page=5"
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "apt-repo-bot/1.0"}
    tok = os.getenv("GITHUB_TOKEN")
    if tok:
        headers["Authorization"] = f"Bearer {tok}"

    r = requests.get(url, headers=headers, timeout=30); r.raise_for_status()
    for rel in r.json():
        if rel.get("draft"):
            continue
        return rel.get("assets") or []
    return []

def latest_redroot_kernel_assets():
    """Agrupa image/headers por CPU; excluye dbg/libc. Requiere ambos paquetes."""
    assets = github_latest_release_assets(REDROOT_REPO)
    out = {cpu: {"image": None, "headers": None, "version": None} for cpu in CPU_PROFILES}
    for a in assets:
        name = a.get("name","")
        if not name.endswith(".deb"):
            continue
        if "-dbg" in name or "libc-dev" in name:
            continue
        m = KIMG_RE.match(name) or KHDR_RE.match(name)
        if not m:
            continue
        ver = m.group("ver"); cpu = m.group("cpu")
        if cpu not in out:
            continue
        url = a.get("browser_download_url")
        if KIMG_RE.match(name):
            out[cpu]["image"] = (url, ver, name)
        else:
            out[cpu]["headers"] = (url, ver, name)
        out[cpu]["version"] = ver
    return {cpu: info for cpu, info in out.items() if info["image"] and info["headers"]}

# =========================
#  Aux
# =========================
def sha256sum(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def download_if_needed(url: str, version: str, subdir: str, target_name: str | None = None, *, cleanup_glob: str | None = "*.deb"):
    pool_dir = REPO_DIR / "pool" / "main" / subdir
    if target_name is None:
        target_name = os.path.basename(urllib.parse.urlparse(url).path) or f"{subdir}_{version}_{PRIMARY_ARCH}.deb"
    target = pool_dir / target_name

    if target.exists():
        log(f"Ya existe {target.name}; no se descarga.")
        return None

    tmp_path = pool_dir / (target.name + ".part")
    log(f"Descargando {subdir} {version} → {target.name}")
    with requests.get(url, stream=True, timeout=180) as r:
        r.raise_for_status()
        with open(tmp_path, "wb") as f:
            for chunk in r.iter_content(1 << 20):
                if chunk:
                    f.write(chunk)

    if tmp_path.stat().st_size == 0:
        tmp_path.unlink(missing_ok=True)
        raise RuntimeError(f"Descarga vacía del .deb de {subdir}")

    # Limpieza (opcional)
    if cleanup_glob is not None:
        removed = 0
        for p in pool_dir.glob(cleanup_glob):
            if p.name != tmp_path.name:
                p.unlink(missing_ok=True); removed += 1
        for p in pool_dir.glob("*.sha256"):
            if p.name != (tmp_path.name + ".sha256"):
                p.unlink(missing_ok=True); removed += 1
        if removed:
            log(f"Limpieza: {removed} archivos previos en pool/{subdir}/")

    os.replace(tmp_path, target)
    (target.with_suffix(".deb.sha256")).write_text(
        f"{sha256sum(target)}  {target.name}\n", encoding="utf-8"
    )
    log(f"Guardado {target.name} (+ .sha256)")
    return target

# =========================
#  Ingesta Redroot Kernels
# =========================
def prune_kernel_pool(retain: int = 3):
    pool_dir = REPO_DIR / "pool" / "main" / KERNEL_SUBDIR
    if not pool_dir.exists():
        return
    for cpu in CPU_PROFILES:
        for kind, rx in (("image", KIMG_RE), ("headers", KHDR_RE)):
            files = [p for p in pool_dir.glob(f"linux-{kind}-*-redroot-{cpu}_*_amd64.deb")]
            if not files:
                continue
            versions = []
            name_map = {}  # ver -> [files]
            for p in files:
                m = rx.match(p.name)
                if not m:
                    continue
                ver = m.group("ver")
                versions.append(ver)
                name_map.setdefault(ver, []).append(p)
            if not versions:
                continue
            ordered = sort_versions_debian(versions)  # asc
            to_remove = ordered[:-retain] if len(ordered) > retain else []
            removed = 0
            for ver in to_remove:
                for p in name_map.get(ver, []):
                    p.unlink(missing_ok=True); removed += 1
                    sha = p.with_suffix(".deb.sha256")
                    sha.unlink(missing_ok=True)
            if removed:
                log(f"Pruned {removed} {kind} pkg(s) for {cpu}; kept last {retain}.")

def ingest_redroot_kernels():
    infos = latest_redroot_kernel_assets()
    if not infos:
        log("No hay kernels Redroot nuevos en el Release.")
        prune_kernel_pool(retain=3)  # higiene periódica
        return False

    pool_dir = REPO_DIR / "pool" / "main" / KERNEL_SUBDIR
    pool_dir.mkdir(parents=True, exist_ok=True)
    changed = False
    for cpu, info in infos.items():
        for kind in ("image","headers"):
            url, ver, fname = info[kind]
            # Importante: NO limpiar el subdir aquí (cleanup_glob=None)
            if download_if_needed(url, ver, subdir=KERNEL_SUBDIR, target_name=fname, cleanup_glob=None):
                changed = True

    prune_kernel_pool(retain=3)
    return changed

# =========================
#  Metapaquetes (alias estables)
# =========================
def build_meta_pkg(pkgname: str, depends: str, version: str, out_dir: Path):
    work = out_dir / f".meta-{pkgname}"
    if work.exists():
        subprocess.run(["rm","-rf",str(work)], check=True)
    (work / "DEBIAN").mkdir(parents=True, exist_ok=True)
    control = f"""Package: {pkgname}
Version: {version}
Architecture: amd64
Depends: {depends}
Priority: optional
Section: kernel
Maintainer: {GPG_KEY_ID}
Description: Meta package for {pkgname}; pulls latest {depends}
"""
    (work / "DEBIAN" / "control").write_text(control, encoding="utf-8")
    deb_path = out_dir / f"{pkgname}_{version}_amd64.deb"
    sh(["dpkg-deb","--build",str(work),str(deb_path)])
    (deb_path.with_suffix(".deb.sha256")).write_text(
        f"{sha256sum(deb_path)}  {deb_path.name}\n", encoding="utf-8"
    )
    log(f"Metapaquete generado: {deb_path.name}")
    return deb_path

def synthesize_kernel_meta_packages():
    pool_dir = REPO_DIR / "pool" / "main" / KERNEL_SUBDIR
    pool_dir.mkdir(parents=True, exist_ok=True)

    # Detectar última versión por CPU según lo presente en pool
    latest = {}  # cpu -> ver
    for p in pool_dir.glob("linux-image-*-tkg-redroot-*_amd64.deb"):
        m = KIMG_RE.match(p.name)
        if not m:
            continue
        cpu = m.group("cpu"); ver = m.group("ver")
        if (cpu not in latest) or (deb_cmp(latest[cpu], ver) < 0):
            latest[cpu] = ver

    if not latest:
        log("No hay kernels en pool para sintetizar metapaquetes.")
        return

    for cpu, ver in latest.items():
        img_pkg = f"linux-image-{ver}-tkg-redroot-{cpu}"
        hdr_pkg = f"linux-headers-{ver}-tkg-redroot-{cpu}"
        # versión del meta = misma del kernel real para que se actualice sola
        build_meta_pkg(f"linux-image-redroot-{cpu}",   img_pkg, ver, pool_dir)
        build_meta_pkg(f"linux-headers-redroot-{cpu}", hdr_pkg, ver, pool_dir)

# =========================
#  Índices APT y firma
# =========================
def generate_packages():
    pool_main = REPO_DIR / "pool" / "main"
    bin_dir = REPO_DIR / "dists" / DIST / COMP / f"binary-{PRIMARY_ARCH}"

    cmd = (
        f"dpkg-scanpackages -m {pool_main.relative_to(REPO_DIR)} /dev/null | "
        f"tee {bin_dir/'Packages'} | gzip -9 > {bin_dir/'Packages.gz'}"
    )
    out = subprocess.run(["bash","-lc", cmd], cwd=REPO_DIR, capture_output=True, text=True)
    if out.returncode != 0:
        err(out.stderr); raise RuntimeError("dpkg-scanpackages falló")
    entries = len([ln for ln in out.stdout.splitlines() if ln.strip()])
    log(f"Entradas {PRIMARY_ARCH} en Packages: {entries}")

    for arch in ARCHES:
        if arch == PRIMARY_ARCH:
            continue
        bdir = REPO_DIR / "dists" / DIST / COMP / f"binary-{arch}"
        (bdir / "Packages").write_text("", encoding="utf-8")
        subprocess.run(
            ["bash","-lc", f"gzip -9c < {bdir/'Packages'} > {bdir/'Packages.gz'}"],
            cwd=REPO_DIR, check=True, capture_output=True, text=True
        )
        log(f"Generado índice vacío para {arch}")

def generate_release():
    dists = REPO_DIR / "dists" / DIST
    conf = REPO_DIR / "apt-ftparchive.conf"
    conf.write_text(
    f"""Dir::ArchiveDir "{REPO_DIR}";
Dir::CacheDir "{REPO_DIR}";
APT::FTPArchive::Release::Suite "{DIST}";
APT::FTPArchive::Release::Codename "{DIST}";
APT::FTPArchive::Release::Components "{COMP}";
APT::FTPArchive::Release::Architectures "{' '.join(ARCHES)}";
""", encoding="utf-8")
    rel_path = dists / "Release"
    log("Generando Release…")
    out = subprocess.run(
        ["apt-ftparchive", "-c", str(conf), "release", f"dists/{DIST}"],
        cwd=REPO_DIR, capture_output=True, text=True
    )
    if out.returncode != 0:
        err(out.stderr); raise RuntimeError("apt-ftparchive falló")
    rel_path.write_text(out.stdout, encoding="utf-8")

    log("Firmando InRelease y Release.gpg…")
    sh(["gpg","--batch","--yes","--pinentry-mode","loopback","-u",GPG_KEY_ID,
        "--output",str(dists/"InRelease"), "--clearsign", str(rel_path)])
    sh(["gpg","--batch","--yes","--pinentry-mode","loopback","-u",GPG_KEY_ID,
        "--output",str(dists/"Release.gpg"), "--detach-sign", str(rel_path)])

def export_pubkey():
    keyfile = REPO_DIR / "KEY.asc"
    subprocess.run(
        ["bash","-lc", f"gpg --batch --yes --armor --export '{GPG_KEY_ID}' > {keyfile}"],
        capture_output=True, text=True
    )
    log("Exportada KEY.asc")

# =========================
#  Flujo
# =========================
def initial_build():
    ensure_layout()
    generate_packages()
    generate_release()
    export_pubkey()

def one_cycle():
    ensure_layout()
    changed = False

    # Discord (conserva solo la última)
    url_d, ver_d = latest_deb_url_and_version()
    if download_if_needed(url_d, ver_d, subdir="discord", target_name=f"discord_{ver_d}_{PRIMARY_ARCH}.deb"):
        changed = True

    # FreeTube (conserva solo la última)
    url_f, ver_f, name_f = freetube_latest_deb_url_and_version()
    if download_if_needed(url_f, ver_f, subdir=FREETUBE_SUBDIR, target_name=name_f):
        changed = True

    # GitHub Desktop (conserva solo la última) con nombre limpio
    url_gd, ver_gd, name_gd = github_desktop_latest_deb_url_and_version()
    clean_name_gd = f"github-desktop_{ver_gd}_{PRIMARY_ARCH}.deb"
    if download_if_needed(url_gd, ver_gd, subdir=GH_DESKTOP_SUBDIR, target_name=clean_name_gd):
        changed = True

    # Redroot Kernels (mantiene últimas 3 por CPU)
    if ingest_redroot_kernels():
        changed = True

    if changed:
        synthesize_kernel_meta_packages()
        generate_packages()
        generate_release()
        export_pubkey()
    else:
        log("Sin cambios; ya estaban las versiones actuales.")

def run_daemon():
    initial_build()
    try:
        one_cycle()
    except Exception as e:
        warn(f"Primer ciclo falló: {e}")
    while True:
        try:
            one_cycle()
        except Exception as e:
            warn(e)
        time.sleep(CHECK_INTERVAL_SECS)

if __name__ == "__main__":
    run_daemon()
