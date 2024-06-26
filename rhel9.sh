#!/bin/bash

# Print colored messages
print_message() {
    local color="$1"
    local message="$2"
    echo -e "\e[${color}m${message}\e[0m"
}
print_success() { print_message 32 "[Success] $1"; }
print_action() { print_message 33 "[Action] $1"; }

# Splash warning and disclaimer text
clear
echo "** Important Please Read! **"
echo "This script is intended for use on a RHEL 9 based distro."
echo "It will install fail2ban and optionally docker, dnf-automatic."
echo "Please make sure you are using a fresh install and logged in as root."
read -r -p "Do you wish to proceed? [y/N]: " start
[[ "$start" =~ ^([yY][eE][sS]|[yY])$ ]] || { echo "Exiting script, goodbye."; exit 1; }

# Set hostname
read -r -p "Please enter desired hostname: " hostname
hostnamectl set-hostname "$hostname"
print_success "Hostname set to $hostname."

# Set system timezone
read -r -p "Please enter desired timezone [America/New_York]: " timezone
timezone=${timezone:-America/New_York}
timedatectl set-timezone "$timezone"
print_success "Timezone set to $timezone."

# Add user account and set password
read -r -p "Please enter desired admin username: " username
id "$username" &>/dev/null || sudo useradd -m -k /empty_skel "$username"
usermod -aG wheel "$username"
print_success "User $username created/exists and added to wheel group."
passwd "$username" && print_success "Password set for $username." || { print_message 31 "[Failed] to set password for $username."; exit 1; }

