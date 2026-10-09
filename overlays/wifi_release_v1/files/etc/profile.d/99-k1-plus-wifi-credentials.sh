#!/bin/sh

if [ "$(id -u)" = 0 ] && [ -r /root/WIFI-PASSWORD.txt ]; then
	echo
	echo 'WiFi credentials: /root/WIFI-PASSWORD.txt'
	echo 'Change the root and WiFi passwords after first login.'
fi
