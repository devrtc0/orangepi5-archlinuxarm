#!/bin/bash -e
# Experimental new cross-building script, to replace cross.sh
# Instead of calling build.sh in a QEMU AArch64 ALARM environment, this does everything purely on host
# The expected running environment is Ubuntu 22.04, i.e. the main distro used in Github Actions
# If you're running ALARM, then you should look at build.sh
# If you're running Arch, then you should expect breakage due to Ubuntu FHS being expected

# The following envs could be set to change the behaviour:
# freeze_rkloaders: when not empty, do not update rkloaders from https://github.com/7Ji/orangepi5-rkloader
# freeze_pacoloco: when not empty, do not update pacoloco from https://github.com/anatol/pacoloco.git
# pkg_from_local_mirror: when not empty, chainload pacoloco from another local mirror, useful for local only

# Everything will be done in a subfolder
mkdir -p cross_nobuild/{bin,cache,out,src/{rkloader,pkg}}
pushd cross_nobuild

# functions
dl() { # 1: url 2: output
    echo "Downloading '$2' <= '$1'" >&2
    if [[ "$2" ]]; then
        curl -qgb "" -fL --retry 3 --retry-delay 3 -o "$2" "$1"
    else
        curl -qgb "" -fL --retry 3 --retry-delay 3 "$1"
    fi
    echo "Downloaded '$2' <= '$1'"
}

init_repo() { # 1: dir, 2: url, 3: branch
    if [[  -z "$1$2" ]]; then
        echo "Dir and URL not set"
        return 1
    fi
    rm -rf "$1"
    mkdir "$1"
    mkdir "$1"/{objects,refs}
    echo 'ref: refs/heads/'"$3" > "$1"/HEAD
cat > "$1"/config << _EOF_
[core]
	repositoryformatversion = 0
	filemode = true
	bare = true
[remote "origin"]
	url = $2
	fetch = +refs/heads/$3:refs/heads/$3
_EOF_
}

run_in_chroot() {
   sudo chroot "${root}" "$@" 
}

cleanup() {
    echo "=> Cleaning up before exiting..."
    if [[ "${pid_pacoloco}" ]]; then
        kill -s TERM ${pid_pacoloco} || true
    fi
    if [[ "${root}" ]]; then
        run_in_chroot killall gpg-agent dirmngr || true
        if sudo umount -fR "${root}"; then
            rm -rf "${root}"
        fi
    fi
    if [[ "${boot}" ]]; then
      if sudo umount -f "${boot}"; then
        rm -rf "${boot}"
      fi
    fi
    if [[ "${lodev}" ]]; then
        sudo losetup --detach "${lodev}" || true
    fi
}

trap "cleanup" INT TERM EXIT

# Get rkloaders
if [[ "${freeze_rkloaders}" ]]; then
    echo "=> Updating of RKloaders skipped"
    rkloaders=()
    for rkloader in src/rkloader/*; do
        rkloaders+=("${rkloader##*/}")
    done
else
    echo "=> Updating RKloaders"
    rkloader_parent=https://github.com/7Ji/orangepi5-rkloader/releases/download/nightly
    rkloaders=($(dl "${rkloader_parent}"/list))
    for rkloader in "${rkloaders[@]}"; do
        if [[ ! -f src/rkloader/"${rkloader}" ]]; then
            dl "${rkloader_parent}/${rkloader}" src/rkloader/"${rkloader}".temp
            mv src/rkloader/"${rkloader}"{.temp,}
        fi
    done
    for rkloader in src/rkloader/*; do
        rkloader_local="${rkloader##*/}"
        latest=''
        for rkloader_cmp in "${rkloaders[@]}"; do
            if [[ "${rkloader_local}" == "${rkloader_cmp}" ]]; then
                latest='yes'
                break
            fi
        done
        if [[ -z "${latest}" ]]; then
            rm -f "${rkloader}"
        fi
    done
    echo "=> Updated RKloaders"
fi

# Deploy pacoloco
if [[ ! -d src/pacoloco.git ]]; then
    rm -rf src/pacoloco.git
    init_repo src/pacoloco.git https://github.com/anatol/pacoloco.git master
fi
if [[ ! -d src/pacoloco.git ]]; then
    echo "Pacoloco repo not existing"
    exit 1
fi
if [[ "${freeze_pacoloco}" ]]; then
    echo "=> Updating of pacoloco git repo skipped"
else
    echo "=> Updating pacoloco git repo"
    git --git-dir src/pacoloco.git remote update --prune
    echo "=> Updated pacoloco git repo"
