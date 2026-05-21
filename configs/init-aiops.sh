#!/usr/bin/bash

# Define a log file for capturing all output
LOGFILE=/var/log/cloud-init-output.log
exec > >(tee -a $LOGFILE) 2>&1

# Marker file to ensure the script only runs once
MARKER_FILE="/home/opc/.init_done"

# Check if the marker file exists
if [ -f "$MARKER_FILE" ]; then
  echo "Init script has already been run. Exiting."
  exit 0
fi

echo "===== Starting Cloud-Init Script ====="

# Expand the boot volume
echo "Expanding boot volume..."
sudo /usr/libexec/oci-growfs -y

# Enable ol9_addons and install necessary development tools
echo "Installing required packages..."

sudo dnf install -y git 
sudo dnf groupinstall -y "Development Tools"
sudo dnf groupinstall -y "Server with GUI" "Graphical Administration Tools"
sudo dnf install tigervnc-server tigervnc-server-module -y
sudo sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
sudo dnf install -y libffi-devel bzip2-devel ncurses-devel
sudo dnf install -y readline-devel make gcc zlib-devel
sudo dnf config-manager --set-enabled ol9_addons
sudo dnf install -y openssl-devel mesa-libGL poppler-utils tesseract
sudo dnf install -y podman wget
sudo dnf install python39-oci-cli -y

sudo mkdir /home/opc/.vnc
sudo echo "Oracle@123" | vncpasswd -f > /home/opc/.vnc/passwd
sudo chown -R opc:opc /home/opc/.vnc
sudo chmod 0600 /home/opc/.vnc/passwd
sudo systemctl set-default graphical.target

sudo cp /lib/systemd/system/vncserver@.service /etc/systemd/system/vncserver@:1.service
sudo echo ":1=opc" >> /etc/tigervnc/vncserver.users 
sudo echo "geometry=1280x1024" >> /etc/tigervnc/vncserver-config-defaults 

sudo systemctl daemon-reload
sudo systemctl enable --now vncserver@:1.service

# Install the latest SQLite from source
echo "Installing latest SQLite..."
cd /tmp
wget https://www.sqlite.org/2023/sqlite-autoconf-3430000.tar.gz
tar -xvzf sqlite-autoconf-3430000.tar.gz
cd sqlite-autoconf-3430000
./configure --prefix=/usr/local
make
sudo make install

# Verify the installation of SQLite
echo "SQLite version:"
/usr/local/bin/sqlite3 --version

# Ensure the correct version is in the path and globally
export PATH="/usr/local/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
echo 'export PATH="/usr/local/bin:$PATH"' >> /home/opc/.bashrc
echo 'export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"' >> /home/opc/.bashrc

# Set environment variables to link the newly installed SQLite with Python build globally
echo 'export CFLAGS="-I/usr/local/include"' >> /home/opc/.bashrc
echo 'export LDFLAGS="-L/usr/local/lib"' >> /home/opc/.bashrc

# Source the updated ~/.bashrc to apply changes globally
source /home/opc/.bashrc

# Run the Oracle Database Free Edition container
echo "Running Oracle Database container..."
sudo podman run -d \
    --name 23ai \
    --network=host \
    -e ORACLE_PWD=database123 \
    container-registry.oracle.com/database/free:23.26.1.0-arm64

#container-registry.oracle.com/database/free:23.26.1.0-lite-amd64

# Wait for Oracle Container to start
echo "Waiting for Oracle container to initialize..."
sleep 20

# --- Wait for CDB root (FREE) ---
# Checking if FREE (CDB root) is registered
echo "$(date '+%Y-%m-%d %H:%M:%S') Checking if FREE (CDB root) is registered..."
MAX_RETRIES=20
for i in $(seq 1 $MAX_RETRIES); do
  if sudo podman exec 23ai lsnrctl status | grep -q "FREE "; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') FREE service is registered with the listener."
    break
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$i/$MAX_RETRIES] Waiting for FREE service..."
  sleep 10
done

