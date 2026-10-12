#!/bin/sh

if [ "$(id -u)" = 0 ]; then
	echo
	if [ -e /root/FIRSTBOOT-FAILED.txt ]; then
		echo 'WARNING: first-boot provisioning failed; see /root/FIRSTBOOT-FAILED.txt'
	fi
	echo 'WiFi credentials and access modes: /root/WIFI-PASSWORD.txt'
	echo 'Current device IPv4 address: cat /tmp/current-ip'
	echo 'Recovery fallback: serial console.'
	echo 'Change the root and WiFi passwords after first login.'
fi