fi
pacoloco_ver=$(git --git-dir src/pacoloco.git rev-parse --short master)
if [[ ! -f bin/pacoloco-${pacoloco_ver} ]]; then
    echo "=> Building pacoloco-${pacoloco_ver}"
    rm bin/pacoloco-* | true
    rm -rf cache/pacoloco
    mkdir cache/pacoloco
    git --git-dir src/pacoloco.git --work-tree cache/pacoloco checkout -f master
    pushd cache/pacoloco
    go build -buildmode=pie -trimpath -ldflags=-linkmode=external -mod=readonly -modcacherw
    popd
    mv cache/pacoloco/pacoloco bin/pacoloco-"${pacoloco_ver}"
fi
chmod +x bin/pacoloco-"${pacoloco_ver}"
ln -sf pacoloco-"${pacoloco_ver}" bin/pacoloco

# Prepare to run pacoloco
# prefer mirrors provided by companies than universities, save their budget
cat > cache/pacoloco.conf << _EOF_
cache_dir: src/pkg
download_timeout: 3600
purge_files_after: 2592000
repos:
_EOF_
if [[ "${pkg_from_local_mirror}" ]]; then
cat >> cache/pacoloco.conf << _EOF_
  archlinuxarm:
    url: http://repo.lan:9129/repo/archlinuxarm
  archlinuxcn_x86_64:
    url: http://repo.lan:9129/repo/archlinuxcn_x86_64
  7Ji:
    url: http://repo.lan/github-mirror
_EOF_
else
cat >> cache/pacoloco.conf << _EOF_
  archlinuxarm:
    urls:
      - http://mirror.archlinuxarm.org
      - http://mirrors.cloud.tencent.com.cn/archlinuxarm
      - http://mirrors.tuna.tsinghua.edu.cn/archlinuxarm
  archlinuxcn_x86_64:
    urls:
      - https://opentuna.cn/archlinuxcn
      - https://mirrors.bfsu.edu.cn/archlinuxcn
      - https://mirrors.pku.edu.cn/archlinuxcn
      - https://mirrors.cloud.tencent.com/archlinuxcn
      - https://mirrors.163.com/archlinux-cn
      - https://mirrors.aliyun.com/archlinuxcn
      - https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn
  7Ji:
    url: https://github.com/7Ji/archrepo/releases/download
_EOF_
fi
# Run pacoloco in background
bin/pacoloco -config cache/pacoloco.conf &
pid_pacoloco=$!
sleep 1

# Mainly for pacman-static
repo_url_archlinuxcn_x86_64=http://127.0.0.1:9129/repo/archlinuxcn_x86_64/x86_64
# For base system packages
repo_url_alarm_aarch64=http://127.0.0.1:9129/repo/archlinuxarm/aarch64/'$repo'
# For kernels and other stuffs
repo_url_7Ji_aarch64=http://127.0.0.1:9129/repo/7Ji/aarch64

# Deploy pacman-static
dl "${repo_url_archlinuxcn_x86_64}/archlinuxcn.db" cache/archlinuxcn.db
desc=$(tar -xOf cache/archlinuxcn.db --wildcards 'pacman-static-*/desc')
pacman_names=($(sed -n '/%NAME%/{n;p;}' <<< "${desc}"))
case ${#pacman_names[@]} in
0)
    echo 'Failed to find pacman-static in archlinuxcn repo'
    exit 1
;;
1)
    pacman_ver=$(sed -n '/%VERSION%/{n;p;}' <<< "${desc}")
    pacman_pkg=$(sed -n '/%FILENAME%/{n;p;}' <<< "${desc}")
;;
*)
    pacman_vers=($(sed -n '/%VERSION%/{n;p;}' <<< "${desc}"))
    pacman_pkgs=($(sed -n '/%FILENAME%/{n;p;}' <<< "${desc}"))
    pacman_id=0
    for pacman_name in "${pacman_names[@]}"; do
        if [[ "${pacman_name}" == pacman-static ]]; then
            break
        fi
        pacman_id=$(( pacman_id + 1 ))
    done
    pacman_ver="${pacman_vers[${pacman_id}]}"
    pacman_pkg="${pacman_pkgs[${pacman_id}]}"
;;
esac
if [[ ! -f bin/pacman-"${pacman_ver}" ]]; then
    rm bin/pacman-* || true
    dl "${repo_url_archlinuxcn_x86_64}/${pacman_pkg}" cache/"${pacman_pkg}"
    tar -xOf cache/"${pacman_pkg}" usr/bin/pacman-static > bin/pacman-"${pacman_ver}".temp
    mv bin/pacman-"${pacman_ver}"{.temp,}
