#! /bin/bash

USERNAME="55k2mu8iN6UIoNey"
PASSWORD="yAho3rBJHLUB0pvL"
HOSTNAME="*.jefedavis.dev"

# Resolve current public IP
IP=$( dig +short myip.opendns.com @resolver1.opendns.com )
# Update Google DNS Record
URL="https://${USERNAME}:${PASSWORD}@domains.google.com/nic/update?hostname=${HOSTNAME}&myip=${IP}"
curl -s $URL
