# farc

```

newfid=777777
new_password="new_secure_password_value"


cd $HOME
mkdir hubble
cd hubble
wget https://raw.githubusercontent.com/encipher88/farc/main/hubble.sh -O hubble.sh
sed -i "s/echo \"HUB_OPERATOR_FID=[0-9]*\"/echo \"HUB_OPERATOR_FID=$newfid\"/" hubble.sh
sed -i "s/new_password=\"new_secure_password\"/new_password=\"$new_password\"/" hubble.sh
echo "Script fetched and updated successfully."
chmod +x hubble.sh
./hubble.sh upgrade
```
