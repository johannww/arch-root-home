# from arch wiki
loadkeys colemak
ip link
ping google.org
timedatectl

pacman -Syu
pacman -S --noconfirm git
git clone https://github.com/johannww/arch-root-home.git

# EDIT HERE
DEV=sdb

# create three partitions: EFI System type FAT32 1GB (change type with t) for /boot, one for / and one for /var 12GB
# actually, I think only /boot/EFI MUST be FAT32
cfdisk /dev/$DEV

echo 0 > /sys/block/${DEV}/queue/rotational # force SSD detection if serial ports (USB) bridge the communication (FOR BTRFS)

mkfs.fat -F 32 /dev/${DEV}2 #for efi partition
cryptsetup luksFormat /dev/${DEV}3 # encrypt the /boot
cryptsetup luksOpen /dev/${DEV}3 boot
mkfs.btrfs /dev/mapper/boot # for boot partition

# create @ subvolume. THIS IS REQUIRED FOR timeshift AND grub-btrfsd
# NOTE: I no longer use timeshift. Anyways, it is a default way of handling drives.
mount /dev/mapper/boot /mnt/boot
btrfs subvolume create /mnt/boot/@
umount /mnt/boot

#set up lvm2
pvcreate /dev/${DEV}1
vgcreate vg_root /dev/${DEV}1
lvcreate -l 100%FREE --name root_volume vg_root

# set encrypted device with logical volumes lvm, since we do use an encrypted swap partition
# cryptsetup luksFormat /dev/mapper/vg_root-root_volume --type luks1 #grub only supports luks1
# apparently, grub supports luks2 now
cryptsetup luksFormat /dev/mapper/vg_root-root_volume
cryptsetup luksOpen /dev/mapper/vg_root-root_volume encrypted
mkfs.btrfs /dev/mapper/encrypted

mount /dev/mapper/encrypted /mnt
# create subvolume for /@
btrfs subvolume create /mnt/@

umount -R /mnt
mount /dev/mapper/encrypted /mnt -t btrfs -o subvol=@
mount --mkdir -o subvol=@ /dev/mapper/boot /mnt/boot # if boot partition
mount --mkdir /dev/${DEV}2 /mnt/boot/EFI

# create subvolume for /mnt/var if no var partition
btrfs subvolume create /mnt/var
mkdir -p /mnt/var/log/usr
chmod -R 777 /mnt/var/log/usr
# TODO: create subvolume for /home/johann/.cache
btrfs subvolume create /home/johann/.cache
btrfs subvolume create /home/johann/onedrive

pacstrap -K /mnt base linux linux-firmware linux-headers

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime

# add /boot /dev/sdX3 to crypttab so linux can decrypt it after boot
UUIDSTR=$(sudo blkid | grep "/dev/${DEV}3" | awk '{print $2}')
echo "boot ${UUIDSTR} /etc/boot.key" | sudo tee -a /etc/crypttab
sudo dd if=/dev/urandom of=/etc/boot.key bs=512 count=1
sudo cryptsetup luksAddKey /dev/${DEV}3 /etc/boot.key

#colemak as default keymap for grub
echo "KEYMAP=colemak" > /etc/vconsole.conf

# install tools for editing
pacman -S --noconfirm vim less
# install btrfs-progs for snapshoting and managing btrfs
pacman -S --noconfirm btrfs-progs

# put "encrypt" and "lvm2" before filesysten and after keyboard/keymap in HOOKS
pacman -S --noconfirm lvm2 #just to have it in case we want to use it in the future
vim /etc/mkinitcpio.conf
mkinitcpio -P

# install grub
pacman -S --noconfirm grub efibootmgr os-prober
grub-install --target=x86_64-efi --efi-directory=/boot/EFI --bootloader-id=GRUB --removable
# add "cryptdevice=/dev/vg_root/root_volume:root root=/dev/mapper/root" to GRUB_CMDLINE_LINUX variable on /etc/default/grub
# add "nvidia-drm.modeset=1" to GRUB_CMDLINE_LINUX variable on /etc/default/grub for nvidia 470xx driver
# if --removable add "cryptdevice=/dev/disk/by-uuid/ENCRYPTED_PARTITION_UUID:root" to GRUB_CMDLINE_LINUX variable on /etc/default/grub
vim /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg
# make swapfile on BTRFS (nuances)
touch /var/swapfile
chmod 600 /var/swapfile
chattr +C /var/swapfile
dd if=/dev/zero of=/var/swapfile bs=1M count=32768 #with 32 GB of ram
mkswap /var/swapfile
swapon /var/swapfile
echo '
/var/swapfile none swap sw 0 0
' >> /etc/fstab
mkinitcpio -P

