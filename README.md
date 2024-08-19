# farc

```

# Setting the new FID and password
newfid=777777
new_password="88888888"

# Creating and navigating to the hubble directory
cd $HOME
mkdir hubble
cd hubble

# Fetching the script
wget https://raw.githubusercontent.com/encipher88/farc/main/hubble.sh -O hubble.sh
wget https://raw.githubusercontent.com/encipher88/farc/main/check_hubble.sh -O check_hubble.sh

# Updating the FID in the script
sed -i "s/echo[[:space:]]\"HUB_OPERATOR_FID=[0-9]\+\"[[:space:]]>>[[:space:]].env/echo \"HUB_OPERATOR_FID=$newfid\" >> .env/" hubble.sh
sed -i "s/HUB_OPERATOR_FID=[0-9]\+/HUB_OPERATOR_FID=$newfid/" "/root/hubble/.env"

# Updating the password in the script
sed -i "s|local new_password=.*|local new_password=\"$new_password\"|" hubble.sh

# Printing success message and setting permissions
echo "Script fetched and updated successfully."
chmod +x hubble.sh
chmod +x check_hubble.sh

# Running the upgrade command
./hubble.sh upgrade

```