fi
chmod +x bin/pacman-"${pacman_ver}"
ln -sf pacman-"${pacman_ver}" bin/pacman

# Basic image layout
build_id=ArchLinuxARM-aarch64-OrangePi5-$(date +%Y%m%d_%H%M%S)
rm -f out/"${build_id}"-base.img
truncate -s 2G out/"${build_id}"-base.img
table='label: gpt
start=8192, size=204800, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
start=212992, size=3979264, type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE'
sfdisk out/${build_id}-base.img <<< "${table}"

# Partition
lodev=$(sudo losetup --find --partscan --show out/${build_id}-base.img)
uuid_root=$(uuidgen)
uuid_boot_mkfs=$(uuidgen)
uuid_boot_mkfs=${uuid_boot_mkfs::8}
uuid_boot_mkfs=${uuid_boot_mkfs^^}
uuid_boot_specifier="${uuid_boot_mkfs::4}-${uuid_boot_mkfs:4}"
sudo mkfs.vfat -n 'ALARMBOOT' -F 32 -i "${uuid_boot_mkfs}" "${lodev}"p1
sudo mkfs.ext4 -L 'ALARMROOT' -m 0 -U "${uuid_root}" "${lodev}"p2

# Mount
root=$(mktemp -d)
sudo mount -o noatime "${lodev}"p2 "${root}"
sudo mkdir -p "${root}"/{boot,dev/{pts,shm},etc/pacman.d,proc,run,sys,tmp,var/{cache/pacman/pkg,lib/pacman,log}}
sudo mount -o noatime "${lodev}"p2 "${root}"/boot
sudo mount proc "${root}"/proc -t proc -o nosuid,noexec,nodev
sudo mount sys "${root}"/sys -t sysfs -o nosuid,noexec,nodev,ro
sudo mount udev "${root}"/dev -t devtmpfs -o mode=0755,nosuid
sudo mount devpts "${root}"/dev/pts -t devpts -o mode=0620,gid=5,nosuid,noexec
sudo mount shm "${root}"/dev/shm -t tmpfs -o mode=1777,nosuid,nodev
sudo mount run "${root}"/run -t tmpfs -o nosuid,nodev,mode=0755
sudo mount tmp "${root}"/tmp -t tmpfs -o mode=1777,strictatime,nodev,nosuid

# Create temporary pacman config
pacman_config="
RootDir      = ${root}
DBPath       = ${root}/var/lib/pacman/
CacheDir     = ${root}/var/cache/pacman/pkg/
LogFile      = ${root}/var/log/pacman.log
GPGDir       = ${root}/etc/pacman.d/gnupg/
HookDir      = ${root}/etc/pacman.d/hooks/
Architecture = aarch64"
pacman_mirrors="
[core]
Server = ${repo_url_alarm_aarch64}
[extra]
Server = ${repo_url_alarm_aarch64}
[alarm]
Server = ${repo_url_alarm_aarch64}
[aur]
Server = ${repo_url_alarm_aarch64}"

cat > cache/pacman-loose.conf << _EOF_
[options]${pacman_config}
SigLevel = Never${pacman_mirrors}
_EOF_

cat > cache/pacman-strict.conf << _EOF_
[options]${pacman_config}
SigLevel = DatabaseOptional${pacman_mirrors}
[7Ji]
Server = ${repo_url_7Ji_aarch64}
_EOF_

# Base system
sudo bin/pacman -Sy --config cache/pacman-loose.conf --noconfirm base archlinuxarm-keyring
# Temporary network
sudo mount --bind /etc/resolv.conf "${root}"/etc/resolv.conf
# Keyring
run_in_chroot pacman-key --init
run_in_chroot pacman-key --populate archlinuxarm
run_in_chroot pacman-key --recv-keys BA27F219383BB875
run_in_chroot pacman-key --lsign BA27F219383BB875
# Pacman-key expects to run in an actual system, it pulled up gpg-agent and it kept running
run_in_chroot killall gpg-agent dirmngr

# Non-base packages
kernel='linux-aarch64-orangepi5'
sudo bin/pacman -Sy --config cache/pacman-strict.conf --noconfirm \
    vim nano sudo openssh \
    7Ji/"${kernel}"{,-headers} \
    linux-firmware-orangepi \
    usb2host

# /etc/fstab
sudo tee -a "${root}"/etc/fstab << _EOF_
# root partition with ext4 on SDcard / USB drive
UUID=${uuid_root}	/	ext4	rw,noatime	0 1
# boot partition with vfat on SDcard / USB drive
UUID=${uuid_boot_specifier}	/boot	vfat	rw,noatime	0 2
_EOF_