if ! sudo podman exec 23ai lsnrctl status | grep -q "FREEPDB1"; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') FREEPDB1 not registered after $MAX_RETRIES attempts. Forcing it open..."
  sudo podman exec 23ai bash -lc "echo exit | sqlplus -S / as sysdba <<EOF
  ALTER SYSTEM SET LOCAL_LISTENER = '(ADDRESS=(PROTOCOL=TCP)(HOST=127.0.0.1)(PORT=1521))' scope=both;
  ALTER SYSTEM REGISTER;
  ALTER PLUGGABLE DATABASE ALL OPEN;
  ALTER PLUGGABLE DATABASE ALL SAVE STATE;
  EXIT;
EOF"
  echo "$(date '+%Y-%m-%d %H:%M:%S') Forced FREEPDB1 open and saved state. Continuing setup..."
fi


# Run the SQL commands to configure the PDB
echo "Configuring Oracle database in PDB (freepdb1)..."
sudo podman exec -i 23ai bash <<EOF
sqlplus -S / as sysdba <<EOSQL
-- ensure PDB is open and switch context
-- ALTER PLUGGABLE DATABASE FREEPDB1 OPEN IF NOT EXISTS;
ALTER SESSION SET CONTAINER=FREEPDB1;
CREATE BIGFILE TABLESPACE tbs2 DATAFILE 'bigtbs_f2.dbf' SIZE 1G AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT AUTO;
CREATE UNDO TABLESPACE undots2 DATAFILE 'undotbs_2a.dbf' SIZE 1G AUTOEXTEND ON RETENTION GUARANTEE;
CREATE TEMPORARY TABLESPACE temp_demo TEMPFILE 'temp02.dbf' SIZE 1G REUSE AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL UNIFORM SIZE 1M;
CREATE USER vector IDENTIFIED BY vector DEFAULT TABLESPACE tbs2 QUOTA UNLIMITED ON tbs2;
GRANT DB_DEVELOPER_ROLE TO vector;
EXIT;
EOSQL
EOF

# Reconnect to CDB root to apply system-level changes
echo "Switching to CDB root for system-level changes..."
sudo podman exec -i 23ai bash <<EOF
sqlplus -S / as sysdba <<EOSQL
CREATE PFILE FROM SPFILE;
ALTER SYSTEM SET vector_memory_size = 512M SCOPE=SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP;
-- Re-open PDBs after restart and save state again
ALTER PLUGGABLE DATABASE ALL OPEN;
ALTER PLUGGABLE DATABASE ALL SAVE STATE;
ALTER SYSTEM REGISTER;
EXIT;
EOSQL
EOF

echo "Final listener check:"
podman exec -i 23ai bash -lc "lsnrctl services"

# Wait for Oracle to restart and apply memory changes
sleep 10

echo "Skipping vector_memory_size check. Assuming it is set to 512M based on startup logs."


# Now switch to opc for user-specific tasks
sudo -u opc -i bash <<'EOF_OPC'

# Set environment variables
export HOME=/home/opc
export PYENV_ROOT="$HOME/.pyenv"
curl https://pyenv.run | bash

# Add pyenv initialization to ~/.bashrc for opc
cat << EOF >> $HOME/.bashrc
export PYENV_ROOT="\$HOME/.pyenv"
[[ -d "\$PYENV_ROOT/bin" ]] && export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init --path)"
eval "\$(pyenv init -)"
eval "\$(pyenv virtualenv-init -)"
EOF

# Ensure .bashrc is sourced on login
cat << EOF >> $HOME/.bash_profile
if [ -f ~/.bashrc ]; then
   source ~/.bashrc
fi
EOF

# Source the updated ~/.bashrc to apply pyenv changes
source $HOME/.bashrc

# Open firewall ports
sudo firewall-cmd --zone=public --add-port=8888/tcp --permanent
sudo firewall-cmd --zone=public --add-port=8000/tcp --permanent
sudo firewall-cmd --zone=public --add-port=8501/tcp --permanent
sudo firewall-cmd --zone=public --add-port=1521/tcp --permanent
sudo firewall-cmd --zone=public --add-port=3000/tcp --permanent
sudo firewall-cmd --zone=public --add-port=5901/tcp --permanent
sudo firewall-cmd --zone=public --add-port=80/tcp --permanent
sudo firewall-cmd --zone=public --add-port=8080/tcp --permanent
sudo firewall-cmd --zone=public --add-masquerade --permanent
sudo firewall-cmd --permanent --add-port={2379,2380,7946,8472,443,6443,10250,2376,9099,10254,30000-32767}/tcp
sudo firewall-cmd --permanent --add-port={8472,30000-32767}/udp
sudo modprobe br_netfilter

