#!/bin/bash

# Define your FTB server root directory
SERVER_DIR="/home/ubuntu/server"

cd "$SERVER_DIR" || exit 1
rm -f mc-stop.sh mc-start.sh monitor

# 1. Create monitor script (checks port 25565 and shuts down EC2 if idle)
cat << 'EOF' > monitor
#!/bin/bash
SSM_SHUTDOWNTIMER=$(aws ssm get-parameter --name "/mc/shutdowntimer" --query "Parameter.Value" --output text)
DEFAULT_SHUTDOWNTIMER=900

if [ $? -eq 0 ] && [[ "$SSM_SHUTDOWNTIMER" =~ ^[0-9]+$ ]] && [ "$SSM_SHUTDOWNTIMER" -gt 0 ]; then
    SHUTDOWNTIMER=$SSM_SHUTDOWNTIMER
else
    SHUTDOWNTIMER=$DEFAULT_SHUTDOWNTIMER
fi

lastdisconnect=0
while true; do
    connections=$(netstat -antp | grep ":25565" | grep ESTABLISHED | wc -l)
    if [ "$connections" -eq 0 ]; then
        echo "0 connections"
        if [ "$lastdisconnect" -eq 0 ]; then
            echo "no players on server, starting timer..."
            lastdisconnect=$(date +%s)
        else
            now=$(date +%s)
            elapsed=$((now - lastdisconnect))
            echo "shutdowntimer: $SHUTDOWNTIMER timer: $elapsed"
            if [ "$elapsed" -ge "$SHUTDOWNTIMER" ]; then
                echo "timer has reached time, begin shutdown logic"
                sudo ./mc-stop.sh
                sleep 120 # Increased to 120s to give modded worlds extra time to save chunks
                echo "stop ec2 instance"
                sudo shutdown -h now
                break
            fi
        fi
    else
        echo "connections exist"
        lastdisconnect=0
    fi
    sleep 30
done
EOF
chmod +x monitor

# 2. Create FTB start wrapper (writes SSM RAM to user_jvm_args.txt, then calls FTB's start.sh)
cat << 'EOF' > mc-start.sh
#!/bin/bash
RAM=$(aws ssm get-parameter --name "/mc/ram" --query "Parameter.Value" --output text)
DEFAULT_RAM="14336"

echo "starting FTB server!"
if [ $? -eq 0 ] && [[ "$RAM" =~ ^[0-9]+$ ]] && [ "$RAM" -gt 0 ]; then
    ram_size="${RAM}M"
else
    ram_size="$DEFAULT_RAM"
fi

echo "Configuring RAM: $ram_size"
# Update user_jvm_args.txt used by modern FTB/Forge/NeoForge packs
echo "-Xmx${ram_size}" > user_jvm_args.txt
echo "-Xms${ram_size}" >> user_jvm_args.txt

# Execute FTB's built-in start script (change to ./run.sh if your pack uses run.sh)
exec ./run.sh
EOF
chmod +x mc-start.sh

# 3. Create stop script
cat << 'EOF' > mc-stop.sh
#!/bin/bash
echo "stop" > /run/minecraft.stdin
EOF
chmod +x mc-stop.sh

# Ensure the minecraft user owns the directory and scripts
chown -R minecraft:minecraft "$SERVER_DIR"

# 4. Create systemd service and socket files
cd /etc/systemd/system/ || exit 1
rm -f minecraft.service minecraft.socket monitor_minecraft.service

cat << EOF > minecraft.service
[Unit]
Description=FTB Minecraft Server on start up
After=network.target

[Service]
User=minecraft
WorkingDirectory=${SERVER_DIR}
ExecStart=${SERVER_DIR}/mc-start.sh
Restart=on-failure
Sockets=minecraft.socket
StandardInput=socket
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat << 'EOF' > minecraft.socket
[Unit]
PartOf=minecraft.service

[Socket]
ListenFIFO=%t/minecraft.stdin
EOF

cat << EOF > monitor_minecraft.service
[Unit]
Description=Monitor MC server for network connections
Wants=network-online.target

[Service]
User=ec2-user
WorkingDirectory=${SERVER_DIR}
ExecStart=${SERVER_DIR}/monitor
StandardInput=null

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable minecraft.service minecraft.socket monitor_minecraft.service
sudo systemctl start minecraft.socket minecraft.service monitor_minecraft.service
