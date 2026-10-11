#!/bin/sh

if [ "$(id -u)" = 0 ]; then
	echo
	echo 'WiFi credentials and access modes: /root/WIFI-PASSWORD.txt'
	echo 'Current device IPv4 address: cat /tmp/current-ip'
	echo 'Recovery fallback: serial console.'
	echo 'Change the root and WiFi passwords after first login.'
fi