# Time
sudo ln -sf "/usr/share/zoneinfo/UTC" "${root}"/etc/localtime

# Locale
sudo sed -i 's/^#\(en_US.UTF-8  \)$/\1/g' "${root}"/etc/locale.gen
sudo tee "${root}"/etc/locale.conf <<< LANG=en_US.UTF-8
run_in_chroot locale-gen

# Network
sudo tee "${root}"/etc/hostname <<< alarm
printf '127.0.0.1\tlocalhost\n::1\t\tlocalhost\n' | sudo tee -a "${root}"/etc/hosts
printf '[Match]\nName=eth* en*\n\n[Network]\nDHCP=yes\nDNSSEC=no\n' | 
    sudo tee "${root}"/etc/systemd/network/20-wired.network

# Units
run_in_chroot systemctl enable systemd-{network,resolve,timesync}d usb2host sshd

# Users
run_in_chroot useradd -g wheel -m alarm
run_in_chroot /bin/sh -c 'printf "%s\n" alarm_please_change_me alarm_please_change_me | passwd alarm'
sudoers="${root}"/etc/sudoers
sudo chmod o+w "${sudoers}"
sudo sed -i 's|^# %wheel ALL=(ALL:ALL) ALL$|%wheel ALL=(ALL:ALL) ALL|g' "${sudoers}"
sudo chmod o-w "${sudoers}"

# QoL: vim link
sudo ln -sf 'vim' "${root}"/usr/bin/vi

# Actual resolv
sudo umount "${root}"/etc/resolv.conf
sudo ln -sf /run/systemd/resolve/resolv.conf "${root}"/etc/resolv.conf

# Extlinux
sudo mkdir "${root}"/boot/extlinux
printf \
    "LABEL\t%s\nLINUX\t/%s\nINITRD\t/%s\nFDT\t/%s\nAPPEND\t%s\n"\
    'Arch Linux for OrangePi 5'\
    "vmlinuz-${kernel}"\
    "initramfs-${kernel}-fallback.img"\
    "dtbs/${kernel}/rockchip/rk3588s-orangepi-5.dtb"\
    "root=UUID=${uuid_root} rw" | 
    sudo tee "${root}"/boot/extlinux/extlinux.conf

# Clean up
sudo rm -rf "${root}"/var/cache/pacman/pkg/*
sudo rm -f "${root}"/boot/initramfs-linux-aarch64-orangepi5.img
sudo dd if=/dev/zero of="${root}"/.zerofill bs=16M || true
sudo dd if=/dev/zero of="${root}"/boot/.zerofill bs=16M || true
sudo rm -f "${root}"/{,boot/}.zerofill
# Root archive
(
    cd ${root}
    sudo bsdtar --acls --xattrs -cpf - *
) > out/"${build_id}"-root.tar
# Release resources
sudo umount -R "${root}"
root=
sudo losetup --detach "${lodev}"
lodev=
suffixes=(
    'root.tar'
    'base.img'
)

for rkloader in rkloaders; do
    model=${rkloader##*pi-}
    model=${model%%-bl31*}
    # Use cp as it could reflink if the fs supports it
    cp out/"${build_id}"-{base,"${model}"}.img
    out=out/"${build_id}-${model}".img
    dd if=rkloader/"${rkloader}" of="${out}" conv=notrunc
    suffixes+=("${model}".img)
    sfdisk "${out}" <<< "${table}"
    case ${model} in
    5)
        continue
    ;;
    5_sata)
        fdt='rk3588s-orangepi-5.dtb\nFDTOVERLAYS\t/dtbs/linux-aarch64-orangepi5/rockchip/overlay/rk3588-ssd-sata0.dtbo'
    ;;
    5b)
        fdt='rk3588s-orangepi-5b.dtb'
    ;;
    5_plus)
        fdt='rk3588-orangepi-5-plus.dtb'
    ;;
    esac
    lodev=$(sudo losetup --find --offset 4M "${out}")
    boot=$(mktemp -d)
    sudo mount -o noatime "${lodev}" "${boot}"
    sudo sed -i 's|rk3588s-orangepi-5b.dtb|'"${fdt}"'|' "${boot}"/extlinux/extlinux.conf
    sudo umount "${boot}"
    boot=""
    sudo losetup --detach "${lodev}"
    lodev=""
done

rm -rf out/latest
mkdir out/latest

for suffix in "${suffixes[@]}"; do
    gzip -9 out/"${build_id}-${suffix}" &
    ln -s ../"${build_id}-${suffix}".gz out/latest/
done
popd