# Reload firewalld 
sudo firewall-cmd --reload

# Export PATH to ensure pyenv is correctly initialized
export PATH="$PYENV_ROOT/bin:$PATH"

# Install Python 3.11.9 using pyenv with the correct SQLite version linked
CFLAGS="-I/usr/local/include" LDFLAGS="-L/usr/local/lib" LD_LIBRARY_PATH="/usr/local/lib" pyenv install 3.11.9

# Rehash pyenv to update shims
pyenv rehash

# Set up vectors directory and Python 3.11.9 environment
mkdir -p $HOME/labs
cd $HOME/labs
pyenv global 3.11.9

# Rehash again to ensure shims are up to date
pyenv rehash

# Verify Python version in the labs directory
python --version

# Adding the PYTHONPATH for correct installation and look up for the libraries
export PYTHONPATH=$HOME/.pyenv/versions/3.11.9/lib/python3.11/site-packages:$PYTHONPATH

# Install required Python packages
$HOME/.pyenv/versions/3.11.9/bin/pip install --no-cache-dir oci oracledb sentence-transformers
$HOME/.pyenv/versions/3.11.9/bin/pip install --no-cache-dir chroma-hnswlib==0.7.3 chromadb==0.5.3 torch==2.5.0
$HOME/.pyenv/versions/3.11.9/bin/pip install --no-cache-dir tiktoken==0.5.1 matplotlib==3.7.1 tensorflow==2.15.0
$HOME/.pyenv/versions/3.11.9/bin/pip install --no-cache-dir tqdm==4.66.1 pandas==2.2.1 psutil==5.9.5  
$HOME/.pyenv/versions/3.11.9/bin/pip install --no-cache-dir "numpy<2.0"   
$HOME/.pyenv/versions/3.11.9/bin/pip install --no-cache-dir thop "chainlit>=1.2.0" "pydantic==2.9.2" "cohere" "python-dotenv"
$HOME/.pyenv/versions/3.11.9/bin/pip install --no-cache-dir "pyautogen==0.2.25"
$HOME/.pyenv/versions/3.11.9/bin/pip install --no-cache-dir "chess==1.10.0"
$HOME/.pyenv/versions/3.11.9/bin/pip install --no-cache-dir ipywidgets widgetsnbextension pandas-profiling

# Download the model during script execution
python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L12-v2')"

# Install JupyterLab
pip install --user jupyterlab

# Ensure .bashrc is sourced on login
cat << EOF >> $HOME/.bash_profile
if [ -f ~/.bashrc ]; then
   source ~/.bashrc
fi
cd ~/labs/
nohup jupyter-lab --no-browser --ip 0.0.0.0 --NotebookApp.token='Sangwan^123' --NotebookApp.password='Oracle@123' --port 8888 &

EOF

sudo cat << EOF >>/etc/sysctl.conf
net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
EOF

sudo sysctl -p

# Get the first non-localhost IP address
NODE_IP=$(hostname -I | tr ' ' '\n' | grep -v '^127\.' | head -1)

if [ -z "$NODE_IP" ]; then
  echo "Error: Could not determine a non-localhost IP address."
  exit 1
fi

echo "Using IP address: $NODE_IP"

# Install k3s with the detected IP
sudo curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.23.9+k3s1" \
  K3S_TOKEN=skillpedia#1 sh -s - server \
  --node-ip="$NODE_IP" \
  --advertise-address="$NODE_IP" \
  --cluster-init

mkdir ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown opc.opc /etc/rancher/k3s/k3s.yaml
sudo chown opc.opc ~/.kube/config

# Add --kubelet-insecure-tls arg to the container
kubectl patch deployment metrics-server \
  -n kube-system \
  --type='json' \
  -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/args/-",
      "value": "--kubelet-insecure-tls"
    },
    {
      "op": "add",
      "path": "/spec/template/spec/hostNetwork",
      "value": true
    }
  ]'

echo "metrics-server patched successfully"

echo "Jupyter Lab Server is started successfully"

EOF_OPC

# Create the marker file to indicate the script has been run
touch "$MARKER_FILE"
echo "===== Cloud-Init Script Completed Successfully ====="
sudo reboot