# setup grub for secure boot: https://www.reddit.com/r/archlinux/comments/10pq74e/my_easy_method_for_setting_up_secure_boot_with/ and https://github.com/Bandie/grub2-signing-extension/tree/master
## FIRST PART: generate gpg key to sign files loaded by grub. Like initrd, fonts, etc
git clone git@github.com:johannww/grub2-signing-extension.git grub-signing # originially from: https://github.com/Bandie/grub2-signing-extension.git
sudo cp grub-signing/sbin/* /sbin
rm -rf grub-signing
sudo gpg --default-new-key-algo rsa4096 --gen-key # must be rsa for grub to check
sudo gpg --export -o /root/grub.pub
## MIX OF REDDIT AND GITHUB COMMANDS
sudo grub-install --target=x86_64-efi --efi-directory=/boot/EFI --bootloader-id=GRUB --modules="tpm" --disable-shim-lock -k /root/grub.pub --modules="gcry_sha256 gcry_sha512 gcry_dsa gcry_rsa" --removable
echo "set check_signatures=enforce" | sudo tee -a /etc/grub.d/00_header
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo grub-sign
# SET HOOKS for after mkinitcpio
echo '#!/bin/bash
sudo sbctl sign -s /boot/vmlinuz-linux
sudo sbctl sign -s /boot/vmlinuz-linux-lts
/sbin/grub-update-kernel-signature
' | sudo tee /etc/initcpio/post/grub-signing.sh
sudo chmod +x /etc/initcpio/post/grub-signing.sh
## SIGN MICROSOFT BINARIES
sudo gpg --detach-sign /boot/EFI/EFI/Microsoft/Boot/memtest.efi
sudo gpg --detach-sign /boot/EFI/EFI/Microsoft/Boot/bootmgr.efi
sudo gpg --detach-sign /boot/EFI/EFI/Microsoft/Boot/bootmgfw.efi

## SECOND PART: create secure boot key and sign grub efi
sudo pacman -S sbctl
sudo sbctl create-keys
sudo sbctl enroll-keys -m
# sudo mkdir -p /var/lib/sbctl/keys/PK # to import keys
# sudo sbctl import-keys --pk-cert PATH --pk-key PATH # to import keys
# if get error about immutable
    sudo chattr -i FILENAME
sudo sbctl verify # does not work for me
sudo sbctl sign -s /boot/EFI/EFI/BOOT/grubx64.efi
## to export
sudo pacman -S efitools
sudo efi-readvar -v PK -o pk.esl # export the platform key
sudo efi-readvar -v db -o myAuthorizedSignatures.esl # export authorized signatures subject

# this is essential for networking
pacman -S --noconfirm networkmanager networkmanager-openvpn networkmanager-strongswan networkmanager-l2tp
# NOTE: ENABLE COMPRESSION FOR LABSEC VPN. No private key password needed.


passwd # set password for root

# reboot on EFI partition and enable netow
systemctl enable --now strongswan
systemctl enable --now NetworkManager.service

vim /etc/pacman.conf # enable ParallelDownloads

# install good tools
pacman -S --noconfirm git man sudo ncdu bat zip p7zip unzip unrar tldr bashtop wget
# kitty terminal: it is gpu accelerated
pacman -S --noconfirm kitty

# create user and set password
useradd -m johann
passwd johann
echo "johann ALL=(ALL) ALL" >> /etc/sudoers
# uncomment the "secure_path" line to avoid keeping the same PATH as the user

#login as johann
logout

# SECURITY
sudo pacman -S --noconfirm apparmor
sudo mkdir -p /etc/default/grub.d
sudo echo 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT lsm=landlock,lockdown,yama,integrity,apparmor,bpf"' | sudo tee /etc/default/grub.d/apparmor.cfg
grub-mkconfig -o /boot/grub/grub.cfg
sudo pacman -S intel-ucode # for intel microcode updates. Check vulnerabilities with lscpu

sudo pacman -S --noconfirm rng-tools # for adding entropy for /dev/random
sudo systemctl enable --now rngd

sudo pacman -S --noconfirm --needed arch-install-scripts # if you screw up /etc/fstab you can recover with genfstab

# install other kernels: lts, zen, hardened
sudo pacman -S --noconfirm linux-lts linux-lts-headers
sudo pacman -S --noconfirm linux-zen linux-zen-headers
sudo pacman -S --noconfirm linux-hardened linux-hardened-headers

# install yay
sudo pacman -S --noconfirm --needed base-devel # install development tools
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si

# install gpu driver, display server and display manager
sudo pacman -Ss --noconfirm xf86-video # lists video drivers
sudo pacman -S --noconfirm xf86-video-nouveau # video driver
sudo pacman -S --noconfirm xf86-video-vmware # video driver
yay -S nvidia-470xx-{dkms,utils,settings} # or use yay for older video cards like mine laptops vaio and asus
# if intel integrated card is takin over
echo 'Section "OutputClass"
    Identifier "intel"
    MatchDriver "i915"
    Driver "modesetting"
EndSection

Section "OutputClass"
    Identifier "nvidia"
    MatchDriver "nvidia-drm"
    Driver "nvidia"
    Option "AllowEmptyInitialConfiguration"
    Option "PrimaryGPU" "yes"
    ModulePath "/usr/lib/nvidia/xorg"
    ModulePath "/usr/lib/xorg/modules"
EndSection
' | sudo tee /etc/X11/xorg.conf.d/10-nvidia-drm-outputclass.conf
echo ' xrandr --setprovideroutputsource modesetting NVIDIA-0
xrandr --auto
' | sudo tee -a /usr/share/sddm/scripts/Xsetup

sudo pacman -S --noconfirm --needed xorg # display server

#xfce4
sudo pacman -S --noconfirm lightdm # display manager
sudo systemctl enable lightdm.service
sudo pacman -S --noconfirm --needed xfce4 xfce4-goodies

#kde plasma
sudo pacman -S --noconfirm --needed sddm # display manager
sudo systemctl enable sddm
echo "xrandr -s 1920x1080" | sudo tee -a /usr/share/sddm/scripts/Xsetup
sudo pacman -S --noconfirm --needed plasma plasma-desktop kde-applications
sudo vim /usr/lib/sddm/sddm.conf.d/default.conf # set current theme to breeze
echo 'export DESKTOP_SESSION=plasma
exec startplasma-x11' >> ~/.xinitrc


sudo localectl --no-convert set-x11-keymap us pc104 colemak grp:win_space_toggle # set colemak as default layout

yay -S brave-bin # install brave browser

sudo pacman -S --noconfirm plymouth # nice UI to enter luks password at boot
sudo vim /etc/default/grub # add "splash" after quiet
sudo vim /etc/mkinitcpio.conf # add HOOKS=(... plymouth ...) before "encrypt" and after keymap and keyboard
sudo vim /etc/plymouth/plymouthd.conf # configure plymouth
sudo plymouth-set-default-theme spinfinity
sudo mkinitcpio -P
sudo grub-mkconfig -o /boot/grub/grub.cfg

LV_BRANCH='release-1.3/neovim-0.9' bash <(curl -s https://raw.githubusercontent.com/LunarVim/LunarVim/release-1.3/neovim-0.9/utils/installer/install.sh) # lunarvim

sudo pacman -S --noconfirm zsh
chsh -s /usr/bin/zsh
mkdir -p ~/.zsh
git clone https://github.com/zsh-users/zsh-autosuggestions ~/.zsh/zsh-autosuggestions
echo 'source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh' >> ~/.zshrc
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.zsh/zsh-syntax-highlighting
echo "source ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" >> ~/.zshrc
sudo pacman -S --noconfirm pkgfile # for zsh command completion, also provides pkgfile command
sudo pkgfile --update # update pkgfile database
echo "source /usr/share/doc/pkgfile/command-not-found.zsh" >> ~/.zshrc

yay -S nerd-fonts-sf-mono

git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ~/powerlevel10k
echo 'source ~/powerlevel10k/powerlevel10k.zsh-theme' >>~/.zshrc

# asdf
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.13.1
echo '. "$HOME/.asdf/asdf.sh"' >> ~/.zshrc
echo 'fpath=(${ASDF_DIR}/completions $fpath)' >> ~/.zshrc
echo 'autoload -Uz compinit && compinit' >> ~/.zshrc
asdf plugin-add nodejs
asdf install nodejs ...
sudo pacman -S --noconfirm neovim # better to install it via pacman
sudo pacman -S --noconfirm xclip # handle neovim clipboard
sudo pacman -S --noconfirm xsel # handle tmux clipboard

# python setup
# arch likes to control python packages with pacman without pip
# so we will use asdf to use pip for the local user
# asdf install python 3.11.6
# asdf global python 3.11.6
# python -m ensurepip
# UPDATE: I am actually using python from pacman
sudo pacman -S --noconfirm python-virtualenv # to create virtual environments

# fzf, rg
sudo pacman -S --noconfirm fd fzf ripgrep
echo 'source /usr/share/fzf/key-bindings.zsh' >> ~/.zshrc
echo 'source /usr/share/fzf/completion.zsh' >> ~/.zshrc

mkdir -p ~/.config/nvim # download config from onedrive
sudo pacman -S --noconfirm lazygit # used in nvim
yay -S luarocks # used by Lazy neovim plugin manager

sudo pacman -S --noconfirm fd exa sd dust tokei hyperfine bandwhich grex # rust performatic tools

sudo pacman -S --noconfirm keepassxc

yay -S onedrive-abraunegg # select ldc and liblphobos
sudo mkdir /mnt/data
sudo vim /etc/fstab # set mount to /mnt/data using /dev/mapper/luks... UUID
# also, add "noauto" option
ln -s /mnt/data/onedrive ~/onedrive

ssh-keygen -t ed25519 -f ~/.ssh/git
echo 'Host github.com
 HostName github.com
 IdentityFile ~/.ssh/git
Host gitlab.labsec.ufsc.br
 HostName gitlab.labsec.ufsc.br
 IdentityFile ~/.ssh/git' >> ~/.ssh/config
git config --global user.email "johannwestphall@gmail.com"
git config --global user.name "Johann Westphall"
git config --global core.editor nvim
git config --global init.defaultBranch main
git config commit.gpgsign true # sign commits by default in a specific repo
# generate pgp key and add to github and gitlab
gpg --full-generate-key
git config --global user.signingkey <key-id> # after sec/<key-id> in gpg --list-secret-keys --keyid-format long

sudo pacman -S --noconfirm github-cli # install github cli
gh extension install github/gh-copilot

sudo pacman -S --noconfirm docker docker-compose
yay -S lazydocker
sudo usermod -aG docker johann
newgrp docker # make command above take effect
sudo systemctl enable --now docker

sudo pacman -S --noconfirm jq

echo "#Hibernate with swapfile"
#https://ubuntuhandbook.org/index.php/2021/08/enable-hibernate-ubuntu-21-10/
touch /var/swapfile
sudo chattr +C /var/swapfile
sudo fallocate -l 6G /var/swapfile
sudo chmod 600 /var/swapfile
sudo mkswap /var/swapfile
sudo swapon /var/swapfile
echo '/var/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
UUID=$(sudo blkid | grep mapper/root | sed 's/\(UUID\)="\([a-zA-Z0-9\-]\+\)"/\1=\2/g' | awk '{print $2}')
OFFSET=$(sudo btrfs inspect-internal map-swapfile -r /var/swapfile)
sudo sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet splash\)"/\1 resume='$UUID' resume_offset='$OFFSET'"/g' /etc/default/grub
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo vim /etc/mkinitcpio.conf # add "resume" hook before fsck
sudo mkinitcpio -P
#see more on https://wiki.archlinux.org/title/Power_management/Suspend_and_hibernate

sudo ~/Downloads/NVIDIA-Linux-x86_64-470.199.02.run #installnvidia driver
yay -S nvidia-470xx-dkms nvidia-470xx-utils nvidia-470xx-settings # or use yay for older video cards like mine laptops vaio and asus
sudo vim /etc/mkinitcpio.conf # The arch wiki says to remove the "kms" hook to prevent nouveau loading. HOWEVER, in my vaio it was not needed
sudo mkinitcpio -P

yay -S texlive-full
pacman -Ssq texlive # list all texlive packages
sudo pacman -S texlive-basic texlive-bibtexextra texlive-bin texlive-binextra texlive-context texlive-fontsextra texlive-fontsrecommended texlive-fontutils texlive-formatsextra texlive-games texlive-humanities texlive-langenglish texlive-langgerman texlive-langportuguese texlive-langother texlive-langgreek texlive-latex texlive-latexextra texlive-latexrecommended texlive-luatex texlive-mathscience texlive-meta texlive-metapost texlive-music texlive-pictures texlive-plaingeneric texlive-pstricks texlive-publishers texlive-xetex biber # equivalent to texlive full: I am having problems installing with yay

echo '[Desktop Entry]
Exec=/bin/bash -c "~/startup/daemon-scripts/execute_on_unlock.sh"
Icon=dialog-scripts
Name=Execute included scripts on unlock
Type=Application
X-KDE-AutostartScript=true
' > ~/.config/autostart/execute_on_unlock.desktop

sudo pacman -S pipewire-{jack,alsa,pulse}
sudo pacman -S wireplumber # automatically switch between HD
systemctl --user enable --now pipewire pipewire-pulse pipewire-media-session
sudo pacman -S --noconfirm bluez bluez-utils
sudo pacman -S --noconfirm alsa-utils # to unmute sound on g750jx speaker
sudo systemctl enable --now bluetooth
sudo vim /etc/bluetooth/main.conf ## set ControllerMode to bredr for JBL GO to work
sudo btmgmt ssp on # try that if airpods not connecting to bluetooth
wget https://github.com/winterheart/broadcom-bt-firmware/raw/master/brcm/BCM20702A1-13d3-3404.hcd
sudo mv BCM20702A1-13d3-3404.hcd /lib/firmware/brcm/ # for bluetooth on g750jx
sudo vim /etc/pulse/daemon.conf # set realtime-priority to 9, trying to solve "[ao/pulse] audio end or underrun" in journalctl. OBS: it seemed to have worked after reboot
sudo pacman -S --noconfirm pavucontrol # for controlling audio

sudo pacman -S --noconfirm thunderbird
yay -S external-editor-revived # for editing emails in nvim

git clone git@github.com:johannww/xkbcomp.git startup #xkbcomp scripts to my custom colemak
sudo pacman -Syu --noconfirm usbutils #for lsusb on xkbdaemon.sh
sudo pacman -S --noconfirm inotify-tools #for detecting fetches of x11 keyboard file and applying my layout
echo "add xkbdaemon.sh to autostart"

yay -S flatseal # install flatseal

sudo pacman -S --noconfirm grub-btrfs
# set ExecStart to ExecStart=/usr/bin/grub-btrfsd --syslog /.snapshots /boot/.snapshots/
sudo systemctl edit --full grub-btrfsd
# sudo systemctl enable --now grub-btrfsd # I use the manual mode. see: ~/.local/share/chezmoi/startup/scripts/snapper_snapshot.sh
# add "grub-btrfs-overlayfs" at the end of HOOKS
sudo vim /etc/mkinitcpio.conf
sudo mkinitcpio -P
sudo pacman -S --noconfirm snapper # controling snapshots in btrfs
# create configs for / and /boot
sudo snapper -c root create-config /
sudo snapper -c boot create-config /boot
# set maximum 3 snapshots for /boot and for /
sudo snapper -c root set-config NUMBER_LIMIT=3 NUMBER_MIN_AGE=0
sudo snapper -c boot set-config NUMBER_LIMIT=3 NUMBER_MIN_AGE=0

sudo pacman -S --noconfirm ntfs-3g

yay -S stremio
sudo pacman -S --noconfirm dosfstools # for creating fat fs

sudo pacman -S --noconfirm system-config-printer cups # for finding printers
sudo systemctl enable --now cups

# clone dotfiles and manually add them to the home and .config directories
git clone git@github.com:johannww:arch-home.git ~/dotfiles

sudo pacman -S broadcom-wl-dkms  # for wifi card on g750jx

mkdir ~/.vpn # for vpn configurations

git clone git@github.com:vinceliuice/grub2-themes.git # for grub themes
cd grub2-themes
sudo ./install -t tela -s 2k -i color -b
cd .. && rm -rf grub2-themes

# add flatpak repo for user
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak --user install flathub io.github.nokse22.teleprompter # install teleprompter only for my user

sudo pacman -S --noconfirm jdk-openjdk # install java
yay -S postman-bin #install postman

# enable multilib to install steam
sudo vim /etc/pacman.conf # uncomment multilib
sudo pacman -Syu
sudo pacman -S steam # dont select nvidia as it conflicts with nvidia-470xx-utils. Select lib32-intel
pacman -R $(comm -12 <(pacman -Qq | sort) <(pacman -Slq multilib | sort)) # if I desire to remove everypackage installed by multilib

sudo pacman -S kubo # install ipfs
yay -S ipfs-desktop # install client

sudo pacman -S --nocomfirm rustup # instead of rust via pacman
rustup default stable

sudo pacman -S --noconfirm rtorrent # torrent client
sudo pacman -S --noconfirm qbittorrent # torrent client

sudo pacman -S --noconfirm neomutt # email client

sudo pacman -S --noconfirm obs-studio # for screen recorder

sudo pacman -S --noconfirm dos2unix # for converting line endings

sudo pacman -S --noconfirm pandoc # convert documents eg markdown to pdf
sudo pacman -S --noconfirm calibre # convert pdf to epub
sudo pacman -S --noconfirm pdfgrep # search for text in pdf
sudo pacman -S --noconfirm diffpdf # see pdf diff

sudo pacman -S --noconfirm pacman-contrib # install pactree

yay -S aichat # install aichat to request commands explanation

#ansible, kubernetes and for hyperledger bevel
sudo pacman -S --noconfirm ansible ansible-lint
sudo pacman -S --noconfirm kubectl kubelet kubeadm minikube kustomize
sudo pacman -S --noconfirm helm # helm
sudo pacman -S --noconfirm vault # install hashicorp vault

sudo pacman -S --noconfirm poppler # for pdf tools and converting to txt. I think kde automatically installs it.

# plantuml
sudo pacman -S --noconfirm plantuml
go install github.com/bykof/go-plantuml@latest
go install github.com/jfeliu007/goplantuml # alternative
# use https://dumels.com to generate diagrams directly from github
# plant uml integrates with drawio, but only with the WEB version

# list of good applications to install: https://wiki.archlinux.org/title/List_of_applications/Other
yay -S numen # for voice dictation
mkdir -p ~/.config/numen && ln -s ~/onedrive/ubuntu/numen/phrases/ ~/.config/numen/phrases
cp ~/onedrive/ubuntu/numen/numen.service /lib/systemd/user/numen.service
# TODO: check here
sudo groupadd -f input
sudo usermod -a -G input $USER

# kali linux classic tools
sudo pacman -S --noconfirm nmap arp-scan wireless_tools wireshark-qt # for network scanning
sudo usermod -aG wireshark johann # for wireshark

sudo pacman -S --noconfirm festival festival-english # for text to speech and use in timers
export GOPRIVATE=github.com/johannww/go-vocal-timer
go install github.com/johannww/go-vocal-timer@latest # install my own timer implementation using ssh
ln -s $(which go-vocal-timer) ~/.local/bin/timer

sudo pacman -S --noconfirm piper # for configuring Logitech Superlight mouse (need cable)
upower --dump # to see battery info of mice and keyboards

yay -S airstatus-git
sudo vim /usr/lib/airstatus.py # edit the polling interval and the max size of the output fil
sudo systemctl enable --now airstatus
echo '#!/bin/bash
tail -n 1 /tmp/airstatus.out
' > ~/.local/bin/airpodsbat
chmod +x ~/.local/bin/airpodsbat

sudo pacman -S --noconfirm yt-dlp # to download youtube videos

sudo pacman -S --noconfirm softhsm # for hyperledger fabric testing

echo 0 | sudo tee /proc/sys/kernel/yama/ptrace_scope # disable yama for golang debugger attach. This is a security risk. Use only for development.

sudo sysctl net.ipv6.conf.all.disable_ipv6=1 # disable ipv6 temporarily
sudo sysctl net.ipv6.conf.default.disable_ipv6=1 # disable ipv6 temporarily

nmcli d wifi # for checking wifi interference

# replace pulseaudio with pipewire (better bluetooth support)
sudo pacman -Rdd pulseaudio
sudo pacman -S pipewire-{jack,alsa,pulse}
sudo pacman -S wireplumber # automatically switch between HD
systemctl --user enable --now pipewire pipewire-pulse pipewire-media-session

yay -S drawio-desktop

sudo pacman -S --noconfirm inxi # for system information

sudo pacman -S touchegg # for touchpad gestures
sudo systemctl enable --now touchegg
#add touchegg to autostart
echo '[Desktop Entry]
Exec=/bin/bash -c "sleep 5s && touchegg --client"
Icon=dialog-scripts
Name=Touchegg Client
Type=Application
X-KDE-AutostartScript=true
' > ~/.config/autostart/touchegg.desktop

# change sddm background image based on time at boot
echo '[Unit]
Description=Change SDDM background based on time
Before=sddm.service

[Service]
Type=oneshot
ExecStart=/usr/bin/logger "SDDM background changed based on time"
ExecStart=/home/johann/startup/daemon-scripts/change_sddm_theme_based_on_time.sh

[Install]
WantedBy=multi-user.target
' | sudo tee /etc/systemd/system/sddm-background-time-change.service
sudo systemctl enable sddm-background-time-change

# task warrior and time warrior for productivity
sudo pacman -S task timew

# set ssh for external connection
sudo ssh-keygen -ted25519 -f /etc/ssh/ssh_host_ed25519_key
echo '
#JOHANN SECTION
HostKey /etc/ssh/ssh_host_ed25519_key
PasswordAuthentication no
' | sudo tee -a /etc/ssh/sshd_config
echo "put the authorized keys in ~/.ssh/authorized_keys"

# remove unused packages
pacman -Qdtq | sudo pacman -Rns -
yay -Qdtq | sudo yay -Rns -

yay -S downgrade # to downgrade packages
sudo vim /etc/pacman.conf # remove package ignore when they are fixed

# ios iphone backup
yay -S libimobiledevice-git # the aur-git version is more updated than the official repo one
# sudo pacman -S libimobiledevice

sudo pacman -S power-profiles-daemon # to set different power profiles
sudo systemctl enable power-profiles-daemon --now

# databases
yay -S mongodb-bin mongosh-bin
sudo pacman -S postgresql
sudo su - postgres
initdb -D /var/lib/postgres/data
echo "Type commands on psql"
psql
# create user johann;
# create database johann;
# grant all privileges on database johann to johann;
# alter database johann owner to johann;

# AI
yay -S shell-gpt
echo 'export OPENAI_API_KEY=$(cat ~/.config/shell_gpt/openai.key)' >> ~/.zshrc
echo "export DEFAULT_MODEL=gpt-4o-mini" >> ~/.zshrc

sudo pacman -S --noconfirm chezmoi # for managing dotfiles

# create a user on input group to run the interception script
sudo usermod -r -G input $USER
echo "johann ALL=(ALL:ALL)  PASSWD: ALL, NOPASSWD: /home/johann/startup/interception/intercept_apple.sh, /home/johann/startup/interception/intercept_regular.sh, /home/johann/startup/interception/intercept_split.sh" | sudo tee -a /etc/sudoers

# sync audio delay when using bluetooth with hdmi
pactl set-port-latency-offset bluez_card.28_2D_7F_D2_B2_41 headphone-output -3700000
pactl set-port-latency-offset bluez_card.10_28_74_FF_5F_04 speaker-output -3700000 # vaio small notebook

git clone git@github.com:johannww/arch-home.git ~/.local/share/chezmoi/