# Move root authorized_keys to new user
read -r -p "Move root authorized_keys to new user? [y/N]: " swapyn
if [[ "$swapyn" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    print_action "Moving root SSH keys to new user."
    mkdir -p /home/$username/.ssh
    mv /root/.ssh/authorized_keys /home/$username/.ssh/
    chown -R $username:$username /home/$username/.ssh
    chmod 700 /home/$username/.ssh
    chmod 600 /home/$username/.ssh/authorized_keys
    print_success "SSH keys moved."
fi

# Secure shared memory
read -r -p "Secure shared memory? [y/N]: " swapyn
if [[ "$swapyn" =~ ^([yY][eE][sS]|[yY])$ ]]; then
print_action "Securing shared memory."
echo 'tmpfs   /run/shm   tmpfs   defaults,noexec,nosuid   0 0' >> /etc/fstab
print_success "Shared memory secured."
fi

# Disable unused network and printer services
print_action "Disabling unused network and printer services."
systemctl disable avahi-daemon cups
print_success "Unused services disabled."

# Create swapfile
read -r -p "Create a swapfile? [y/N]: " swapyn
if [[ "$swapyn" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    read -r -p "How many GB do you wish to use for the swapfile? " swapsize
    fallocate -l "${swapsize}G" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile   swap    swap    sw   0 0' >> /etc/fstab
    print_success "Swapfile created."
fi

# Optimize RAM usage
read -r -p "Optimize RAM usage? [y/N]: " swapyn
if [[ "$swapyn" =~ ^([yY][eE][sS]|[yY])$ ]]; then
print_action "Optimizing swappiness and cache pressure."
echo 'vm.swappiness = 10' >> /etc/sysctl.conf
echo 'vm.vfs_cache_pressure = 50' >> /etc/sysctl.conf
print_success "Swappiness and cache pressure optimized."
swapon --show
sudo sysctl -p
echo "Review swap settings. Press any key to continue."
read -r
fi

# Install EPEL repo and update
print_action "Installing EPEL repo and updating."
dnf install epel-release -y && dnf update -y
print_success "EPEL repo installed and system updated."

# Install security-utils, firewalld, and fail2ban
print_action "Installing security-utils, fail2ban, and firewalld."
dnf install policycoreutils-python-utils fail2ban firewalld fail2ban-firewalld -y
systemctl enable --now firewalld fail2ban
firewall-cmd --version
fail2ban-client --version
print_success "Security packages installed."
read -r "Review firewall and fail2ban installed. Press any key to continue."

# Update SSH port
read -r -p "Select desired SSH port number (1024-65535): " sshport
print_action "Updating SSH port and authentication methods."
cat << EOF > /etc/ssh/sshd_config.d/ssh.conf
# Custom SSH Configuration for $hostname
Protocol 2
Port $sshport 
PermitRootLogin no
PasswordAuthentication no
MaxAuthTries 3 
MaxSessions 5
LoginGraceTime 30
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
EOF
print_success "SSH configuration updated."

# Update SELinux and Firewalld
print_action "Updating SELinux and Firewalld for SSH port."
semanage port -a -t ssh_port_t -p tcp "$sshport" || semanage port -m -t ssh_port_t -p tcp "$sshport"
firewall-cmd --zone=public --remove-service={ssh,cockpit,dhcpv6-client} --permanent
firewall-cmd --zone=public --add-port="$sshport"/tcp --permanent
firewall-cmd --zone=public --add-service={http,https} --permanent
firewall-cmd --reload
print_success "SELinux and Firewalld updated."

# Configure Fail2ban
print_action "Configuring Fail2ban."
cat << EOF > /etc/fail2ban/jail.d/sshd.local
[sshd]
enabled = true
port = $sshport
maxretry = 5
bantime = 24h
findtime = 24h
banaction = firewallcmd-rich-rules[actiontype=<muliport>]
banaction_allports = firewallcmd-rich-rules[actiontype=<allport>]
EOF
print_success "Fail2ban configured."

print_action "Restarting SSH and Fail2ban daemon."
systemctl restart sshd
systemctl restart fail2ban
print_success "SSH and Fail2ban daemon restarted."

# Install Docker
read -r -p "Install Docker? [y/N]: " swapyn
if [[ "$swapyn" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    print_action "Uninstalling old Docker versions."
    dnf remove docker{,-client,-client-latest,-common,-latest,-latest-logrotate,-logrotate,-engine} podman buildah runc -y
    print_success "Old Docker versions uninstalled."

    print_action "Adding Docker repository and updating."
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf update
    print_success "Docker repository added."

    print_action "Installing Docker and Docker Compose."
    print_action "Docker GPG Key 060A 61C5 1B55 8A7F 742B 77AA C52F EB6B 621E 9F35"
    dnf install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
    print_success "Docker installed."
    
    read -r -p "Harden Docker daemon security? [y/N]: " autoyn
    if [[ "$autoyn" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    print_action "Hardening Docker daemon security."
    mkdir -p /etc/docker
    cat << EOF > /etc/docker/daemon.json
{
  "icc": false,
  "userns-remap": "default",
  "no-new-privileges": true
}
EOF
    print_success "Docker daemon hardened."
    fi
    # Open docker swarm ports in internal firewalld
    firewall-cmd --zone=internal --add-port="2376"/tcp --permanent # Docker client communication
    firewall-cmd --zone=internal --add-port="2377"/tcp --permanent # Swarm manager control plane 
    firewall-cmd --zone=internal --add-port="7946"/tcp --permanent # Swarm discovery tcp
    firewall-cmd --zone=internal --add-port="7946"/udp --permanent # Swarm discovery udp
    firewall-cmd --zone=internal --add-port="4789"/udp --permanent # Trusted overlay network 
    firewall-cmd --zone=internal --add-port="9001"/udp --permanent # Portainer agent
    firewall-cmd --zone=internal --add-port="9443"/tcp --permanent # Portainer web interface
    firewall-cmd --reload
    groupadd docker
    usermod -aG docker "$username"
    # Enable docker daemon
    systemctl enable --now docker
    print_success "Docker configured and started."
fi

# Enable automatic updates
read -r -p "Install and enable automatic updates? [y/N]: " autoyn
if [[ "$autoyn" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    dnf install dnf-automatic -y
    print_action "Configuring automatic updates."
    read -r -p "Configure automatic updates? [y/N]: " autoyn
    [[ "$autoyn" =~ ^([yY][eE][sS]|[yY])$ ]] && vi /etc/dnf/automatic.conf

    read -r -p "Change automatic updates timer? [06:00 daily] [y/N]: " autoyn
    if [[ "$autoyn" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        cp /usr/lib/systemd/system/dnf-automatic.timer /etc/systemd/system/
        vi /etc/systemd/system/dnf-automatic.timer
    fi
    systemctl daemon-reload
    systemctl enable --now dnf-automatic.timer
    print_success "Automatic updates enabled."
fi

# Install additional packages
read -r -p "Install additional packages [y/N]: " swapyn
if [[ "$swapyn" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    read -r -p "List packages to install? [tmux btop]: " packages
    packages=${packages:-tmux btop}
    print_action "Installing additional packages."
    dnf install $packages -y
    print_success "Additional packages installed."
fi

# Parting remarks.
print_action "All done! Don't forget to reboot into your new user and disable root login. # sudo passwd -l root"
exit 0
