#!/usr/bin/env python3

from urllib.request import urlopen, urlretrieve
from urllib.parse import urlparse
from gzip import GzipFile
from pathlib import Path
import subprocess 
import tarfile
import shutil
import pickle
import os

# WARNING: this script does not verify integrity and signature of packages!

RASPBIAN_VERSION = "buster"
RASPBIAN_ARCHIVE = "http://archive.raspberrypi.org/debian"
RASPBIAN_MAIN = "http://raspbian.raspberrypi.org/raspbian"

UBUNTU_VERSION = "bionic"
UBUNTU_MAIN = "http://ports.ubuntu.com/ubuntu-ports"
UBUNTU_RPI = "http://ppa.launchpad.net/ubuntu-raspi2/ppa/ubuntu"

ALARM = "http://mirror.archlinuxarm.org"
ALARM_REPOS = ["alarm", "core", "extra", "community"]

ALPINE_VERSION = "3.12"
ALPINE = "http://dl-cdn.alpinelinux.org/alpine"

IGNORED_PACKAGES = [
  "raspberrypi-bootloader", "libasan3", "libubsan0", "libgomp1", "libatomic1",
  "sh", "filesystem", "tzdata", "iana-etc", "libncursesw.so", "libp11-kit.so",
  "libsystemd.so", "libidn2.so", "libacl.so"
]

# db is dict from package name to two element list - url and list of dependencies
def deb_collect_packages(url, version, section, db):
  with urlopen(f"{url}/dists/{version}/{section}/binary-armhf/Packages.gz") as req:
    with GzipFile(fileobj=req) as gz:
      for line in gz:
        line = line.strip().decode("utf-8")
        if ": " not in line:
          continue
        key, value = line.split(": ", 1)
        if key == "Package":
          pkg = [url, []]
          db[value] = pkg
        elif key == "Depends":
          deps = value.split(", ")
          pkg[1] += [dep.split(" (")[0].split(" | ")[0] for dep in deps]
        elif key == "Filename":
          pkg[0] += "/" + value


def alarm_collect_packages(arch, repo, db):
  base = f"{ALARM}/{arch}/{repo}"
  with urlopen(f"{base}/{repo}.db.tar.gz") as req:
    with tarfile.open(fileobj=req, mode="r:gz") as tar:
      name = None
      url = None
      depends = []
      processed = 0
      for info in tar:
        if not info.isfile():
          continue

        p = Path(info.name)
        if p.stem == "desc":
          next_name = False
          next_url = False
          for line in tar.extractfile(info):
            line = line.strip().decode("utf-8")
            if next_url:
              url = f"{base}/{line}"
              next_url = False
            elif next_name:
              name = line
              next_name = False
            elif line == "%FILENAME%":
              next_url = True
            elif line == "%NAME%":
              next_name = True
          processed += 1

        elif p.stem == "depends":
          next_depends = False
          for line in tar.extractfile(info):
            line = line.strip().decode("utf-8")
            if next_depends:
              if line:
                depends.append(line.split("<")[0].split(">")[0].split("=")[0])
              else:
                next_depends = False
                break
            elif line == "%DEPENDS%":
              next_depends = True
          processed += 1

        if processed == 2:
          processed = 0
          db[name] = [url, depends]
          name = None
          url = None
          depends = []


def alpine_collect_packages(version, repo, arch, db):
  base = f"{ALPINE}/v{version}/{repo}/{arch}"
  packages = {}
  with urlopen(f"{base}/APKINDEX.tar.gz") as req:
    with tarfile.open(fileobj=req, mode="r:gz") as tar:
      for info in tar:
        if info.name != "APKINDEX":
          continue
        name = None
        version = None
        depends = []
        provides = []
        for line in tar.extractfile(info):
          line = line.strip().decode("utf-8")
          if line.startswith("P:"):
            name = line[2:]
          elif line.startswith("V:"):
            version = line[2:]
          elif line.startswith("D:"):
            depends = line[2:].split(" ")
          elif line.startswith("p:"):
            provides = line[2:].split(" ")
          elif not line:
            for p in provides:
              p = p.split("<")[0].split(">")[0].split("=")[0]
              packages[p] = [name, version, depends]
            packages[name] = [name, version, depends]
            name = None
            version = None
            depends = []
            provides = []

  for p,v in packages.items():
    name, version, depends = v
    url = f"{base}/{name}-{version}.apk"
    deps = []
    for d in depends:
      d = d.split("<")[0].split(">")[0].split("=")[0]
      if d in packages:
        deps.append(packages[d][0])
    db[name] = [url, deps]


