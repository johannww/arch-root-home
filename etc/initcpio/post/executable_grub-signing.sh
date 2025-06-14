#!/bin/bash
sudo sbctl sign -s /boot/vmlinuz-linux
sudo sbctl sign -s /boot/vmlinuz-linux-lts
/sbin/grub-update-kernel-signature