def resolve(package, packages, db):
  if package in packages:
    return
  packages.add(package)
  for dep in db[package][1]:
    if dep not in IGNORED_PACKAGES:
      resolve(dep, packages, db)


def install(distro, version, target, sysroot, packages):

  sysroot = Path(sysroot)
  cache = sysroot / ".db.pickle"

  if cache.is_file():
    print("Loading package database...")
    
    with open(cache, "rb") as f:
      db = pickle.load(f)

    if distro == "alarm":
      print("WARNING: ArchLinux package database can be out-of-date pretty quickly, remove db if downloading fails")

  else:
    print("Downloading package database...")
  
    db = {}

    if distro == "raspbian":
      if version is None:
        version = RASPBIAN_VERSION
      deb_collect_packages(RASPBIAN_ARCHIVE, version, "main", db)
      deb_collect_packages(RASPBIAN_MAIN, version, "main", db)

    elif distro == "ubuntu":
      if version is None:
        version = UBUNTU_VERSION
      deb_collect_packages(UBUNTU_RPI, version, "main", db)
      for section in ["main", "universe"]:
        deb_collect_packages(UBUNTU_MAIN, version, section, db)

    elif distro == "alarm":
      if target is None:
        raise Exception("ALARM target not specified (use --target argument)")
      elif target.startswith("armv6"):
        arch = "armv6h"
      elif target.startswith("armv7"):
        arch = "armv7h"
      elif target.startswith("aarch64"):
        arch = "aarch64"
      else:
        raise Exception(f"Unsupported ALARM target {target}")

      for repo in ALARM_REPOS:
        alarm_collect_packages(arch, repo, db)
     
    elif distro == "alpine":
      if version is None:
        version = ALPINE_VERSION
      if target is None:
        raise Exception("ALPINE target not specified (use --target argument)")
      elif target.startswith("aarch64"):
        arch = "aarch64"
      elif target.startswith("arm"):
        arch = "armhf"
      else:
        raise Exception(f"Unsupported ALARM target {target}")

      alpine_collect_packages(version, "main", arch, db)

    with open(cache, "wb") as f:
      pickle.dump(db, f, pickle.HIGHEST_PROTOCOL)

  print("Resolving dependencies...")

  process = set()
  for pkg in packages:
    resolve(pkg, process, db)

  print("Downloading...")

  for i, pkg in enumerate(process):
    print(f"({i+1}/{len(process)}) {pkg}")
    url = db[pkg][0]
    name = sysroot / Path(urlparse(url).path).name

    if not name.is_file():
      urlretrieve(url, name)

      if distro == "raspbian" or distro == "ubuntu":
        subprocess.check_call(["dpkg-deb", "-x", name, sysroot])

      elif distro == "alarm":
        subprocess.check_call(["tar", "--force-local", "-C", sysroot, "-xJf", name], stderr=subprocess.DEVNULL)

      elif distro == "alpine":
        subprocess.check_call(["tar", "--force-local", "-C", sysroot, "-xzf", name], stderr=subprocess.DEVNULL)

  # remove files that makes life difficult when cross-compiling for alpine
  if distro == "alpine":
    t = sysroot / "usr" / target
    if t.is_dir():
      shutil.rmtree(t)

  print("Fixing symlinks...")

  for p in sysroot.glob("**/*"):
    if p.is_symlink():
      link = os.readlink(p)
      if Path(link).is_absolute():
        full = sysroot / ("." + link)
        fixed = os.path.relpath(full.resolve(), p.parent)
        p.unlink()
        p.symlink_to(fixed)

  print("Done!")


if __name__ == "__main__":
  from argparse import ArgumentParser

  ap = ArgumentParser(description="Download and install Raspbian packages to sysroot")
  ap.add_argument("--distro", required=True, choices=["raspbian", "ubuntu", "alarm", "alpine"], help="distribution to use")
  ap.add_argument("--version", help=f"distribution version to use for raspbian/ubuntu/alpine (default: {RASPBIAN_VERSION}/{UBUNTU_VERSION}/{ALPINE_VERSION})")
  ap.add_argument("--target", help="target to download for alarm or alpine (ex: armv6l-unknown-linux-gnueabihf)")
  ap.add_argument("--sysroot", required=True, help="sysroot folder")
  ap.add_argument("packages", nargs="+")
  args = ap.parse_args()

  os.makedirs(args.sysroot, exist_ok=True)
  install(args.distro, args.version, args.target, args.sysroot, args.packages)
